import CaptureKit
import CoreGraphics
import Foundation
import ShotModel

// Live end-to-end smoke test for the capture stack — drives the REAL
// SCKScreenshotter / SystemWindowProvider / AXElementLocator through the actual
// CaptureEngine, the way the Windows capture-selftest.ts does. Requires Screen
// Recording permission (SCK); Accessibility is optional (element names fail
// soft). Run: `swift run CaptureSelfTest`.

@main
enum CaptureSelfTest {
    static func main() async {
        var passed = true
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("  [\(ok ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { passed = false }
        }

        print("shotAI capture self-test\n")

        // --- 1. Services ---
        print("Services:")
        let screenshotter = SCKScreenshotter()
        let windows = SystemWindowProvider()

        var displays: [DisplayInfo] = []
        do {
            displays = try await screenshotter.displays()
            check("SCK displays enumerated", !displays.isEmpty,
                  displays.map { "#\($0.id) \(Int($0.frame.width))x\(Int($0.frame.height))@\($0.pixelScale)x" }.joined(separator: ", "))
        } catch {
            check("SCK displays enumerated", false, "\(error) — grant Screen Recording and retry")
            print("\n[capture-test] FAIL")
            exit(1)
        }
        guard let primary = displays.first(where: \.isPrimary) ?? displays.first else {
            print("\n[capture-test] FAIL (no display)")
            exit(1)
        }

        if let frame = try? await screenshotter.captureDisplay(primary.id) {
            check("Primary display captured", frame.image.width > 0,
                  "\(frame.image.width)x\(frame.image.height)px")
        } else {
            check("Primary display captured", false)
        }

        let active = await windows.activeWindow()
        check("Active window resolved", true, active.map { "\($0.app) — '\($0.title)'" } ?? "(none)")

        let axTrusted = CapturePermission.accessibility.isGranted()
        print("  [info] Accessibility: \(axTrusted ? "granted (element names on)" : "not granted (captions fall back to window-only)")")

        // --- 2. Pipeline: one hotkey capture end-to-end ---
        print("\nPipeline (hotkey capture → step + PNG on disk):")
        let root = NSTemporaryDirectory() + "shotai-selftest-\(UUID().uuidString)"
        let settings = InMemorySettings(projectsDir: root)
        let store = ProjectStore(settings: settings)
        defer { try? FileManager.default.removeItem(atPath: root) }

        do {
            let project = try await store.createProject(title: "Self-Test")
            let engine = makeEngine(store: store, screenshotter: screenshotter, windows: windows)
            try await engine.start(projectPath: project.path, attachHook: false)
            let step = try await engine.captureStep(trigger: .hotkey, point: nil)
            _ = await engine.stop()

            let opened = try await store.openProject(at: project.path)
            check("Exactly one step recorded", opened.manifest.steps.count == 1,
                  "count=\(opened.manifest.steps.count)")
            if let step, let first = opened.manifest.steps.first {
                check("Step id persisted", step.id == first.id)
                check("Caption generated", !step.caption.isEmpty, "\"\(step.caption)\"")
                check("Monitor recorded", step.monitor != nil)
                let shotPath = confinePath(dir: opened.dir, rel: step.screenshot)
                let size = shotPath.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int) ?? nil } ?? 0
                check("Shot PNG on disk & non-empty", size > 0, "\(step.screenshot), \(size / 1024) KB")
            } else {
                check("Step returned", false)
            }
        } catch {
            check("Pipeline ran", false, "\(error)")
        }

        // --- 3. Modes: screen (full monitor) and area (cropped) ---
        print("\nModes (dimension checks vs the downscale contract):")
        let downscale = 0.85
        let expectedScreenW = Int((Double(Int((primary.frame.width * primary.pixelScale).rounded())) * downscale).rounded())

        let (sw, sh) = await runMode(
            "screen", store: store, screenshotter: screenshotter, windows: windows,
            target: CaptureTarget(mode: .screen, monitorId: Int(primary.id)),
            point: CGPoint(x: primary.frame.minX + 100, y: primary.frame.minY + 100))
        check("screen mode ≈ full monitor × 0.85", abs(sw - expectedScreenW) <= 2,
              "\(sw)x\(sh)px (expected ~\(expectedScreenW) wide)")

        let areaW = 300, areaH = 200
        let expAreaW = Int((Double(areaW) * Double(primary.pixelScale) * downscale).rounded())
        let expAreaH = Int((Double(areaH) * Double(primary.pixelScale) * downscale).rounded())
        let (aw, ah) = await runMode(
            "area", store: store, screenshotter: screenshotter, windows: windows,
            target: CaptureTarget(mode: .area, area: Rect(
                x: primary.frame.minX + 100, y: primary.frame.minY + 100,
                width: Double(areaW), height: Double(areaH))),
            point: CGPoint(x: primary.frame.minX + 150, y: primary.frame.minY + 150))
        check("area mode ≈ 300x200 × scale × 0.85", abs(aw - expAreaW) <= 2 && abs(ah - expAreaH) <= 2,
              "\(aw)x\(ah)px (expected ~\(expAreaW)x\(expAreaH))")

        print("\n[capture-test] \(passed ? "PASS" : "FAIL")")
        exit(passed ? 0 : 1)
    }

    static func makeEngine(store: ProjectStore, screenshotter: SCKScreenshotter, windows: SystemWindowProvider) -> CaptureEngine {
        CaptureEngine(
            store: store,
            screenshotter: screenshotter,
            activeWindows: windows,
            elements: AXElementLocator(),
            ownWindows: NullOwnWindows(), // no app windows in a CLI run
            triggers: NullTriggers() // attachHook:false — never used here
        )
    }

    /// Capture one step in a fresh temp project under the given target and hand
    /// the written PNG's pixel dimensions to `assert`.
    static func runMode(
        _ label: String,
        store: ProjectStore,
        screenshotter: SCKScreenshotter,
        windows: SystemWindowProvider,
        target: CaptureTarget,
        point: CGPoint
    ) async -> (Int, Int) {
        do {
            let project = try await store.createProject(title: "Mode \(label)")
            let engine = makeEngine(store: store, screenshotter: screenshotter, windows: windows)
            try await engine.start(projectPath: project.path, attachHook: false, target: target)
            let step = try await engine.captureStep(trigger: .click, point: point)
            _ = await engine.stop()
            guard let step,
                  let abs = confinePath(dir: project.path, rel: step.screenshot),
                  let data = FileManager.default.contents(atPath: abs) else {
                return (0, 0)
            }
            let w = data.subdata(in: 16..<20).reduce(0) { ($0 << 8) | Int($1) }
            let h = data.subdata(in: 20..<24).reduce(0) { ($0 << 8) | Int($1) }
            return (w, h)
        } catch {
            print("  [FAIL] \(label) mode threw — \(error)")
            return (0, 0)
        }
    }
}

/// No own windows in a headless CLI run.
struct NullOwnWindows: OwnWindowChecking {
    func pointHitsOwnWindow(_ point: CGPoint) async -> Bool { false }
    func frontmostIsOwnApp() async -> Bool { false }
}

/// Triggers are never attached in the self-test (attachHook: false).
struct NullTriggers: TriggerSource {
    func attach(mouse: @escaping @Sendable (TapEvent) -> Void, hotkey: (@Sendable () -> Void)?) throws {}
    func detach() {}
}
