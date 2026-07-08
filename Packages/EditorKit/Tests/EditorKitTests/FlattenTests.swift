import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import EditorKit
import ShotModel

@Suite struct FlattenTests {
    // MARK: - Test image helpers (all top-left coordinate space)

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Build a source CGImage; the draw block uses TOP-LEFT image coordinates.
    private func makeImage(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(ctx)
        return ctx.makeImage()!
    }

    private func decodePNG(_ data: Data) -> CGImage {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(src, 0, nil)!
    }

    /// Read one pixel at TOP-LEFT (x,y) unambiguously via a 1×1 crop.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        guard let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return (0, 0, 0, 0) }
        var b = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &b, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(b[0]), Int(b[1]), Int(b[2]), Int(b[3]))
    }

    private func lum(_ p: (r: Int, g: Int, b: Int, a: Int)) -> Int { (p.r + p.g + p.b) / 3 }

    private func blur(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
                      mode: BlurAnnotation.Mode = .solid, block: Double = 14) -> Annotation {
        .blur(BlurAnnotation(id: "b", x: x, y: y, width: w, height: h, mode: mode, blockSize: block))
    }

    // MARK: - Redaction destroys the original pixels (THE security invariant)

    @Test func solidRedactionIsOpaqueBlack() throws {
        // White canvas with a red square; solid-redact the square.
        let src = makeImage(100, 100) { c in
            c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
        }
        let out = decodePNG(try Flatten.toPNG(image: src, annotations: [blur(20, 20, 40, 40, mode: .solid)], crop: nil))
        let center = pixel(out, 40, 40)
        #expect(center.r < 8 && center.g < 8 && center.b < 8, "solid redaction must be black, got \(center)")
    }

    @Test func mosaicRedactionDestroysHighContrastText() throws {
        // 1px alternating black/white horizontal stripes (stand-in for text) in a
        // region. Source has ~full luminance range there; a mosaic must collapse it.
        let src = makeImage(120, 120) { c in
            c.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            for y in 20..<80 {
                c.setFillColor(CGColor(gray: y % 2 == 0 ? 0 : 1, alpha: 1))
                c.fill(CGRect(x: 20, y: y, width: 60, height: 1))
            }
        }
        // Source: adjacent rows are near-opposite luminance.
        let srcDiff = abs(lum(pixel(src, 40, 40)) - lum(pixel(src, 40, 41)))
        #expect(srcDiff > 150, "source stripes should be high-contrast, got \(srcDiff)")

        let out = decodePNG(try Flatten.toPNG(
            image: src, annotations: [blur(20, 20, 60, 60, mode: .pixelate, block: 16)], crop: nil))
        // After the mosaic, that region is averaged — adjacent rows nearly equal,
        // and no pure black/white survives.
        let outDiff = abs(lum(pixel(out, 40, 40)) - lum(pixel(out, 40, 41)))
        #expect(outDiff < 60, "mosaic should collapse the stripe contrast, got \(outDiff)")
        let p = pixel(out, 40, 40)
        #expect(lum(p) > 40 && lum(p) < 215, "mosaiced pixel should be mid-tone, not pure b/w: \(p)")
    }

    /// The mosaic must not flip the region vertically. A dark-top / light-bottom
    /// split stays dark-top after pixelation; the flip bug reversed it (only
    /// pixelate was affected — solid fill is orientation-free).
    @Test func mosaicPreservesVerticalOrientation() throws {
        let src = makeImage(120, 120) { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            c.setFillColor(CGColor(gray: 0.15, alpha: 1)); c.fill(CGRect(x: 20, y: 20, width: 60, height: 30)) // top band dark
            c.setFillColor(CGColor(gray: 0.85, alpha: 1)); c.fill(CGRect(x: 20, y: 50, width: 60, height: 30)) // bottom band light
        }
        let out = decodePNG(try Flatten.toPNG(
            image: src, annotations: [blur(20, 20, 60, 60, mode: .pixelate, block: 8)], crop: nil))
        let top = lum(pixel(out, 50, 30))
        let bottom = lum(pixel(out, 50, 70))
        #expect(top < bottom - 60, "mosaic must keep dark-top/light-bottom (not flipped): top=\(top) bottom=\(bottom)")
    }

    /// Fail CLOSED: a redaction that overlaps the export but rounds to <1px must
    /// throw, never emit a PNG with an unprotected area.
    @Test func subPixelRedactionFailsClosed() throws {
        let src = makeImage(100, 100) { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        #expect(throws: Flatten.FlattenError.redactionUnbakeable) {
            _ = try Flatten.toPNG(image: src, annotations: [blur(10, 10, 0.4, 0.4)], crop: nil)
        }
    }

    @Test func redactionEntirelyOutsideCropIsIgnored() throws {
        let src = makeImage(100, 100) { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        // Blur at (60,60) but crop is the top-left 50×50 → no overlap, no throw.
        let out = decodePNG(try Flatten.toPNG(
            image: src, annotations: [blur(60, 60, 20, 20)],
            crop: Rect(x: 0, y: 0, width: 50, height: 50)))
        #expect(out.width == 50 && out.height == 50)
        #expect(lum(pixel(out, 25, 25)) > 240) // still white, untouched
    }

    // MARK: - Crop + marker

    @Test func cropProducesExpectedDimensions() throws {
        let src = makeImage(200, 150) { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        }
        let out = decodePNG(try Flatten.toPNG(
            image: src, annotations: [], crop: Rect(x: 10, y: 20, width: 80, height: 60)))
        #expect(out.width == 80 && out.height == 60)
    }

    @Test func clickMarkerIsBaked() throws {
        let src = makeImage(100, 100) { c in
            c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let out = decodePNG(try Flatten.toPNG(
            image: src, annotations: [], crop: nil,
            marker: Flatten.Marker(x: 50, y: 50, color: "#e11d48", radius: 20)))
        // The rose ring should paint reddish pixels around radius 20 from center.
        var foundRed = false
        for dx in [-20, 20] {
            let p = pixel(out, 50 + dx, 50)
            if p.r > 150 && p.g < 120 && p.b < 120 { foundRed = true }
        }
        #expect(foundRed, "click marker ring should be baked into the pixels")
    }

    @Test func plainFlattenPreservesTheImage() throws {
        let src = makeImage(60, 40) { c in
            c.setFillColor(CGColor(srgbRed: 0, green: 0.7, blue: 0.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        let out = decodePNG(try Flatten.toPNG(image: src, annotations: [], crop: nil))
        #expect(out.width == 60 && out.height == 40)
        let p = pixel(out, 30, 20)
        #expect(p.g > 140 && p.r < 80 && p.b < 100, "green fill should survive, got \(p)")
    }
}
