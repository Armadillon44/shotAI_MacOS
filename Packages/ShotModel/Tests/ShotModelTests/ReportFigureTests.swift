import Foundation
import Testing
@testable import ShotModel

/// The report figure (`ReportPresentation.figureLayout`): what each step's
/// image looks like on screen, and what its zoom buttons and drags do, framed
/// and unframed. The SwiftUI view only draws this.
@Suite struct ReportFigureTests {
    private let wide = 10_000.0   // a column wider than any frame box
    private let square = ShotFrame(width: 1, height: 1)!
    private let fourThree = ShotFrame(width: 4, height: 3)!

    private func shot(zoom: Double? = nil, panX: Double? = nil, panY: Double? = nil,
                      click: (Double, Double)? = nil) -> ProjectStep {
        var s = ProjectStep(id: "s", order: 1, kind: .shot, screenshot: "shots/1.png", trigger: .click)
        s.reportZoom = zoom; s.reportPanX = panX; s.reportPanY = panY
        if let c = click { s.click = StepClick(global: Point(x: 0, y: 0), image: Point(x: c.0, y: c.1), button: .left) }
        return s
    }

    private func layout(_ step: ProjectStep, _ w: Double, _ h: Double, frame: ShotFrame?,
                        fitWidth: Double? = nil, docScale: Double = 1) throws -> ReportPresentation.FigureLayout {
        try #require(ReportPresentation.figureLayout(for: step, imagePixelSize: (w, h), frame: frame,
                                                     docScale: docScale, fitWidth: fitWidth ?? wide))
    }

    private func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol * max(1, abs(b)) }

    // MARK: framed

    /// Every step's frame is the project box, whatever its image: that is what
    /// makes a framed report read as one set of same-size frames.
    @Test func everyFramedStepGetsTheSameBox() throws {
        let box = try #require(FrameGeometry.projectBox(frame: fourThree, docScale: 1))
        for (w, h) in [(1600.0, 1000.0), (300.0, 200.0), (800.0, 1600.0), (5000.0, 200.0), (738.0, 553.5)] {
            let l = try layout(shot(), w, h, frame: fourThree)
            #expect(l.framed)
            #expect(l.boxWidth == box.width && l.boxHeight == box.height, "\(w)x\(h)")
            #expect(l.imageWidth <= l.boxWidth + 1e-9 && l.imageHeight <= l.boxHeight + 1e-9, "fit shows it whole")
        }
        // The box follows the document scale, as the exports' does.
        let small = try layout(shot(), 1600, 1000, frame: fourThree, docScale: 0.75)
        let smallBox = try #require(FrameGeometry.projectBox(frame: fourThree, docScale: 0.75))
        #expect(small.boxWidth == smallBox.width && small.boxHeight == smallBox.height)
    }

    /// A column narrower than the box draws the same framing smaller. It never
    /// reframes: the same part of the image shows, at a smaller size.
    @Test func aNarrowColumnScalesTheFramingDownWithoutReframing() throws {
        let step = shot(zoom: 2, click: (1200, 300))
        let full = try layout(step, 1600, 1000, frame: fourThree)
        let half = try layout(step, 1600, 1000, frame: fourThree, fitWidth: full.boxWidth / 2)
        for (a, b) in [(half.boxWidth, full.boxWidth), (half.boxHeight, full.boxHeight),
                       (half.imageWidth, full.imageWidth), (half.imageHeight, full.imageHeight),
                       (half.offsetX, full.offsetX), (half.offsetY, full.offsetY)] {
            #expect(near(a, b / 2))
        }
        #expect(half.zoom == full.zoom && half.zoomInTarget == full.zoomInTarget)
        // A wider column never enlarges it past the box.
        let wider = try layout(step, 1600, 1000, frame: fourThree, fitWidth: full.boxWidth * 3)
        #expect(wider == full)
    }

    /// Decision 2: a small image is shown at 100% inside the full-size frame,
    /// centred with padding, and there is nothing to drag.
    @Test func aSmallImageIsPaddedAndNeverEnlargedAtFit() throws {
        let l = try layout(shot(), 300, 200, frame: fourThree)
        #expect(l.imageWidth == 300 && l.imageHeight == 200)
        #expect(near(l.offsetX, (l.boxWidth - 300) / 2) && near(l.offsetY, (l.boxHeight - 200) / 2))
        #expect(!l.canPan)
        let o = l.draggedOffset(fromX: l.offsetX, fromY: l.offsetY, dx: 80, dy: -50)
        #expect(o.x == l.offsetX && o.y == l.offsetY, "a padded image does not move")
        let p = l.pan(forOffsetX: o.x, offsetY: o.y)
        #expect(p.x == nil && p.y == nil, "and nothing is written")
    }

    /// The carried PR3 finding: the old drag clamp assumed offsets ≤ 0, which
    /// would snap a padded (positive) axis to the edge on the first drag.
    @Test func aDragLeavesThePaddedAxisCentred() throws {
        // 1600x1000 in a square at zoom 1.25: overflows across, padded down.
        let l = try layout(shot(zoom: 1.25), 1600, 1000, frame: square)
        #expect(l.pannableX && !l.pannableY && l.canPan)
        #expect(l.offsetY > 0, "padded")
        let o = l.draggedOffset(fromX: l.offsetX, fromY: l.offsetY, dx: -40, dy: 120)
        #expect(o.y == l.offsetY)
        #expect(near(o.x, l.offsetX - 40))
        let p = l.pan(forOffsetX: o.x, offsetY: o.y)
        #expect(p.y == nil, "the padded axis is not written, so it keeps following the click")
        #expect(p.x.map { near($0, -o.x / (l.imageWidth - l.boxWidth)) } == true)
    }

    /// The mirror case: a tall image overflows down only.
    @Test func aTallImagePansDownOnly() throws {
        let fit = try layout(shot(), 800, 1600, frame: fourThree)
        let fill = try #require(fit.zoomInTarget)
        let l = try layout(shot(zoom: fill), 800, 1600, frame: fourThree)
        #expect(!l.pannableX && l.pannableY && l.canPan)
        let o = l.draggedOffset(fromX: l.offsetX, fromY: l.offsetY, dx: 30, dy: -30)
        #expect(o.x == l.offsetX && o.y != l.offsetY)
        #expect(l.pan(forOffsetX: o.x, offsetY: o.y).x == nil)
    }

    /// Review finding: fill can leave a point or two of overflow on one axis (a
    /// small image within a hair of the frame's shape). A drag there saved a
    /// pan stuck at 0 or 1, which then overrode the click at the next zoom.
    @Test func aHairOfOverflowIsNotDraggable() throws {
        // 401x300 in 4:3 (738x553.5): fill covers the height exactly and leaves
        // 1 image pixel, about 1.8pt, across.
        let fit = try layout(shot(click: (200, 150)), 401, 300, frame: fourThree)
        let fill = try #require(fit.zoomInTarget)
        let l = try layout(shot(zoom: fill, click: (200, 150)), 401, 300, frame: fourThree)
        #expect(l.imageWidth > l.boxWidth, "it does overflow")
        #expect(!l.pannableX && !l.canPan)
        #expect(l.pan(forOffsetX: l.offsetX - 2, offsetY: l.offsetY).x == nil, "and a drag writes nothing")
        // The same image zoomed further pans.
        let more = try layout(shot(zoom: fill * 1.25, click: (200, 150)), 401, 300, frame: fourThree)
        #expect(more.pannableX && more.pannableY)
    }

    /// The gate is on the overflow as drawn: about 8pt across pans in a wide
    /// window, and the same view drawn at a quarter size (2pt) does not.
    @Test func thePanGateIsInDrawnPoints() throws {
        let fit = try layout(shot(), 1348, 1000, frame: fourThree)
        let fill = try #require(fit.zoomInTarget)
        let full = try layout(shot(zoom: fill), 1348, 1000, frame: fourThree)
        #expect(full.imageWidth - full.boxWidth > 4 && full.imageWidth - full.boxWidth < 16)
        #expect(full.pannableX && !full.pannableY)
        let quarter = try layout(shot(zoom: fill), 1348, 1000, frame: fourThree, fitWidth: full.boxWidth / 4)
        #expect(!quarter.pannableX)
    }

    /// The pan is a fraction of the overflow, whatever offset it is given.
    @Test func thePanIsClampedToTheImage() throws {
        let l = try layout(shot(zoom: 3), 1600, 1000, frame: square)
        let past = l.pan(forOffsetX: 50, offsetY: -1e6)
        #expect(past.x == 0 && past.y == 1)
    }

    @Test func aDragStopsAtTheImagesEdges() throws {
        let l = try layout(shot(zoom: 3), 1600, 1000, frame: square)
        #expect(l.pannableX && l.pannableY)
        let left = l.draggedOffset(fromX: l.offsetX, fromY: l.offsetY, dx: 1e6, dy: 1e6)
        #expect(left.x == 0 && left.y == 0)
        #expect(l.pan(forOffsetX: left.x, offsetY: left.y).x == 0)
        let right = l.draggedOffset(fromX: l.offsetX, fromY: l.offsetY, dx: -1e6, dy: -1e6)
        #expect(near(right.x, -(l.imageWidth - l.boxWidth)) && near(right.y, -(l.imageHeight - l.boxHeight)))
        let p = l.pan(forOffsetX: right.x, offsetY: right.y)
        #expect(p.x.map { near($0, 1) } == true && p.y.map { near($0, 1) } == true)
    }

    /// Decision 1: zoom-in goes fit → fill → ×1.25; zoom-out mirrors it.
    @Test func zoomStepsFitThenFillThenByAQuarter() throws {
        // 1600x1000 in a square: fill is 1.6.
        let fit = try layout(shot(), 1600, 1000, frame: square)
        #expect(fit.zoomInTarget.map { near($0, 1.6) } == true)
        #expect(fit.zoomOutTarget == nil, "fit is the floor")
        let fill = try layout(shot(zoom: 1.6), 1600, 1000, frame: square)
        #expect(fill.zoomInTarget.map { near($0, 2) } == true)
        #expect(fill.zoomOutTarget == 1, "out from fill is fit")
        let two = try layout(shot(zoom: 2), 1600, 1000, frame: square)
        #expect(two.zoomOutTarget.map { near($0, 1.6) } == true)
        let top = try layout(shot(zoom: 4), 1600, 1000, frame: square)
        #expect(top.zoomInTarget == nil && top.maxZoom == 4)
    }

    /// Fill is always reachable, even past the usual 4×: a wide strip in a
    /// square needs 25× to cover it.
    @Test func fillCanBeAboveFour() throws {
        let l = try layout(shot(), 5000, 200, frame: square)
        #expect(l.maxZoom == 25 && l.zoomInTarget == 25)
        let atFill = try layout(shot(zoom: 25), 5000, 200, frame: square)
        #expect(atFill.zoom == 25 && atFill.zoomInTarget == nil)
        #expect(atFill.zoomOutTarget == 1)
        let over = try layout(shot(zoom: 40), 5000, 200, frame: square)
        #expect(over.zoom == 25, "a stored zoom past the maximum is clamped on read")
        #expect(over.zoomInTarget == nil && over.zoomOutTarget == 1, "and the buttons start from the clamped zoom")
        // The same zoom in a wider frame needs less to fill: clamped to that.
        let wider = try layout(shot(zoom: 25), 5000, 200, frame: ShotFrame(width: 16, height: 9)!)
        #expect(near(wider.zoom, 14.0625) && wider.zoomInTarget == nil)
    }

    /// Decision 3: with no saved pan the view centres on the click, clamped at
    /// the edge; a saved axis wins.
    @Test func theDefaultPositionIsTheClick() throws {
        let l = try layout(shot(zoom: 1.6, click: (1500, 500)), 1600, 1000, frame: square)
        #expect(near(l.offsetX, -(l.imageWidth - l.boxWidth)), "clamped at the right edge")
        let middle = try layout(shot(zoom: 3, click: (800, 500)), 1600, 1000, frame: square)
        #expect(near(middle.offsetX, -(middle.imageWidth - middle.boxWidth) / 2))
        let saved = try layout(shot(zoom: 1.6, panX: 0, click: (1500, 500)), 1600, 1000, frame: square)
        #expect(saved.offsetX == 0)
    }

    /// Reset clears a saved pan in a framed project, so it has work to do even
    /// at fit, where the pan does not show.
    @Test func resetIsOfferedForASavedPanInAFramedProject() throws {
        #expect(try !layout(shot(), 1600, 1000, frame: square).canReset)
        #expect(try layout(shot(panX: 0.2), 1600, 1000, frame: square).canReset)
        #expect(try layout(shot(panY: 0.2), 1600, 1000, frame: square).canReset)
        #expect(try layout(shot(zoom: 2), 1600, 1000, frame: square).canReset)
        #expect(try layout(shot(), 1600, 1000, frame: square).resetClearsPan)
    }

    /// A fill within a few percent of fit is still a real step, not a no-op.
    @Test func zoomStepsAreNotSwallowedByTheTolerance() throws {
        // 2880x1800 in 3:2: fill is 16/15 of fit.
        let l = try layout(shot(), 2880, 1800, frame: ShotFrame(width: 3, height: 2)!)
        #expect(l.zoomInTarget.map { near($0, 16.0 / 15.0) } == true)
        #expect(try layout(shot(zoom: 3.814697265625), 1600, 1000, frame: nil).zoomInTarget == 4)
        #expect(try layout(shot(zoom: 4 * (1 - 1e-12)), 1600, 1000, frame: nil).zoomInTarget == nil)
    }

    /// A legacy or hand-edited zoom below 1 reads as fit, in both modes.
    @Test func aZoomBelowOneIsFit() throws {
        for f in [nil, square] as [ShotFrame?] {
            let l = try layout(shot(zoom: 0.5), 1600, 1000, frame: f)
            let one = try layout(shot(), 1600, 1000, frame: f)
            #expect(l.zoom == 1 && l.zoomInTarget == one.zoomInTarget)
            #expect(l.zoomOutTarget == nil && !l.canReset)
        }
    }

    // MARK: unframed

    /// No frame: the report is exactly what it was.
    @Test func unframedProjectsAreUnchanged() throws {
        for zoom in [nil, 1.0, 1.5, 2.5, 4.0] {
            for fitWidth in [wide, 400.0] {
                for docScale in [0.65, 1.0, 1.25] {
                    let step = shot(zoom: zoom, panX: 0.3, panY: 0.8)
                    let l = try layout(step, 1600, 1000, frame: nil, fitWidth: fitWidth, docScale: docScale)
                    let v = try #require(ReportPresentation.viewport(for: step, imagePixelSize: (1600, 1000),
                                                                     fitWidth: fitWidth, docScale: docScale))
                    #expect(!l.framed && !l.resetClearsPan)
                    #expect([l.boxWidth, l.boxHeight, l.imageWidth, l.imageHeight, l.offsetX, l.offsetY]
                            == [v.boxWidth, v.boxHeight, v.imageWidth, v.imageHeight, v.offsetX, v.offsetY])
                    let zoomed = (zoom ?? 1) > 1
                    #expect(l.pannableX == zoomed && l.pannableY == zoomed && l.canPan == zoomed)
                    #expect(l.canReset == ((zoom ?? 1) != 1), "a saved pan alone is not a reset here")
                }
            }
        }
        // Strips zoomed a little overflow only a few points on their short axis,
        // and tiny images less still: half a point is the unframed threshold.
        let strip = try layout(shot(zoom: 1.25), 1600, 200, frame: nil)
        #expect(strip.pannableX && strip.pannableY)
        let tall = try layout(shot(zoom: 1.25), 200, 1600, frame: nil)
        #expect(tall.pannableX && tall.pannableY)
        let tiny = try layout(shot(zoom: 1.25), 4, 4, frame: nil)
        #expect(tiny.pannableX && tiny.pannableY, "1pt of overflow")
        let dot = try layout(shot(zoom: 1.25), 1, 1, frame: nil)
        #expect(!dot.pannableX && !dot.pannableY, "a quarter point is not")
        let one = try layout(shot(), 1600, 1000, frame: nil)
        #expect(one.zoomInTarget == 1.25 && one.zoomOutTarget == nil && one.maxZoom == 4)
        let four = try layout(shot(zoom: 4), 1600, 1000, frame: nil)
        #expect(four.zoomInTarget == nil && four.zoomOutTarget == 3.2)
        // A zoom above 4, kept from a framed project whose frame was removed.
        let kept = try layout(shot(zoom: 9), 1600, 1000, frame: nil)
        #expect(kept.zoom == 4 && kept.zoomInTarget == nil && kept.zoomOutTarget == 3.2)
    }

    // MARK: report and export

    /// Spec #160 "Report/export parity": in frame mode the report's visible
    /// region is the export's crop, and its padding is the export's, across
    /// frames, image shapes, zooms, clicks, document scales and column widths.
    @Test func theReportShowsWhatTheExportShips() throws {
        let images: [(Double, Double)] = [(1600, 1000), (2880, 1800), (300, 200), (800, 1600), (5000, 200), (1200, 1200)]
        let clicks: [(Double, Double)?] = [nil, (10, 10), (0.5, 0.5), (0.97, 0.4)]
        var checked = 0
        for frame in ShotFrame.presets {
            for docScale in [0.65, 1.0, 1.25] {
                let box = try #require(FrameGeometry.projectBox(frame: frame, docScale: docScale))
                for (w, h) in images {
                    for zoom in [1.0, 1.25, 1.6, 2.2, 4.0] {
                        for click in clicks {
                            // Fractions are of the image; (10, 10) is a corner in pixels.
                            let c = click.map { $0.0 <= 1 ? ($0.0 * w, $0.1 * h) : $0 }
                            let step = shot(zoom: zoom, click: c)
                            for fitWidth in [wide, box.width * 0.6] {
                                let l = try layout(step, w, h, frame: frame, fitWidth: fitWidth, docScale: docScale)
                                let pan = FrameGeometry.pan(for: step, imageWidth: w, imageHeight: h, box: box)
                                let x = try #require(FrameGeometry.exportLayout(
                                    imageWidth: Int(w), imageHeight: Int(h), box: box, zoom: zoom, panX: pan.x, panY: pan.y))
                                let s = l.imageWidth / w   // display points per image pixel
                                let visX = max(0, -l.offsetX) / s, visW = min(l.boxWidth, l.imageWidth) / s
                                let visY = max(0, -l.offsetY) / s, visH = min(l.boxHeight, l.imageHeight) / s
                                let at = "\(frame.rawValue) \(docScale) \(w)x\(h) z\(zoom) \(String(describing: c)) col \(fitWidth)"
                                #expect(abs(Double(x.cropWidth) - visW) <= 0.5 + 1e-6, "\(at)")
                                #expect(abs(Double(x.cropHeight) - visH) <= 0.5 + 1e-6, "\(at)")
                                #expect(abs(Double(x.cropX) - visX) <= 1, "\(at)")
                                #expect(abs(Double(x.cropY) - visY) <= 1, "\(at)")
                                // The padding: where the image starts in the frame, as a share of it.
                                #expect(abs(Double(x.originX) / Double(x.canvasWidth) - max(0, l.offsetX) / l.boxWidth)
                                        <= 1.0 / Double(x.canvasWidth) + 1e-9, "\(at)")
                                #expect(abs(Double(x.originY) / Double(x.canvasHeight) - max(0, l.offsetY) / l.boxHeight)
                                        <= 1.0 / Double(x.canvasHeight) + 1e-9, "\(at)")
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == 5 * 3 * 6 * 5 * 4 * 2)
    }
}

/// The report pan is clearable, which Reset needs (spec #160).
@Suite struct ReportPanPatch {
    private func step() -> ProjectStep {
        var s = ProjectStep(id: "s1", order: 1, screenshot: "shots/step-0001.png", trigger: .click)
        s.reportZoom = 2; s.reportPanX = 0.3; s.reportPanY = 0.7
        s.flattened = "export/.render/s1.png"; s.markerBaked = true
        return s
    }

    @Test func anUnsetPanIsLeftAlone() {
        var s = step()
        var p = StepPatch(); p.reportZoom = 1.5
        applyPatchAndInvalidate(&s, p, hasFreshPng: false)
        #expect(s.reportZoom == 1.5 && s.reportPanX == 0.3 && s.reportPanY == 0.7)
    }

    @Test func eachAxisCanBeSetOrClearedAlone() {
        var s = step()
        var p = StepPatch(); p.reportPanX = .set(nil)
        applyPatchAndInvalidate(&s, p, hasFreshPng: false)
        #expect(s.reportPanX == nil && s.reportPanY == 0.7)
        var q = StepPatch(); q.reportPanY = .set(0.1)
        applyPatchAndInvalidate(&s, q, hasFreshPng: false)
        #expect(s.reportPanX == nil && s.reportPanY == 0.1)
    }

    /// The report view is display-only: changing it keeps the baked render.
    @Test func aPanChangeKeepsTheRender() {
        var s = step()
        var p = StepPatch(); p.reportZoom = 1; p.reportPanX = .set(nil); p.reportPanY = .set(nil)
        applyPatchAndInvalidate(&s, p, hasFreshPng: false)
        #expect(s.flattened == "export/.render/s1.png" && s.markerBaked == true)
    }

    /// A cleared pan leaves project.json, rather than being written as null.
    @Test func aClearedPanIsRemovedFromDisk() async throws {
        let root = NSTemporaryDirectory() + "shotai-pan-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dir = root + "/proj"
        try FileManager.default.createDirectory(atPath: dir + "/shots", withIntermediateDirectories: true)
        var m = ProjectManifest(id: "p", title: "T", createdAt: "", updatedAt: "")
        var s = ProjectStep(id: "s1", order: 1, screenshot: "shots/step-0001.png", trigger: .click)
        s.reportZoom = 2; s.reportPanX = 0.3; s.reportPanY = 0.7
        m.steps = [s]
        try ProjectJSON.encodeManifest(m).write(to: URL(fileURLWithPath: dir + "/project.json"))
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        var p = StepPatch(); p.reportZoom = 1; p.reportPanX = .set(nil); p.reportPanY = .set(nil)
        _ = try await store.updateStep(at: dir, stepId: "s1", patch: p, flattenedPng: nil)
        let raw = try String(contentsOfFile: dir + "/project.json", encoding: .utf8)
        #expect(!raw.contains("reportPanX") && !raw.contains("reportPanY"))
        #expect(raw.contains("\"reportZoom\" : 1") || raw.contains("\"reportZoom\":1"))
    }
}
