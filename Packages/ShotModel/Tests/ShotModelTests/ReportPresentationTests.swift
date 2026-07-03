import Testing
@testable import ShotModel

// The rendering rules ported from Report.tsx — these are what "renders a
// Windows project correctly" means, minus the pixels.
@Suite struct ReportPresentationTests {
    private func shotStep(
        id: String = "s",
        click: StepClick? = nil,
        crop: Rect? = nil,
        flattened: String? = nil,
        markerBaked: Bool? = nil,
        markerColor: String? = nil,
        zoom: Double? = nil
    ) -> ProjectStep {
        ProjectStep(
            id: id, order: 1, screenshot: "shots/step-0001.png", trigger: .click,
            click: click, crop: crop, markerColor: markerColor,
            flattened: flattened, markerBaked: markerBaked, reportZoom: zoom
        )
    }

    private func click(_ x: Double, _ y: Double, button: MouseButton = .left) -> StepClick {
        StepClick(global: Point(x: x, y: y), image: Point(x: x, y: y), button: button)
    }

    private func textStep(id: String, callout: CalloutKind? = nil) -> ProjectStep {
        ProjectStep(id: id, order: 1, kind: .text, screenshot: "", trigger: .hotkey, callout: callout)
    }

    @Test func calloutsAreNotNumbered() {
        let steps = [
            shotStep(id: "a"),
            textStep(id: "b"), // plain text steps ARE numbered
            textStep(id: "c", callout: .note), // callouts are not
            shotStep(id: "d"),
        ]
        let nums = ReportPresentation.displayNumbers(for: steps)
        #expect(nums == ["a": 1, "b": 2, "d": 3])
    }

    @Test func markerColorMatchesAnnotationsTs() {
        #expect(ReportPresentation.markerColorHex(for: shotStep(click: click(1, 1))) == "#e11d48")
        #expect(ReportPresentation.markerColorHex(for: shotStep(click: click(1, 1, button: .right))) == "#2563eb")
        #expect(ReportPresentation.markerColorHex(for: shotStep(click: click(1, 1, button: .right), markerColor: "#00ff00")) == "#00ff00")
    }

    @Test func flattenedRenderIsPreferredOverRawScreenshot() {
        #expect(ReportPresentation.displayImagePath(for: shotStep()) == "shots/step-0001.png")
        #expect(ReportPresentation.displayImagePath(for: shotStep(flattened: "export/.render/s.png")) == "export/.render/s.png")
        #expect(ReportPresentation.displayImagePath(for: textStep(id: "t")) == nil)
    }

    @Test func markerOverlaySkippedWhenBakedIntoThePixels() {
        let step = shotStep(click: click(100, 50), flattened: "export/.render/s.png", markerBaked: true)
        #expect(ReportPresentation.markerFraction(for: step, displayedImageSize: (200, 100)) == nil)
    }

    @Test func markerFractionSubtractsCropOriginOnFlattenedRenders() {
        // Click at image px (565+200, 390+120), crop origin (200,120), cropped
        // render 1200x700 → marker at (565/1200, 390/700). Fixture step 2 shape.
        let step = shotStep(
            click: click(765, 510),
            crop: Rect(x: 200, y: 120, width: 1200, height: 700),
            flattened: "export/.render/s.png",
            markerBaked: false
        )
        let f = ReportPresentation.markerFraction(for: step, displayedImageSize: (1200, 700))
        #expect(f != nil)
        #expect(abs((f?.x ?? 0) - 565.0 / 1200.0) < 1e-9)
        #expect(abs((f?.y ?? 0) - 390.0 / 700.0) < 1e-9)
    }

    @Test func markerHiddenWhenClickFallsOutsideTheCrop() {
        let step = shotStep(
            click: click(50, 50), // left of the crop
            crop: Rect(x: 200, y: 120, width: 1200, height: 700),
            flattened: "export/.render/s.png"
        )
        #expect(ReportPresentation.markerFraction(for: step, displayedImageSize: (1200, 700)) == nil)
    }

    @Test func markerUsesRawImageSpaceWhenNotFlattened() {
        // A crop with NO flattened render isn't applied to the displayed image
        // (crop is applied at flatten time), so no offset is subtracted.
        let step = shotStep(click: click(100, 50), crop: Rect(x: 90, y: 40, width: 10, height: 10))
        let f = ReportPresentation.markerFraction(for: step, displayedImageSize: (200, 100))
        #expect(f?.x == 0.5)
        #expect(f?.y == 0.5)
    }

    @Test func viewportAtZoom1FitsWithinTheBaseBox() {
        let v = ReportPresentation.viewport(for: shotStep(), imagePixelSize: (2176, 1224))
        // 2176x1224 fit in 820x600 → scale 820/2176, box == image, no pan.
        #expect(v != nil)
        #expect(abs((v?.boxWidth ?? 0) - 820) < 1e-9)
        #expect(v?.imageWidth == v?.boxWidth)
        #expect(v?.offsetX == 0)
        #expect(v?.offsetY == 0)
    }

    @Test func viewportAtZoom2KeepsTheBoxAndOverflowsTheImage() {
        let v = ReportPresentation.viewport(for: shotStep(zoom: 2), imagePixelSize: (820, 600))
        #expect(v?.boxWidth == 820)
        #expect(v?.boxHeight == 600)
        #expect(v?.imageWidth == 1640)
        // Default pan is centered: offset = -(1640-820)*0.5.
        #expect(v?.offsetX == -410)
    }

    @Test func smallImagesAreNotUpscaledAtZoom1() {
        let v = ReportPresentation.viewport(for: shotStep(), imagePixelSize: (400, 300))
        #expect(v?.boxWidth == 400)
        #expect(v?.imageHeight == 300)
    }
}
