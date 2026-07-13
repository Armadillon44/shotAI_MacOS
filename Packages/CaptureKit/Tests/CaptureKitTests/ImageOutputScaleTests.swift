import CoreGraphics
import Testing
@testable import CaptureKit

/// The configurable screenshot-quality downscale (Settings ▸ Capture). The
/// engine passes the user's scale into ImageOutput; the ACTUAL applied scale is
/// what flows into click.imageScale, so coordinates stay self-consistent.
@Suite struct ImageOutputScaleTests {
    private func solidImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func downscaleUsesProvidedScaleWhenWellAboveTheFloor() {
        // 3000px longer edge: floor (1100) is far below, so 0.5 applies fully.
        let (out, applied) = ImageOutput.downscale(solidImage(3000, 2000), scale: 0.5)
        #expect(out.width == 1500)
        #expect(out.height == 1000)
        #expect(abs(applied - 0.5) < 0.01)
    }

    @Test func readabilityFloorClampsTheLongEdgeToMinimum() {
        // 1600px longer edge at 0.5 would give 800; the floor (1100/1600 ≈ 0.6875)
        // wins, so the longer edge lands at ~1100.
        let (out, _) = ImageOutput.downscale(solidImage(1600, 1000), scale: 0.5)
        #expect(out.width == 1100)
    }

    @Test func smallCapturesAreNotDownscaledAtAll() {
        // Longer edge already below the floor → returned untouched even at 0.5.
        let (out, applied) = ImageOutput.downscale(solidImage(800, 600), scale: 0.5)
        #expect(out.width == 800)
        #expect(applied == 1)
    }

    @Test func downscaleAtOneIsANoOp() {
        let (out, applied) = ImageOutput.downscale(solidImage(3000, 2000), scale: 1.0)
        #expect(out.width == 3000)
        #expect(applied == 1)
    }

    @Test func clampBoundsAndFallback() {
        #expect(CaptureConstants.clampCaptureScale(0.1) == CaptureConstants.captureScaleMin)
        #expect(CaptureConstants.clampCaptureScale(2.0) == CaptureConstants.captureScaleMax)
        #expect(abs(CaptureConstants.clampCaptureScale(0.7) - 0.7) < 0.0001)
        #expect(CaptureConstants.clampCaptureScale(.nan) == CaptureConstants.captureScale)
    }
}
