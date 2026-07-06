import CoreGraphics
import Testing
@testable import CaptureKit

// Crop geometry ported formula-for-formula — these tests pin the Windows
// clamp semantics, including the deliberate areaCrop/cropToRegion difference.
@Suite struct GrabMathTests {
    let monitor = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    let secondary = CGRect(x: 2560, y: -200, width: 1920, height: 1080)

    @Test func cropToRegionInsideMonitor() {
        let crop = GrabMath.cropToRegion(monitor: monitor, region: CGRect(x: 100, y: 200, width: 800, height: 600))
        #expect(crop.local == CGRect(x: 100, y: 200, width: 800, height: 600))
        #expect(crop.originX == 100)
        #expect(crop.originY == 200)
    }

    @Test func cropToRegionShrinksARegionHangingOffTheLeft() {
        // Right edge computed from the UNCLAMPED local origin: a region 300pt
        // off the left edge loses those 300pt.
        let crop = GrabMath.cropToRegion(monitor: monitor, region: CGRect(x: -300, y: 0, width: 800, height: 600))
        #expect(crop.local == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(crop.originX == 0)
    }

    @Test func cropToRegionOnSecondaryMonitorUsesMonitorLocalSpace() {
        let crop = GrabMath.cropToRegion(monitor: secondary, region: CGRect(x: 2660, y: -100, width: 400, height: 300))
        #expect(crop.local == CGRect(x: 100, y: 100, width: 400, height: 300))
        #expect(crop.originX == 2660)
        #expect(crop.originY == -100)
    }

    @Test func areaCropKeepsFullWidthWhenAreaHangsOffTheLeft() {
        // The preserved Windows quirk: cropX clamps to 0 but the width stays
        // a.width (extending right), NOT shrunk by the off-screen amount.
        let crop = GrabMath.areaCrop(monitor: monitor, area: CGRect(x: -300, y: 100, width: 800, height: 600))
        #expect(crop.local == CGRect(x: 0, y: 100, width: 800, height: 600))
    }

    @Test func areaCropClampsToMonitorEdges() {
        let crop = GrabMath.areaCrop(monitor: monitor, area: CGRect(x: 2400, y: 1300, width: 500, height: 400))
        #expect(crop.local == CGRect(x: 2400, y: 1300, width: 160, height: 140))
        #expect(crop.originX == 2400)
    }

    @Test func regionCropCentersOnClickAndShiftsToStayOnMonitor() {
        // Centered: click in the middle.
        let center = GrabMath.regionCrop(monitor: monitor, point: CGPoint(x: 1280, y: 720))
        #expect(center.local.width == 820)
        #expect(center.local.height == 640)
        #expect(center.local.minX == 870) // 1280 − 410
        #expect(center.local.minY == 400) // 720 − 320
        // Near a corner: shifted, not shrunk.
        let corner = GrabMath.regionCrop(monitor: monitor, point: CGPoint(x: 10, y: 1435))
        #expect(corner.local == CGRect(x: 0, y: 1440 - 640, width: 820, height: 640))
    }

    @Test func regionCropShrinksOnlyWhenMonitorIsSmallerThanTheBox() {
        let tiny = CGRect(x: 0, y: 0, width: 640, height: 480)
        let crop = GrabMath.regionCrop(monitor: tiny, point: CGPoint(x: 320, y: 240))
        #expect(crop.local == CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    @Test func clickBoxIsSymmetric1240Square() {
        let box = GrabMath.clickBox(point: CGPoint(x: 1000, y: 500))
        #expect(box == CGRect(x: 380, y: -120, width: 1240, height: 1240))
    }

    @Test func unionRect() {
        let u = GrabMath.unionRect(
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 50, y: -50, width: 200, height: 100))
        #expect(u == CGRect(x: 0, y: -50, width: 250, height: 150))
    }

    @Test func displayResolutionPrefersHitThenPrimaryThenFirst() {
        let a = DisplayInfo(id: 1, frame: monitor, pixelScale: 2, isPrimary: true, name: "A")
        let b = DisplayInfo(id: 2, frame: secondary, pixelScale: 1, isPrimary: false, name: "B")
        #expect(GrabMath.display(for: CGPoint(x: 3000, y: 100), in: [a, b])?.id == 2)
        #expect(GrabMath.display(for: CGPoint(x: 9999, y: 9999), in: [a, b])?.id == 1) // primary fallback
        #expect(GrabMath.display(for: nil, in: [b])?.id == 2) // first fallback
    }

    @Test func chebyshevDistanceIsPerAxis() {
        // 5 right + 5 down is within a 6pt gate even though Euclidean > 6.
        #expect(GrabMath.withinDistance(CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), dx: 6, dy: 6))
        #expect(!GrabMath.withinDistance(CGPoint(x: 0, y: 0), CGPoint(x: 7, y: 0), dx: 6, dy: 6))
    }
}
