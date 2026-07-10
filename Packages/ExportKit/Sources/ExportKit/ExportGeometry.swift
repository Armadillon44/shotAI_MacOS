import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

/// Encode a CGImage to PNG data (sRGB), or nil on failure.
func encodePNG(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}
