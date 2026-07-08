import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ShotModel
import UniformTypeIdentifiers

/// Pure flatten: a screenshot CGImage + its annotations → a single PNG, with the
/// crop applied and blur/redact regions BAKED destructively into the pixels.
/// Ported from `shotAI-original/src/renderer/editor/flatten.ts`.
///
/// SECURITY-CRITICAL: redaction must be irreversible in the output. The region
/// is mosaiced (average-downsample then upsample) or solid-filled BEFORE any
/// vector overlay, so the original pixels under a redaction are gone from the
/// result. Exports and the Claude pass consume only this flattened PNG — never
/// the raw shots/*.png. Fail CLOSED: if a redaction overlaps the exported region
/// but can't be baked (rounds to <1px), throw rather than emit a PNG with an
/// un-obscured area the user believes is redacted.
public enum Flatten {
    public struct Marker: Sendable {
        public var x: CGFloat
        public var y: CGFloat
        /// Ring color (CSS hex string).
        public var color: String
        /// Ring radius (image px). nil = derive from image size.
        public var radius: CGFloat?

        public init(x: CGFloat, y: CGFloat, color: String, radius: CGFloat? = nil) {
            self.x = x
            self.y = y
            self.color = color
            self.radius = radius
        }
    }

    public enum FlattenError: Error, LocalizedError, Equatable {
        case redactionUnbakeable
        case contextUnavailable
        case encodeFailed

        public var errorDescription: String? {
            switch self {
            case .redactionUnbakeable:
                "A redaction region could not be applied (too small or off-image). Adjust or remove it, then save again."
            case .contextUnavailable:
                "Could not create the render context."
            case .encodeFailed:
                "Could not encode the flattened image."
            }
        }
    }

    /// Flatten to PNG data. `crop` (image px) selects the region; nil = whole image.
    public static func toPNG(
        image: CGImage,
        annotations: [Annotation],
        crop: Rect?,
        marker: Marker? = nil
    ) throws -> Data {
        let nw = image.width
        let nh = image.height
        let cx = crop.map { clampInt(Int($0.x.rounded()), 0, max(0, nw - 1)) } ?? 0
        let cy = crop.map { clampInt(Int($0.y.rounded()), 0, max(0, nh - 1)) } ?? 0
        let cw = crop.map { clampInt(Int($0.width.rounded()), 1, nw - cx) } ?? nw
        let ch = crop.map { clampInt(Int($0.height.rounded()), 1, nh - cy) } ?? nh

        guard let ctx = CGContext(
            data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw FlattenError.contextUnavailable }

        // Flip to a top-left origin so all drawing uses image-pixel coordinates
        // (y down), matching the schema and the HTML-canvas source.
        ctx.translateBy(x: 0, y: CGFloat(ch))
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high

        // 1) the (cropped) source
        guard let cropped = image.cropping(to: CGRect(x: cx, y: cy, width: cw, height: ch)) else {
            throw FlattenError.contextUnavailable
        }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: cw, height: ch))

        // 2) BAKE redaction destructively, before any overlay. Fail closed.
        for case .blur(let a) in annotations {
            let bx = finite(a.x), by = finite(a.y), bw = finite(a.width), bh = finite(a.height)
            // Overlap of the blur with the output (crop) region, in image px.
            let ow = min(bx + bw, CGFloat(cx + cw)) - max(bx, CGFloat(cx))
            let oh = min(by + bh, CGFloat(cy + ch)) - max(by, CGFloat(cy))
            if ow <= 0 || oh <= 0 { continue } // entirely outside the export
            let baked = bakeRedaction(ctx, blur: a, source: image, cropX: cx, cropY: cy, cw: cw, ch: ch)
            if !baked { throw FlattenError.redactionUnbakeable }
        }

        // 3) vector overlay on top (image-px coords → cropped-canvas coords)
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(-cx), y: CGFloat(-cy))
        for a in annotations { drawVector(ctx, a) }
        ctx.restoreGState()

        // 4) click-register markers, baked on top so Claude's vision + exports
        //    see the clicked spot(s). The step's own marker (param) plus any
        //    'marker' annotations render with one style.
        let defaultRadius = AnnotationStyle.clickMarkerRadius(width: CGFloat(nw), height: CGFloat(nh))
        if let marker {
            drawMarker(ctx, x: marker.x, y: marker.y, color: marker.color,
                       radius: marker.radius ?? defaultRadius, cropX: cx, cropY: cy)
        }
        for case .marker(let a) in annotations {
            drawMarker(ctx, x: a.x, y: a.y, color: a.color,
                       radius: a.radius ?? defaultRadius, cropX: cx, cropY: cy)
        }

        guard let out = ctx.makeImage() else { throw FlattenError.encodeFailed }
        return try encodePNG(out)
    }

    // MARK: - Redaction bake

    /// Destructively obscure one region. Returns false if it clamped to nothing
    /// (caller fails the save rather than emit an unprotected region). Coordinates
    /// mirror flatten.ts's canvas-space rounding exactly.
    private static func bakeRedaction(
        _ ctx: CGContext, blur a: BlurAnnotation, source: CGImage,
        cropX: Int, cropY: Int, cw: Int, ch: Int
    ) -> Bool {
        let x = Int((a.x - CGFloat(cropX)).rounded())
        let y = Int((a.y - CGFloat(cropY)).rounded())
        let x0 = clampInt(x, 0, cw)
        let y0 = clampInt(y, 0, ch)
        let x1 = clampInt(x + Int(a.width.rounded()), 0, cw)
        let y1 = clampInt(y + Int(a.height.rounded()), 0, ch)
        let w = x1 - x0
        let h = y1 - y0
        if w <= 0 || h <= 0 { return false }
        let dest = CGRect(x: x0, y: y0, width: w, height: h)

        if a.mode == .solid {
            ctx.saveGState()
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(dest)
            ctx.restoreGState()
            return true
        }

        // Mosaic: crop the SOURCE region (equivalent to the canvas at bake time —
        // only the source has been drawn so far), average-downsample it, then
        // draw it back up. `block` (downsample factor) is floored at
        // MIN_REDACT_BLOCK so a hand-edited manifest can't blur text legible.
        let block = max(AnnotationStyle.minRedactBlock, CGFloat(max(1, Int((a.blockSize == 0 ? 12 : a.blockSize).rounded()))))
        let sw = max(1, Int((CGFloat(w) / block).rounded()))
        let sh = max(1, Int((CGFloat(h) / block).rounded()))
        // Source region in image coords (top-left) = canvas region + crop origin.
        guard let region = source.cropping(to: CGRect(x: x0 + cropX, y: y0 + cropY, width: w, height: h)),
              let small = CGContext(
                data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            // Fail closed: solid-fill rather than leak pixels.
            ctx.saveGState()
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(dest)
            ctx.restoreGState()
            return true
        }
        small.interpolationQuality = .high // averaging downsample
        small.draw(region, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let tile = small.makeImage() else {
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(dest)
            return true
        }
        ctx.saveGState()
        ctx.clip(to: dest) // keep the upscale bleed off un-redacted pixels
        ctx.interpolationQuality = .high
        ctx.draw(tile, in: dest)
        ctx.restoreGState()
        return true
    }

    // MARK: - Vector overlay

    private static func drawVector(_ ctx: CGContext, _ a: Annotation) {
        switch a {
        case .rect(let r):
            let rect = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            let radius = max(0, min(r.cornerRadius, abs(r.width) / 2, abs(r.height) / 2))
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            if let fill = r.fill, let c = cgColor(fromHex: fill) {
                ctx.setFillColor(c)
                ctx.fillPath()
                ctx.addPath(path)
            }
            ctx.setStrokeColor(cgColor(fromHex: r.stroke) ?? defaultAccent)
            ctx.setLineWidth(r.strokeWidth)
            ctx.strokePath()

        case .arrow(let ar):
            guard ar.points.count == 4 else { return }
            let (x1, y1, x2, y2) = (ar.points[0], ar.points[1], ar.points[2], ar.points[3])
            let color = cgColor(fromHex: ar.stroke) ?? defaultAccent
            ctx.setStrokeColor(color)
            ctx.setFillColor(color)
            ctx.setLineWidth(ar.strokeWidth)
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x1, y: y1))
            ctx.addLine(to: CGPoint(x: x2, y: y2))
            ctx.strokePath()
            let angle = atan2(y2 - y1, x2 - x1)
            let head = max(12, ar.strokeWidth * 3)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x2, y: y2))
            ctx.addLine(to: CGPoint(x: x2 - head * cos(angle - .pi / 6), y: y2 - head * sin(angle - .pi / 6)))
            ctx.addLine(to: CGPoint(x: x2 - head * cos(angle + .pi / 6), y: y2 - head * sin(angle + .pi / 6)))
            ctx.closePath()
            ctx.fillPath()

        case .stamp(let s):
            ctx.saveGState()
            ctx.setFillColor(cgColor(fromHex: s.fill) ?? defaultAccent)
            ctx.fillEllipse(in: CGRect(x: s.x - s.radius, y: s.y - s.radius, width: s.radius * 2, height: s.radius * 2))
            ctx.restoreGState()
            drawText(ctx, String(s.n), centeredAt: CGPoint(x: s.x, y: s.y),
                     fontSize: (s.radius * 1.15).rounded(), bold: true,
                     color: cgColor(fromHex: s.textColor) ?? whiteColor)

        case .text(let t):
            drawText(ctx, t.text, topLeftAt: CGPoint(x: t.x, y: t.y),
                     fontSize: t.fontSize, bold: false,
                     color: cgColor(fromHex: t.fill) ?? defaultAccent)

        case .blur, .marker, .unknown:
            break // blur baked in step 2; marker drawn in step 4; unknown not rendered
        }
    }

    private static func drawMarker(
        _ ctx: CGContext, x: CGFloat, y: CGFloat, color: String, radius: CGFloat,
        cropX: Int, cropY: Int
    ) {
        let cx = finite(x) - CGFloat(cropX)
        let cy = finite(y) - CGFloat(cropY)
        let c = cgColor(fromHex: color) ?? defaultAccent
        let box = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
        ctx.saveGState()
        ctx.setAlpha(0.18)
        ctx.setFillColor(c)
        ctx.fillEllipse(in: box)
        ctx.setAlpha(1)
        ctx.setLineWidth(max(2, (radius * 0.22).rounded()))
        ctx.setStrokeColor(c)
        ctx.strokeEllipse(in: box)
        ctx.restoreGState()
    }

    // MARK: - Text (Core Text, flip-compensated for the top-left context)

    private static func drawText(
        _ ctx: CGContext, _ string: String, topLeftAt topLeft: CGPoint? = nil,
        centeredAt center: CGPoint? = nil, fontSize: CGFloat, bold: Bool, color: CGColor
    ) {
        guard !string.isEmpty else { return }
        let fontName = bold ? "Helvetica-Bold" : "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        let baseline: CGPoint
        if let p = topLeft {
            baseline = CGPoint(x: p.x, y: p.y + ascent) // textBaseline = top
        } else if let p = center {
            baseline = CGPoint(x: p.x - width / 2, y: p.y + (ascent - descent) / 2) // centered
        } else {
            return
        }

        ctx.saveGState()
        // Un-flip locally so glyphs render upright in the top-left context.
        ctx.translateBy(x: baseline.x, y: baseline.y)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Encode

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FlattenError.encodeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw FlattenError.encodeFailed }
        return data as Data
    }

    // MARK: - Helpers

    private static let defaultAccent = cgColor(fromHex: AnnotationStyle.accent)!
    private static let whiteColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
}

private func finite(_ v: CGFloat) -> CGFloat { v.isFinite ? v : 0 }
private func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int { max(lo, min(v, hi)) }
