import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cropping, downscaling and PNG encoding for captured frames. The downscale
/// contract is ported exactly from downscalePng (T2): target width =
/// max(1, round(w × 0.85)) pixels, skip for degenerate/no-op cases, persist the
/// ACTUAL post-rounding scale, and fail OPEN — a resize hiccup must never lose
/// a capture.
public enum ImageOutput {
    public struct Prepared: @unchecked Sendable {
        /// PNG bytes actually written to shots/.
        public var png: Data
        /// stored-PNG px per global POINT: pixelScale × downscale. This is the
        /// schema's click.imageScale (persisted iff ≠ 1).
        public var imageScale: CGFloat
    }

    /// Crop a full-display frame to a monitor-local point rect, downscale, and
    /// PNG-encode. `pixelScale` is the frame's pixels-per-point. `scale` is the
    /// target downscale factor (defaults to the constant; the engine passes the
    /// user's configured screenshot quality).
    public static func prepare(
        frame: CGImage,
        cropLocal: CGRect?,
        pixelScale: CGFloat,
        scale: CGFloat = CaptureConstants.captureScale
    ) -> Prepared? {
        var image = frame
        var effectivePixelScale = pixelScale
        if let cropLocal {
            // Round each EDGE independently (not origin+size), so the width and
            // height come out consistent per axis on fractional-scale displays,
            // then clamp explicitly to the frame instead of relying on
            // cropping(to:)'s silent intersection.
            let minX = (cropLocal.minX * pixelScale).rounded()
            let minY = (cropLocal.minY * pixelScale).rounded()
            let maxX = (cropLocal.maxX * pixelScale).rounded()
            let maxY = (cropLocal.maxY * pixelScale).rounded()
            let pixelRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
                  let cropped = frame.cropping(to: pixelRect) else { return nil }
            image = cropped
            // The actual pixels-per-point of the cropped image (rounding can
            // shave a pixel; keep click math exact against real dimensions).
            effectivePixelScale = cropLocal.width > 0 ? CGFloat(cropped.width) / cropLocal.width : pixelScale
        }
        let (downscaled, downScale) = downscale(image, scale: scale)
        guard let png = encodePNG(downscaled) else { return nil }
        return Prepared(png: png, imageScale: effectivePixelScale * downScale)
    }

    /// Ported downscalePng: returns the (possibly original) image + the ACTUAL
    /// applied scale (so click-coordinate math stays exact even when rounding
    /// shaves a pixel). Enforces the readability floor — the longer edge is never
    /// taken below `minCaptureLongEdge`, so even a low quality setting stays
    /// legible (target = max(userScale, floorScale)). Fail-open on every path.
    static func downscale(_ image: CGImage, scale: CGFloat = CaptureConstants.captureScale) -> (CGImage, CGFloat) {
        let w = image.width
        let h = image.height
        guard w >= 2, h >= 2 else { return (image, 1) }
        // Never upscale (floorScale caps at 1 for already-small captures).
        let floorScale = min(1, CaptureConstants.minCaptureLongEdge / CGFloat(max(w, h)))
        let target = max(scale, floorScale)
        guard target < 1 else { return (image, 1) }
        let targetW = max(1, Int((CGFloat(w) * target).rounded()))
        guard targetW < w else { return (image, 1) }
        let targetH = max(1, Int((CGFloat(h) * CGFloat(targetW) / CGFloat(w)).rounded()))
        guard let ctx = CGContext(
            data: nil,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (image, 1) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let out = ctx.makeImage() else { return (image, 1) }
        return (out, CGFloat(out.width) / CGFloat(w))
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
