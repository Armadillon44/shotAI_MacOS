import CoreGraphics
import Foundation
@testable import CaptureKit
import ShotModel

// Headless fakes for the hardware seams, so the whole capture pipeline runs
// under `swift test` with no TCC grants.

func makeImage(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// PNG IHDR dimensions (same trick as the Windows self-test).
func pngSize(_ data: Data) -> (width: Int, height: Int) {
    let w = data.subdata(in: 16..<20).reduce(0) { ($0 << 8) | Int($1) }
    let h = data.subdata(in: 20..<24).reduce(0) { ($0 << 8) | Int($1) }
    return (w, h)
}

final class FakeScreenshotter: Screenshotter, @unchecked Sendable {
    private let lock = NSLock()
    var displayList: [DisplayInfo]
    private(set) var captureCount = 0

    init(displays: [DisplayInfo]) {
        self.displayList = displays
    }

    func displays() async throws -> [DisplayInfo] {
        lock.withLock { displayList }
    }

    func captureDisplay(_ id: UInt32) async throws -> CapturedFrame {
        let display = lock.withLock { () -> DisplayInfo? in
            captureCount += 1
            return displayList.first { $0.id == id }
        }
        guard let display else { throw CocoaError(.fileNoSuchFile) }
        let image = makeImage(
            width: Int(display.frame.width * display.pixelScale),
            height: Int(display.frame.height * display.pixelScale))
        return CapturedFrame(image: image, display: display)
    }
}

final class FakeActiveWindows: ActiveWindowProviding, @unchecked Sendable {
    private let lock = NSLock()
    var snapshot: WindowSnapshot?
    var windowRects: [Int: CGRect] = [:] // window id → bounds for resolveWindow

    /// When set, activeWindow() signals `entered` then suspends until
    /// `release()` — lets a test hold a capture at its first await to exercise
    /// teardown-during-capture races deterministically.
    private var gateContinuations: [CheckedContinuation<Void, Never>] = []
    private var gateEnabled = false
    let entered = AsyncStream.makeStream(of: Void.self)

    init(snapshot: WindowSnapshot? = nil) {
        self.snapshot = snapshot
    }

    func enableGate() {
        lock.withLock { gateEnabled = true }
    }

    func release() {
        let conts = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let c = gateContinuations
            gateContinuations = []
            gateEnabled = false
            return c
        }
        conts.forEach { $0.resume() }
    }

    func activeWindow() async -> WindowSnapshot? {
        if lock.withLock({ gateEnabled }) {
            entered.continuation.yield(())
            await withCheckedContinuation { c in
                lock.withLock { gateContinuations.append(c) }
            }
        }
        return lock.withLock { snapshot }
    }

    func listWindows() async -> [WindowInfo] {
        []
    }

    func resolveWindow(_ ref: CaptureTarget.WindowRef) async -> CGRect? {
        lock.withLock { windowRects[ref.id] }
    }
}

final class FakeElements: ElementLocating, @unchecked Sendable {
    private let lock = NSLock()
    var element: StepElement?
    private(set) var callCount = 0
    private(set) var queriedPoints: [CGPoint] = []

    init(element: StepElement? = nil) {
        self.element = element
    }

    func elementAt(_ point: CGPoint) async -> StepElement? {
        lock.withLock {
            callCount += 1
            queriedPoints.append(point)
            return element
        }
    }
}

final class FakeOwnWindows: OwnWindowChecking, @unchecked Sendable {
    private let lock = NSLock()
    /// Own window frames in global top-left points (the pill's rect).
    var ownFrames: [CGRect] = []
    var frontmostIsOwn = false

    func pointHitsOwnWindow(_ point: CGPoint) async -> Bool {
        lock.withLock {
            ownFrames.contains { frame in
                point.x >= frame.minX && point.x < frame.maxX
                    && point.y >= frame.minY && point.y < frame.maxY
            }
        }
    }

    func frontmostIsOwnApp() async -> Bool {
        lock.withLock { frontmostIsOwn }
    }
}

final class FakeTriggers: TriggerSource, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var mouse: (@Sendable (TapEvent) -> Void)?
    private(set) var hotkey: (@Sendable () -> Void)?
    private(set) var attachCount = 0
    private(set) var detachCount = 0
    private(set) var lastAttachHadHotkey = false

    func attach(
        mouse: @escaping @Sendable (TapEvent) -> Void,
        hotkey: (@Sendable () -> Void)?
    ) throws {
        lock.withLock {
            self.mouse = mouse
            self.hotkey = hotkey
            attachCount += 1
            lastAttachHadHotkey = hotkey != nil
        }
    }

    func detach() {
        lock.withLock {
            mouse = nil
            hotkey = nil
            detachCount += 1
        }
    }

    func fireMouse(_ event: TapEvent) {
        lock.withLock { mouse }?(event)
    }

    func fireHotkey() {
        lock.withLock { hotkey }?()
    }
}

/// Controllable clock for double-click / menu-window timing.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000

    var now: @Sendable () -> TimeInterval {
        { [self] in lock.withLock { time } }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { time += seconds }
    }
}

/// Poll until a condition holds (pipeline processing is async).
func eventually(
    timeout: TimeInterval = 3,
    _ condition: @escaping () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// A ready-to-record engine over a temp project, with all fakes exposed.
struct EngineHarness {
    let engine: CaptureEngine
    let store: ProjectStore
    let root: String
    let projectDir: String
    let screenshotter: FakeScreenshotter
    let activeWindows: FakeActiveWindows
    let elements: FakeElements
    let ownWindows: FakeOwnWindows
    let triggers: FakeTriggers
    let clock: FakeClock

    /// One 1000x600pt display at 2x — stored PNGs are 2000x1200px before the
    /// 0.85 downscale.
    static let display = DisplayInfo(
        id: 7, frame: CGRect(x: 0, y: 0, width: 1000, height: 600),
        pixelScale: 2, isPrimary: true, name: "Main")

    init(displays: [DisplayInfo] = [display]) throws {
        root = NSTemporaryDirectory() + "shotai-engine-\(UUID().uuidString)"
        projectDir = root + "/proj"
        try FileManager.default.createDirectory(atPath: projectDir + "/shots", withIntermediateDirectories: true)
        let manifest = ProjectManifest(id: "p", title: "Engine Test", createdAt: "", updatedAt: "")
        try ProjectJSON.encodeManifest(manifest)
            .write(to: URL(fileURLWithPath: projectDir + "/project.json"))
        store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        screenshotter = FakeScreenshotter(displays: displays)
        activeWindows = FakeActiveWindows(snapshot: WindowSnapshot(
            app: "Safari", title: "Apple", pid: 500, bundleID: "com.apple.Safari",
            bounds: CGRect(x: 100, y: 80, width: 700, height: 450)))
        elements = FakeElements()
        ownWindows = FakeOwnWindows()
        triggers = FakeTriggers()
        clock = FakeClock()
        engine = CaptureEngine(
            store: store,
            screenshotter: screenshotter,
            activeWindows: activeWindows,
            elements: elements,
            ownWindows: ownWindows,
            triggers: triggers,
            now: clock.now
        )
    }

    func readSteps() throws -> [ProjectStep] {
        let data = try Data(contentsOf: URL(fileURLWithPath: projectDir + "/project.json"))
        return try ProjectJSON.decodeManifest(data).steps
    }

    func shotData(_ step: ProjectStep) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: projectDir + "/" + step.screenshot))
    }

    /// Fire a tap and wait until the engine has both processed the event and
    /// drained the capture queue.
    func tap(_ point: CGPoint, _ button: MouseButton) async {
        let before = await engine.processedInputCount()
        triggers.fireMouse(TapEvent(location: point, button: button))
        _ = await eventually { await engine.processedInputCount() > before }
        await engine.drainCaptures()
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: root)
    }
}
