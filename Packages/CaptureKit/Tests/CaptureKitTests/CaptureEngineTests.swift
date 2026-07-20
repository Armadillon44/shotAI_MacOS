import CoreGraphics
import Foundation
import Testing
@testable import CaptureKit
import ShotModel

// The native capture-selftest: session lifecycle, the mousedown pipeline, and
// exact stored-PNG geometry, all headless via fakes. Dimension assertions
// resolve the Windows self-test's downscale inconsistency by asserting
// round(dim × CAPTURE_SCALE) — the downscale path stays ON under test.
@Suite struct CaptureEngineTests {
    // display: 1000x600pt @2x → full grab 2000x1200px → ×0.85 → 1700x1020.
    private let fullW = 1700
    private let fullH = 1020
    // imageScale = pixelScale × downscale = 2 × (1700/2000) = 1.7
    private let imageScale = 1.7

    @Test func hotkeyCapturesFullscreenWithWindowCaption() async throws {
        let h = try EngineHarness()
        // Fake active window is Safari → auto mode classifies 'window', so a
        // hotkey in auto mode crops to the active window bounds.
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        let step = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        #expect(step != nil)
        #expect(step?.caption == "Capture: Apple")
        #expect(step?.click == nil)
        #expect(step?.trigger == .hotkey)
        #expect(step?.window?.app == "Safari")
        #expect(step?.element == .unavailable)
        // Window crop 700x450pt → 1400x900px → ×0.85 → 1190x765.
        let dims = pngSize(try h.shotData(step!))
        #expect(dims.width == 1190)
        #expect(dims.height == 765)
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func clickImageCoordinatesFollowTheSchemaInvariant() async throws {
        let h = try EngineHarness()
        h.activeWindows.snapshot = nil // auto → fullscreen (unknown focus)
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        let p = CGPoint(x: 100, y: 50)
        let step = try await h.engine.captureStep(trigger: .click, point: p)
        #expect(step?.click?.global == Point(x: 100, y: 50))
        // image = round((global − origin) × imageScale); origin = (0,0).
        #expect(step?.click?.image == Point(x: (100 * imageScale).rounded(), y: (50 * imageScale).rounded()))
        #expect(step?.click?.imageScale == imageScale)
        #expect(step?.monitor?.scaleFactor == 2)
        #expect(step?.monitor?.bounds == Rect(x: 0, y: 0, width: 1000, height: 600))
        let dims = pngSize(try h.shotData(step!))
        #expect(dims.width == fullW)
        #expect(dims.height == fullH)
        // The origin must be recoverable: origin = global − image/imageScale.
        let recoveredX = 100 - (step!.click!.image.x / step!.click!.imageScale!)
        #expect(abs(recoveredX) < 1)
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func areaModeCropsExactly() async throws {
        let h = try EngineHarness()
        try await h.engine.start(
            projectPath: h.projectDir, attachHook: false,
            target: CaptureTarget(mode: .area, area: Rect(x: 100, y: 100, width: 300, height: 200)))
        let step = try await h.engine.captureStep(trigger: .click, point: CGPoint(x: 150, y: 150))
        // 300x200pt → 600x400px. The longer edge (600) is below the 1100
        // readability floor, so it is NOT downscaled → 600x400 (imageScale = 2).
        let dims = pngSize(try h.shotData(step!))
        #expect(dims.width == 600)
        #expect(dims.height == 400)
        // Origin = area origin → click at (150,150) maps to (50,50)pt × 2.
        #expect(step?.click?.image == Point(x: 100, y: 100))
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func screenModeKeepsTheChosenFullMonitor() async throws {
        let h = try EngineHarness()
        try await h.engine.start(
            projectPath: h.projectDir, attachHook: false,
            target: CaptureTarget(mode: .screen, monitorId: 7))
        let step = try await h.engine.captureStep(trigger: .click, point: CGPoint(x: 10, y: 10))
        let dims = pngSize(try h.shotData(step!))
        #expect(dims.width == fullW)
        #expect(dims.height == fullH)
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func windowModeCropsToTheResolvedWindow() async throws {
        let h = try EngineHarness()
        h.activeWindows.windowRects[42] = CGRect(x: 200, y: 100, width: 400, height: 300)
        try await h.engine.start(
            projectPath: h.projectDir, attachHook: false,
            target: CaptureTarget(
                mode: .window,
                window: .init(id: 42, pid: 500, title: "Apple")))
        let step = try await h.engine.captureStep(trigger: .click, point: CGPoint(x: 250, y: 150))
        // 400x300pt → 800x600px; below the 1100 readability floor → not
        // downscaled → 800x600.
        let dims = pngSize(try h.shotData(step!))
        #expect(dims.width == 800)
        #expect(dims.height == 600)
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func unresolvableWindowFallsBackToMonitor() async throws {
        let h = try EngineHarness()
        try await h.engine.start(
            projectPath: h.projectDir, attachHook: false,
            target: CaptureTarget(mode: .window, window: .init(id: 999, pid: 1, title: "Gone")))
        let step = try await h.engine.captureStep(trigger: .click, point: CGPoint(x: 10, y: 10))
        let dims = pngSize(try h.shotData(step!))
        #expect(dims.width == fullW) // full monitor fallback
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func autoShellHostGetsRegionCrop() async throws {
        let h = try EngineHarness()
        h.activeWindows.snapshot = WindowSnapshot(
            app: "Dock", title: "Dock", pid: 88, bundleID: "com.apple.dock", bounds: nil)
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        let step = try await h.engine.captureStep(trigger: .click, point: CGPoint(x: 500, y: 590))
        // 820x640pt box, but monitor is 600pt tall → 820x600pt → ×2 ×0.85 → 1394x1020.
        let dims = pngSize(try h.shotData(step!))
        #expect(dims.width == 1394)
        #expect(dims.height == 1020)
        #expect(step?.caption == "Click in Dock")
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func elementNamesFlowIntoCaptions() async throws {
        let h = try EngineHarness()
        h.elements.element = StepElement(
            available: true, name: "Export", controlType: "Button",
            bounds: Rect(x: 300, y: 200, width: 80, height: 30))
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        let step = try await h.engine.captureStep(trigger: .click, point: CGPoint(x: 320, y: 210))
        #expect(step?.caption == "Click 'Export' button in Safari")
        #expect(step?.element.name == "Export")
        _ = await h.engine.stop()
        h.cleanup()
    }

    // MARK: - Own-window exclusion (the exit-test invariant)

    @Test func pillClicksCreateNoSteps() async throws {
        let h = try EngineHarness()
        h.ownWindows.ownFrames = [CGRect(x: 310, y: 8, width: 380, height: 52)] // the pill
        try await h.engine.start(projectPath: h.projectDir)
        await h.tap(CGPoint(x: 400, y: 20), .left) // on the pill
        #expect(try h.readSteps().isEmpty)
        await h.tap(CGPoint(x: 400, y: 200), .left) // below the pill
        #expect(try h.readSteps().count == 1)
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func frontmostOwnAppSuppressesEvenWithoutGeometry() async throws {
        let h = try EngineHarness()
        h.ownWindows.frontmostIsOwn = true
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        let step = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        #expect(step == nil)
        #expect(try h.readSteps().isEmpty)
        _ = await h.engine.stop()
        h.cleanup()
    }

    // MARK: - Pipeline decisions

    @Test func doubleClickCollapsesToOneStep() async throws {
        let h = try EngineHarness()
        try await h.engine.start(projectPath: h.projectDir)
        let p = CGPoint(x: 400, y: 300)
        await h.tap(p, .left)
        h.clock.advance(0.2)
        await h.tap(CGPoint(x: 402, y: 301), .left) // within 400ms + 6pt → dropped
        h.clock.advance(0.15)
        await h.tap(CGPoint(x: 403, y: 300), .left) // chains off the 2nd → dropped too
        h.clock.advance(1.0)
        await h.tap(CGPoint(x: 402, y: 301), .left) // past the window → real step
        #expect(try h.readSteps().count == 2)
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func rightClickThenNearbyLeftClickIsAMenuSelection() async throws {
        let h = try EngineHarness()
        try await h.engine.start(projectPath: h.projectDir)
        await h.tap(CGPoint(x: 400, y: 300), .right)
        h.clock.advance(2)
        await h.tap(CGPoint(x: 450, y: 380), .left) // within 640x680 proximity
        let steps = try h.readSteps()
        #expect(steps.count == 2)
        #expect(steps[0].caption == "Right-click in Safari")
        #expect(steps[1].caption == "Select from context menu in Safari")
        // Selection framing: owner bounds (100,80,700,450) ∪ clickBox(450,380
        // half 620) → (-170,-240)-(1070,1000) clamped to the 1000x600 monitor
        // via cropToRegion → local (0,0, 900x600)pt... right edge = min(-170+1240,
        // 1000) - 0 = 1000, bottom = min(-240+1240, 600) - 0 = 600 → 1000x600pt
        // → ×2 ×0.85 → 1700x1020.
        let dims = pngSize(try h.shotData(steps[1]))
        #expect(dims.width == 1700)
        #expect(dims.height == 1020)
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func farAwayLeftClickDisarmsTheMenu() async throws {
        let h = try EngineHarness()
        try await h.engine.start(projectPath: h.projectDir)
        await h.tap(CGPoint(x: 100, y: 100), .right)
        h.clock.advance(1)
        await h.tap(CGPoint(x: 940, y: 100), .left) // 840pt away > 640 gate
        let steps = try h.readSteps()
        #expect(steps.count == 2)
        #expect(steps[1].caption == "Click in Safari") // plain, not a selection
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func menuChainIsBoundedAtFour() async throws {
        let h = try EngineHarness()
        try await h.engine.start(projectPath: h.projectDir)
        await h.tap(CGPoint(x: 400, y: 300), .right)
        for i in 0..<4 {
            h.clock.advance(0.5)
            await h.tap(CGPoint(x: 410 + CGFloat(i), y: 310), .left)
        }
        let steps = try h.readSteps()
        #expect(steps.count == 5)
        // Selections 1-3 re-arm; the 4th click hits the chain cap...
        #expect(steps[1].caption == "Select from context menu in Safari")
        #expect(steps[3].caption == "Select from context menu in Safari")
        #expect(steps[4].caption == "Select from context menu in Safari")
        // ...so the NEXT nearby click is a plain click again.
        h.clock.advance(0.5)
        await h.tap(CGPoint(x: 412, y: 311), .left)
        // (0.5s gap + 2pt distance: outside the double-click window)
        #expect(try h.readSteps().last?.caption == "Click in Safari")
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func expiredMenuWindowIsNotASelection() async throws {
        let h = try EngineHarness()
        try await h.engine.start(projectPath: h.projectDir)
        await h.tap(CGPoint(x: 400, y: 300), .right)
        h.clock.advance(31) // past the 30s follow-up window
        await h.tap(CGPoint(x: 410, y: 310), .left)
        #expect(try h.readSteps()[1].caption == "Click in Safari")
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func pauseSuppressesTheQueuedBacklog() async throws {
        let h = try EngineHarness()
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        _ = await h.engine.pause()
        let step = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        #expect(step == nil)
        _ = await h.engine.resume()
        let step2 = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        #expect(step2 != nil)
        _ = await h.engine.stop()
        h.cleanup()
    }

    // MARK: - Session guards, filenames, discard

    @Test func sessionGuards() async throws {
        let h = try EngineHarness()
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        // Same project → idempotent no-op.
        let again = try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        #expect(again.status == .recording)
        // Different project → throws.
        let other = h.root + "/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try ProjectJSON.encodeManifest(ProjectManifest(id: "o", title: "O", createdAt: "", updatedAt: ""))
            .write(to: URL(fileURLWithPath: other + "/project.json"))
        await #expect(throws: CaptureEngine.EngineError.recordingInProgressOtherProject) {
            try await h.engine.start(projectPath: other, attachHook: false)
        }
        // An immediate capture refuses while ANY session exists.
        await #expect(throws: CaptureEngine.EngineError.recordingInProgress) {
            try await h.engine.captureImmediate(
                projectPath: h.projectDir, insertAt: 0, target: CaptureTarget(mode: .screen))
        }
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func filenameCounterSeedsPastOrphanShots() async throws {
        let h = try EngineHarness()
        // An orphan from a deleted step: the counter must skip past it.
        FileManager.default.createFile(
            atPath: h.projectDir + "/shots/step-0007.png", contents: Data([0x89]))
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        let step = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        #expect(step?.screenshot == "shots/step-0008.png")
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func filenameCollisionFailsLoudlyInsteadOfOverwriting() async throws {
        let h = try EngineHarness()
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        // Pre-create the file the NEXT capture will target.
        FileManager.default.createFile(
            atPath: h.projectDir + "/shots/step-0001.png", contents: Data([0x89]))
        // Defeat the seed by creating it AFTER start(): the exclusive write
        // must throw, not clobber.
        await #expect(throws: Error.self) {
            try await h.engine.captureStep(trigger: .hotkey, point: nil)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: h.projectDir + "/shots/step-0001.png"))
        #expect(data == Data([0x89])) // original bytes untouched
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func discardDeletesExactlyThisSessionsSteps() async throws {
        let h = try EngineHarness()
        // A pre-existing step from an earlier session.
        try await h.store.addStep(
            at: h.projectDir,
            ProjectStep(id: "old", order: 0, screenshot: "", trigger: .hotkey))
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        _ = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        _ = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        let (state, projectDeleted) = await h.engine.discard()
        #expect(state.status == .idle)
        #expect(!projectDeleted)
        let steps = try h.readSteps()
        #expect(steps.map(\.id) == ["old"]) // session steps gone, old kept
        h.cleanup()
    }

    @Test func discardDeletesAWholeProjectCreatedThisSession() async throws {
        let h = try EngineHarness()
        let created = try await h.store.createProject(title: "Fresh")
        try await h.engine.start(
            projectPath: created.path, attachHook: false, createdThisSession: true)
        _ = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        let (_, projectDeleted) = await h.engine.discard()
        #expect(projectDeleted)
        #expect(!FileManager.default.fileExists(atPath: created.path))
        h.cleanup()
    }

    // The pill's Discard-confirmation wording keys off state.willDeleteProjectOnDiscard;
    // it must match discard()'s own whole-project predicate.
    @Test func stateFlagsWholeProjectDiscardForFreshProject() async throws {
        let h = try EngineHarness()
        let created = try await h.store.createProject(title: "Fresh")
        try await h.engine.start(
            projectPath: created.path, attachHook: false, createdThisSession: true)
        _ = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        #expect(await h.engine.state().willDeleteProjectOnDiscard) // whole-project discard
        h.cleanup()
    }

    @Test func stateDoesNotFlagWholeProjectDiscardWithPriorSteps() async throws {
        let h = try EngineHarness()
        try await h.store.addStep(
            at: h.projectDir,
            ProjectStep(id: "old", order: 0, screenshot: "", trigger: .hotkey))
        // Not created this session (default), and it has a pre-existing step.
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        _ = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        #expect(!(await h.engine.state().willDeleteProjectOnDiscard)) // session-only discard
        h.cleanup()
    }

    @Test func immediateCaptureInsertsClicklessStepAtIndex() async throws {
        let h = try EngineHarness()
        for id in ["a", "b"] {
            try await h.store.addStep(
                at: h.projectDir, ProjectStep(id: id, order: 0, screenshot: "", trigger: .hotkey))
        }
        let target = CaptureTarget(mode: .screen, monitorId: Int(EngineHarness.display.id))
        let step = try await h.engine.captureImmediate(projectPath: h.projectDir, insertAt: 1, target: target)
        #expect(step != nil)
        #expect(step?.click == nil)        // manual capture — no click marker
        #expect(step?.trigger == .hotkey)
        let steps = try h.readSteps()
        #expect(steps.count == 3)
        #expect(steps[1].id == step?.id)   // inserted at index 1
        #expect(steps.map(\.order) == [1, 2, 3])
        // No pill/recording session lingers: a normal recording can start after.
        #expect(await h.engine.state().status == .idle)
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func recordingInsertsStepsAtChosenPositionInOrder() async throws {
        let h = try EngineHarness()
        for id in ["a", "b", "c"] {
            try await h.store.addStep(
                at: h.projectDir, ProjectStep(id: id, order: 0, screenshot: "s", trigger: .hotkey))
        }
        // "Capture steps here" at index 1: captured steps land at 1, 2, … in order.
        try await h.engine.start(projectPath: h.projectDir, attachHook: false, insertAt: 1)
        let s1 = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        let s2 = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        _ = await h.engine.stop()
        let ids = try h.readSteps().map(\.id)
        #expect(ids == ["a", s1?.id, s2?.id, "b", "c"].compactMap { $0 })
        h.cleanup()
    }

    @Test func downscaleContract() {
        // <2px passthrough
        let tiny = makeImage(width: 1, height: 1)
        let (outTiny, sTiny) = ImageOutput.downscale(tiny)
        #expect(sTiny == 1)
        #expect(outTiny.width == 1)
        // Actual scale is post-rounding output/input, not the nominal 0.85.
        // Use a long edge well above the 1100 readability floor so 0.85 applies.
        let img = makeImage(width: 2001, height: 1000)
        let (out, s) = ImageOutput.downscale(img)
        #expect(out.width == 1701) // round(2001 × 0.85)
        #expect(s == CGFloat(1701) / CGFloat(2001))
    }
}
