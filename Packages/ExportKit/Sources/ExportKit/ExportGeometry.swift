import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ShotModel

/// Pure geometry for reproducing the report's per-step zoom/pan as a static crop
/// on export. Ported verbatim from export-geometry.ts. All operands are
/// non-negative here (width/height > 0, zoom > 1, pan in [0,1]), so Swift's
/// round-half-away and JS's round-half-up agree — `.rounded()` is safe.
///
/// Returns the visible sub-region (natural image pixels, top-left origin) shown
/// for a given zoom/pan, or nil when the whole image is visible (zoom ≤ 1) or
/// the inputs are degenerate.
func zoomCropRect(width: Double, height: Double, zoom: Double, panX: Double, panY: Double) -> CGRect? {
    guard zoom > 1 else { return nil }         // zoom ≤ 1 / NaN → full image
    guard width >= 2, height >= 2 else { return nil }
    let boxScale = min(zoom, 1)                 // == 1 for zoom > 1; kept for parity
    let w = max(1, min(width, (width * boxScale / zoom).rounded()))
    let h = max(1, min(height, (height * boxScale / zoom).rounded()))
    if w >= width, h >= height { return nil }   // nothing to crop
    let px = clamp01(panX), py = clamp01(panY)
    let x = max(0, min(width - w, (width * (zoom - boxScale) * px / zoom).rounded()))
    let y = max(0, min(height - h, (height * (zoom - boxScale) * py / zoom).rounded()))
    return CGRect(x: x, y: y, width: w, height: h)
}

private func clamp01(_ n: Double) -> Double {
    guard n.isFinite else { return 0.5 } // default to centered on a bad value
    return n < 0 ? 0 : (n > 1 ? 1 : n)
}

/// Crop the already-safe render at `path` to its report zoom/pan window and
/// re-encode PNG. Returns nil when there's nothing to crop (zoom ≤ 1) OR on any
/// failure — a nil result means "use the full render", and that render is the
/// redaction-baked sendable one, so this NEVER falls open to raw pixels.
func zoomCropPNG(path: String, zoom: Double, panX: Double, panY: Double) -> Data? {
    guard zoom > 1,
          let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }
    guard let rect = zoomCropRect(
        width: Double(image.width), height: Double(image.height),
        zoom: zoom, panX: panX, panY: panY),
        let cropped = image.cropping(to: rect)
    else { return nil }
    return encodePNG(cropped)
}

/// The most pixels a framed export image may have. A very tall image in a wide
/// frame (or an extreme hand-edited frame) pads to a canvas many times the
/// image's own area at render resolution; above this budget the framed image is
/// drawn scaled down instead of allocated in full. 4096² is far more than any
/// export shows (HTML displays at most 738 px wide at scale 1, PDF ~468 pt).
let framedCanvasPixelBudget = 4096 * 4096

/// A framed project's image for one step (Armadillon44/shotAI#160): the region
/// of the render the report shows, on a transparent canvas of the frame's shape,
/// at the step's zoom and pan (`FrameGeometry.pan(for:)`, the click-centred
/// default where no pan is saved).
///
/// Returns nil when the render already IS the framed image (it has the frame's
/// shape at fit) OR on any failure. nil means "use the full render", and that
/// render is the redaction-baked sendable one, so like `zoomCropPNG` this never
/// falls open to raw pixels: it only ever crops or pads baked pixels.
func framedPNG(path: String, step: ProjectStep, box: FrameGeometry.Size) -> Data? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }
    let w = image.width, h = image.height
    let pan = FrameGeometry.pan(for: step, imageWidth: Double(w), imageHeight: Double(h), box: box)
    guard let layout = FrameGeometry.exportLayout(imageWidth: w, imageHeight: h, box: box,
                                                  zoom: step.reportZoom ?? 1, panX: pan.x, panY: pan.y),
          !layout.isIdentity
    else { return nil }
    return composeFramed(image, layout: layout)
}

/// Draw `layout`'s crop of `image` onto its transparent canvas, scaled down as a
/// whole when the canvas is over `framedCanvasPixelBudget`. At full size the
/// crop is copied pixel for pixel.
func composeFramed(_ image: CGImage, layout: FrameGeometry.ExportLayout,
                   pixelBudget: Int = framedCanvasPixelBudget) -> Data? {
    guard let crop = image.cropping(to: CGRect(x: layout.cropX, y: layout.cropY,
                                               width: layout.cropWidth, height: layout.cropHeight))
    else { return nil }
    let cw = Double(layout.canvasWidth), ch = Double(layout.canvasHeight)
    let k = min(1, (Double(pixelBudget) / (cw * ch)).squareRoot())
    let outW = max(1, Int((cw * k).rounded())), outH = max(1, Int((ch * k).rounded()))
    // The render's own colour space, so the copied pixels keep their values.
    let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: outW, height: outH))   // the padding: transparent
    ctx.interpolationQuality = .high
    let dw = Double(layout.cropWidth) * k, dh = Double(layout.cropHeight) * k
    // CoreGraphics' origin is bottom-left; the layout's is top-left.
    ctx.draw(crop, in: CGRect(x: Double(layout.originX) * k,
                              y: Double(outH) - Double(layout.originY) * k - dh,
                              width: dw, height: dh))
    return ctx.makeImage().flatMap(encodePNG)
}

/// Resample PNG/JPEG `data` down so its width is at most `maxWidth`, re-encoding
/// PNG. Returns nil when there's nothing to do or on any failure — a nil result
/// means "use the bytes you already have", so this can only ever leave the
/// payload larger, never fall open to different pixels (#64).
///
/// NEVER upscales: a capture already at or under `maxWidth` is left alone, both
/// to avoid inventing detail and because re-encoding a crisp screenshot for no
/// reason can make it BIGGER (interpolation turns flat colour runs into many
/// unique colours, which PNG compresses worse).
///
/// Only the HTML exporters use this. They inline the image as a base64 data URI
/// and then let CSS display it at `htmlExportImageMaxWidth`, so shipping the full
/// render was ~3x more pixels than are ever shown, plus base64's ~33% overhead.
/// PDF and Markdown deliberately keep full resolution (print quality / separate
/// image files, no payload to bloat).
func downscalePNG(_ data: Data, maxWidth: Int) -> Data? {
    guard maxWidth > 0,
          let src = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
          image.width > maxWidth, image.height > 0
    else { return nil }
    // Preserve aspect; guarantee at least 1px so a pathological sliver survives.
    let scale = Double(maxWidth) / Double(image.width)
    let w = maxWidth
    let h = max(1, Int((Double(image.height) * scale).rounded()))
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let out = ctx.makeImage() else { return nil }
    return encodePNG(out)
}

/// Whether ImageIO on this system can WRITE AVIF. Computed once — the set of
/// writable types is fixed for the process.
private let canEncodeAVIF: Bool = {
    (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(avifTypeIdentifier)
}()

private let avifTypeIdentifier = "public.avif"

/// Re-encode `data` as AVIF at `quality` (0…1), or nil if AVIF can't be written
/// here or the encode fails — callers then keep their PNG bytes, so this can only
/// make the payload larger, never break an export.
///
/// Why AVIF for the styled HTML export (#64): the images are inlined as base64,
/// and Freshservice-style KB editors accept a data URI but choke past a total
/// payload budget. AVIF is the only format that is BOTH natively writable by
/// ImageIO (so no third-party dependency — WebP is decode-only on macOS) and
/// dramatically smaller than PNG on screenshots. Measured on a real 9-step SOP:
/// 1.43 MB of base64 as PNG vs 0.16 MB as AVIF q85, with the worst single image
/// going 495 KB -> 26 KB. At 4x magnification q85 is indistinguishable from
/// lossless on UI text, which is the content that matters here.
///
/// NOT used for the plain / Word-paste export: Word cannot read AVIF.
func encodeAVIF(_ data: Data, quality: Double) -> Data? {
    guard canEncodeAVIF,
          let src = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        out, avifTypeIdentifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [
        kCGImageDestinationLossyCompressionQuality: quality,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(dest), out.length > 0 else { return nil }
    return out as Data
}

/// Encode a CGImage to PNG data (sRGB), or nil on failure.
func encodePNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}
