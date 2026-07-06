import CoreGraphics
import Foundation
import Testing
@testable import CaptureKit
import ShotModel

// Regression tests for the confirmed Phase B review findings.
@Suite struct ReviewFixTests {
    // display: 1000x600pt @2x → 2000x1200px → ×0.85 → 1700x1020.
    private let fullW = 1700
    private let fullH = 1020

    // #13/#4: a capture whose session is cleared mid-flight must NOT write a
    // phantom step-0000.png or resurrect a step into the (discarded) manifest.
    @Test func captureBailsWhenSessionClearedMidFlight() async throws {
        let h = try EngineHarness()
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        h.activeWindows.enableGate() // captureStep will suspend at activeWindow()

        let capture = Task { try await h.engine.captureStep(trigger: .hotkey, point: nil) }
        // Wait until captureStep is parked inside activeWindow().
        var it = h.activeWindows.entered.stream.makeAsyncIterator()
        _ = await it.next()

        // Tear the session down while the capture is suspended, then let it go.
        _ = await h.engine.stop()
        h.activeWindows.release()

        let step = try await capture.value
        #expect(step == nil) // no step committed
        #expect(try h.readSteps().isEmpty)
        // The phantom-filename regression: no step-0000.png (or any shot).
        let shots = (try? FileManager.default.contentsOfDirectory(atPath: h.projectDir + "/shots")) ?? []
        #expect(shots.isEmpty, "no orphan shot written on teardown: \(shots)")
        h.cleanup()
    }

    // #14: a hostile orphan filename (Int.max) must clamp, not overflow-trap on
    // the first `stepCount += 1`.
    @Test func hostileOrphanFilenameClampsInsteadOfCrashing() async throws {
        let h = try EngineHarness()
        FileManager.default.createFile(
            atPath: h.projectDir + "/shots/step-9223372036854775807.png",
            contents: Data([0x89]))
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        let step = try await h.engine.captureStep(trigger: .hotkey, point: nil)
        // Seed clamps to 1_000_000 → first capture is 1_000_001.
        #expect(step?.screenshot == "shots/step-1000001.png")
        _ = await h.engine.stop()
        h.cleanup()
    }

    @Test func shotFilenameNumberClampsOversizedValues() {
        #expect(CaptureConstants.shotFilenameNumber("step-0007.png") == 7)
        #expect(CaptureConstants.shotFilenameNumber("step-9223372036854775807.png")
            == CaptureConstants.maxOrphanStepNumber)
        #expect(CaptureConstants.shotFilenameNumber("step-99999999999999999999.png") == nil) // Int() nil
        #expect(CaptureConstants.shotFilenameNumber("notashot.png") == nil)
    }

    // #10: the strict containing-display resolver returns nil off every
    // display, so the `?? clickDisplay` fallback in grab() can actually fire —
    // while the click/hotkey resolver keeps its primary fallback.
    @Test func strictDisplayResolutionHasNoPrimaryFallback() {
        let primary = DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                  pixelScale: 2, isPrimary: true, name: "P")
        let secondary = DisplayInfo(id: 2, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1200),
                                    pixelScale: 1, isPrimary: false, name: "S")
        let displays = [primary, secondary]
        // A window origin dragged off the left edge of the arrangement.
        let off = CGPoint(x: -2200, y: 100)
        #expect(GrabMath.display(containing: off, in: displays) == nil)
        // The click/hotkey resolver still falls back to primary.
        #expect(GrabMath.display(for: off, in: displays)?.id == 1)
        // A point that IS on the secondary resolves to it either way.
        #expect(GrabMath.display(containing: CGPoint(x: -1000, y: 100), in: displays)?.id == 2)
    }

    // #30: window mode with a nil window ref must fall back to the full
    // monitor, NOT silently crop to the active window.
    @Test func windowModeNilRefFallsBackToMonitor() async throws {
        let h = try EngineHarness()
        // Active window present (would be wrongly used by the old else-branch).
        h.activeWindows.snapshot = WindowSnapshot(
            app: "Safari", title: "x", pid: 1, bundleID: "com.apple.Safari",
            bounds: CGRect(x: 100, y: 100, width: 300, height: 200))
        try await h.engine.start(
            projectPath: h.projectDir, attachHook: false,
            target: CaptureTarget(mode: .window, window: nil))
        let step = try await h.engine.captureStep(trigger: .click, point: CGPoint(x: 150, y: 150))
        let dims = pngSize(try h.shotData(step!))
        #expect(dims.width == fullW) // full monitor, not the 300x200 window
        _ = await h.engine.stop()
        h.cleanup()
    }

    // #29: an auto-mode click OUTSIDE the frontmost app's window (the desktop
    // case, where Finder is frontmost with an unrelated window) must fullscreen,
    // not crop to a window the user never clicked.
    @Test func autoClickOutsideActiveWindowFullscreens() async throws {
        let h = try EngineHarness()
        h.activeWindows.snapshot = WindowSnapshot(
            app: "Finder", title: "Documents", pid: 9, bundleID: "com.apple.finder",
            bounds: CGRect(x: 100, y: 80, width: 400, height: 300))
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        // Click far outside the Finder window bounds (on the "desktop").
        let step = try await h.engine.captureStep(trigger: .click, point: CGPoint(x: 900, y: 550))
        let dims = pngSize(try h.shotData(step!))
        #expect(dims.width == fullW) // fullscreen, not the 400x300 Finder window
        #expect(dims.height == fullH)
        _ = await h.engine.stop()
        h.cleanup()
    }

    // Deferred finding: symlinked `shots/` residual. A hostile/shared project
    // whose `shots` is a symlink out of the folder must not redirect writes.
    // start()'s mkdir refuses it up front, before any session is installed.
    @Test func startRefusesASymlinkedShotsFolder() async throws {
        let h = try EngineHarness()
        let fm = FileManager.default
        let hostile = h.root + "/hostile"
        let outside = h.root + "/outside"
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: hostile, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: hostile + "/shots", withDestinationPath: outside)
        try ProjectJSON.encodeManifest(ProjectManifest(id: "h", title: "H", createdAt: "", updatedAt: ""))
            .write(to: URL(fileURLWithPath: hostile + "/project.json"))

        await #expect(throws: CaptureEngine.EngineError.shotsPathNotConfined) {
            try await h.engine.start(projectPath: hostile, attachHook: false)
        }
        #expect(await h.engine.state().status == .idle) // refused before recording
        h.cleanup()
    }

    // The write path re-checks, so a symlink swapped in AFTER start() (past the
    // mkdir) still can't redirect the PNG out of the project.
    @Test func captureWriteRefusesASymlinkSwappedInMidSession() async throws {
        let h = try EngineHarness() // projectDir starts with a real shots/ dir
        let fm = FileManager.default
        let outside = h.root + "/outside"
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        try fm.removeItem(atPath: h.projectDir + "/shots")
        try fm.createSymbolicLink(atPath: h.projectDir + "/shots", withDestinationPath: outside)

        await #expect(throws: CaptureEngine.EngineError.shotsPathNotConfined) {
            try await h.engine.captureStep(trigger: .hotkey, point: nil)
        }
        let leaked = (try? fm.contentsOfDirectory(atPath: outside)) ?? []
        #expect(leaked.isEmpty, "no PNG leaked through the symlink: \(leaked)")
        _ = await h.engine.stop()
        h.cleanup()
    }

    // #29 counterpart: a click INSIDE the active window still crops to it.
    @Test func autoClickInsideActiveWindowCropsToIt() async throws {
        let h = try EngineHarness()
        h.activeWindows.snapshot = WindowSnapshot(
            app: "Safari", title: "x", pid: 1, bundleID: "com.apple.Safari",
            bounds: CGRect(x: 100, y: 80, width: 400, height: 300))
        try await h.engine.start(projectPath: h.projectDir, attachHook: false)
        let step = try await h.engine.captureStep(trigger: .click, point: CGPoint(x: 200, y: 180))
        let dims = pngSize(try h.shotData(step!))
        // 400x300pt → 800x600px → ×0.85 → 680x510.
        #expect(dims.width == 680)
        #expect(dims.height == 510)
        _ = await h.engine.stop()
        h.cleanup()
    }
}
