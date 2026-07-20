import CoreGraphics
import Foundation
import os
import ShotModel

/// The recording engine — a behavioral port of the Windows CaptureController.
/// On each trigger (global mousedown or hotkey) it gathers the active window,
/// a screenshot, the click coordinates, and the UI element under the cursor
/// (resolved AT mousedown, before the click mutates the UI), skips the app's
/// own windows, writes a PNG into <project>/shots/, and appends a step.
///
/// Two serialization layers, exactly as the original:
/// - EVENT decisions (double-click collapse, menu arming, own-window checks)
///   run serially and promptly off an AsyncStream — the analog of the
///   synchronous uiohook handler.
/// - CAPTURE work chains on a FIFO task queue (`queueTail`) — the analog of
///   the promise queue — so rapid clicks can't race the counter, the file
///   writes, or the manifest appends. A failed capture emits `.error` and the
///   chain continues; a long recording can never fail silently.
public actor CaptureEngine {
    public enum EngineError: Error, LocalizedError, Equatable {
        case recordingInProgressOtherProject
        case recordingInProgress
        case shotsPathNotConfined

        public var errorDescription: String? {
            switch self {
            case .recordingInProgressOtherProject:
                "A recording is already in progress for another project"
            case .recordingInProgress:
                "A recording is already in progress"
            case .shotsPathNotConfined:
                "This project's shots folder resolves outside the project (it may be a symlink). Recording was refused so screenshots aren't written elsewhere."
            }
        }
    }

    /// Options threaded into a capture, mirroring the Windows `opts`.
    public struct CaptureOptions: Sendable {
        public var menuPopup = false
        public var menuOwnerBounds: CGRect?
        public var preGrab: Task<CapturedFrame?, Never>?
        public var elementTask: Task<StepElement?, Never>?

        public init() {}
    }

    private struct Session {
        var projectPath: String
        var projectTitle: String
        var paused = false
        var stepCount: Int
        var target: CaptureTarget
        var stepCountAtStart: Int
        var createdThisSession: Bool
        var addedStepIds: [String] = []
        /// A recording that inserts into the report at a fixed spot (the report's
        /// "Capture steps here" flow). Each captured step lands at
        /// `insertBase + addedStepIds.count`, so they keep their order at the
        /// chosen index. nil = append to the end (normal recording).
        var insertBase: Int? = nil
    }

    /// Reference type so stale async results can be identity-checked against
    /// the current arm (the Windows `menuFollowUp === cur` guards).
    private final class MenuArm {
        var until: TimeInterval
        var ownerBounds: CGRect?
        var lastPoint: CGPoint
        var menuFrame: CapturedFrame?
        var chain: Int
        /// In-flight poll-capture guard, PER ARM. Engine-global state would
        /// leak a stranded `true` across a re-arm (a poll capture that resolves
        /// after the arm was replaced), permanently suppressing the next arm's
        /// polling; a fresh arm always starts with its own clear flag.
        var polling = false

        init(until: TimeInterval, ownerBounds: CGRect?, lastPoint: CGPoint, chain: Int) {
            self.until = until
            self.ownerBounds = ownerBounds
            self.lastPoint = lastPoint
            self.chain = chain
        }
    }

    private let store: ProjectStore
    private let screenshotter: any Screenshotter
    private let activeWindows: any ActiveWindowProviding
    private let elements: any ElementLocating
    private let ownWindows: any OwnWindowChecking
    private let triggers: any TriggerSource
    private let now: @Sendable () -> TimeInterval
    /// Diagnostics — read with:
    /// `log show --debug --last 5m --predicate 'subsystem == "com.armadillon44.shotai"'`
    private let log = Logger(subsystem: "com.armadillon44.shotai", category: "capture")

    /// UI-facing event stream (single consumer: the app's coordinator).
    public nonisolated let events: AsyncStream<CaptureEvent>
    private let eventsCont: AsyncStream<CaptureEvent>.Continuation

    private enum EngineInput: Sendable {
        case mouse(TapEvent)
        case hotkey
    }

    private let inputs: AsyncStream<EngineInput>
    private let inputsCont: AsyncStream<EngineInput>.Continuation

    private var session: Session?
    /// Target downscale for stored PNGs (screenshot quality). Defaults to the
    /// constant; the app updates it from the user's setting via `setCaptureScale`
    /// before a recording/immediate capture. Clamped to the allowed range.
    private var captureScale: CGFloat = CaptureConstants.captureScale

    /// Set the screenshot-quality downscale for subsequent captures (clamped).
    public func setCaptureScale(_ scale: CGFloat) {
        captureScale = CaptureConstants.clampCaptureScale(scale)
    }
    /// Monotonic session identity, bumped when a session is installed. A
    /// capture/decision captures the generation at entry and re-checks it after
    /// every suspension: `session != nil` alone is insufficient because a
    /// DIFFERENT session may have been installed during the await (start B
    /// after stop A), so a stale operation must compare the token, not just
    /// nil-ness, before mutating session state or committing a step.
    private var generation = 0
    /// Set at the top of stop()/discard() before draining, so buffered inputs
    /// still in the AsyncStream can't enqueue a new capture during the drain
    /// (which drainQueue's captured tail would not cover) — closes the
    /// resurrected-step-after-discard race.
    private var tearingDown = false
    /// Dedupe for grab-failure error events: emit once per failure run (on the
    /// success→failure transition), so a mid-session Screen Recording
    /// revocation surfaces instead of failing silently, without spamming an
    /// error on every click.
    private var lastGrabFailed = false
    private var queueTail: Task<Void, Never>?
    private var triggersAttached = false
    private var lastLeftClick: (at: TimeInterval, point: CGPoint)?
    private var menuArm: MenuArm?
    private var pollTask: Task<Void, Never>?

    public init(
        store: ProjectStore,
        screenshotter: any Screenshotter,
        activeWindows: any ActiveWindowProviding,
        elements: any ElementLocating,
        ownWindows: any OwnWindowChecking,
        triggers: any TriggerSource,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.store = store
        self.screenshotter = screenshotter
        self.activeWindows = activeWindows
        self.elements = elements
        self.ownWindows = ownWindows
        self.triggers = triggers
        self.now = now
        (events, eventsCont) = AsyncStream.makeStream()
        (inputs, inputsCont) = AsyncStream.makeStream()
        // [weak self] so the consumer task doesn't itself keep the engine
        // alive forever; teardown() finishes the input stream, which ends the
        // loop and releases the strong ref the running method holds, so the
        // engine can deinit.
        Task { [weak self] in await self?.consumeInputs() }
    }

    // MARK: - Lifecycle

    public func state() -> CaptureState {
        guard let s = session else { return .idle }
        return CaptureState(
            status: s.paused ? .paused : .recording,
            projectPath: s.projectPath,
            projectTitle: s.projectTitle,
            // Steps captured in THIS session (0 at the start). `stepCount` is the
            // filename counter — seeded past existing shots on disk — so it would
            // report the project's running total (a fresh recording pill would read
            // "4" on a 4-step project). addedStepIds is appended only on a
            // committed step, so its count is the true session progress.
            stepCount: s.addedStepIds.count,
            // Same predicate discard() uses for whole-project deletion, surfaced
            // so the pill can warn that Discard deletes the entire new project.
            willDeleteProjectOnDiscard: s.createdThisSession && s.stepCountAtStart == 0
        )
    }

    @discardableResult
    public func start(
        projectPath: String,
        attachHook: Bool = true,
        target: CaptureTarget = CaptureTarget(mode: .auto),
        createdThisSession: Bool = false,
        insertAt: Int? = nil
    ) async throws -> CaptureState {
        if let s = session {
            if s.projectPath == projectPath { return state() } // idempotent re-start
            throw EngineError.recordingInProgressOtherProject
        }
        let opened = try await store.openProject(at: projectPath)
        // Re-check after the await: a concurrent start()/captureImmediate() may
        // have installed a session while we suspended (TOCTOU).
        if let s = session {
            if s.projectPath == opened.dir { return state() }
            throw EngineError.recordingInProgressOtherProject
        }
        let shotsDir = try confinedShotsPath(projectDir: opened.dir, rel: "shots")
        try FileManager.default.createDirectory(
            atPath: shotsDir, withIntermediateDirectories: true)
        let existing = opened.manifest.steps.count
        generation += 1
        session = Session(
            projectPath: opened.dir,
            projectTitle: opened.manifest.title,
            stepCount: seedStepCounter(projectDir: opened.dir, manifestCount: existing),
            target: target,
            stepCountAtStart: existing,
            createdThisSession: createdThisSession,
            insertBase: insertAt.map { max(0, min($0, existing)) }
        )
        if attachHook {
            // A trigger-attach failure (e.g. the event tap can't be created)
            // must fail the start, not leave a phantom 'recording' session that
            // can never produce a step.
            do {
                try attachTriggers(hotkey: true)
            } catch {
                session = nil
                throw error
            }
        }
        eventsCont.yield(.recordingChanged(true))
        emitState()
        log.notice("session started [gen \(self.generation, privacy: .public)] createdThisSession=\(createdThisSession, privacy: .public) mode=\(String(describing: target.mode), privacy: .public) existingSteps=\(existing, privacy: .public) insertAt=\(String(describing: insertAt), privacy: .public)")
        return state()
    }

    /// Capture ONE frame right now (no click, no pill) for the given target and
    /// insert it at `insertAt`. This is the report's "insert a screenshot here"
    /// flow for area/window/screen: the caller has already picked the region /
    /// window / monitor, so there's nothing to wait for. Our own windows are
    /// excluded from the frame by the screenshotter's content filter, so the
    /// report window need not be hidden (the area flow hides it only so the user
    /// can see what they're selecting). Returns nil on a soft grab failure.
    @discardableResult
    public func captureImmediate(
        projectPath: String,
        insertAt: Int,
        target: CaptureTarget
    ) async throws -> ProjectStep? {
        guard session == nil else { throw EngineError.recordingInProgress }
        let opened = try await store.openProject(at: projectPath)
        // Re-check after the await (TOCTOU): another start could have raced in.
        guard session == nil else { throw EngineError.recordingInProgress }
        let shotsDir = try confinedShotsPath(projectDir: opened.dir, rel: "shots")
        try FileManager.default.createDirectory(
            atPath: shotsDir, withIntermediateDirectories: true)
        let existing = opened.manifest.steps.count
        let at = max(0, min(insertAt, existing))
        generation += 1
        let gen = generation
        // Install a lightweight session purely so grab() can read the target.
        // No triggers and no recordingChanged, so no pill appears; the defer
        // always tears it down so a later capture/recording isn't blocked — even
        // on a thrown PNG write.
        session = Session(
            projectPath: opened.dir,
            projectTitle: opened.manifest.title,
            stepCount: seedStepCounter(projectDir: opened.dir, manifestCount: existing),
            target: target,
            stepCountAtStart: existing,
            createdThisSession: false
        )
        defer { if generation == gen { session = nil } }
        log.notice("immediate capture requested [gen \(gen, privacy: .public)] mode=\(String(describing: target.mode), privacy: .public) at=\(at, privacy: .public)")

        // point=nil / active=nil: explicit modes (area/window/screen) resolve
        // from the target alone; there is no click to frame around.
        guard let grabbed = await grab(point: nil, button: .left, opts: CaptureOptions(), active: nil) else {
            log.error("immediate capture: grab returned no frame")
            eventsCont.yield(.error("A screenshot could not be captured. Re-check Screen Recording permission in System Settings."))
            return nil
        }
        // A stop()/discard() can't race here (no triggers), but guard anyway so
        // a torn-down session never commits a bogus step.
        guard generation == gen else { return nil }

        session?.stepCount += 1
        let order = session?.stepCount ?? 0
        let filename = CaptureConstants.shotFilename(order: order)
        // Re-confine at the write itself (symlink-swap defense), exclusive create.
        let dest = try confinedShotsPath(projectDir: opened.dir, rel: "shots/\(filename)")
        try grabbed.prepared.png.write(
            to: URL(fileURLWithPath: dest), options: .withoutOverwriting)

        // Window metadata only for window mode (from the chosen target — the
        // frontmost app is us, so activeWindow() would be wrong here).
        let window: CapturedWindow? = target.mode == .window
            ? target.window.map { CapturedWindow(app: "", title: $0.title, pid: $0.pid, bounds: nil) }
            : nil
        let step = ProjectStep(
            id: UUID().uuidString.lowercased(),
            order: order,
            screenshot: "shots/\(filename)",
            trigger: .hotkey, // click-less manual capture — no click marker
            click: nil,
            monitor: CapturedMonitor(
                id: Int(grabbed.display.id),
                bounds: rect(from: grabbed.display.frame),
                scaleFactor: grabbed.display.pixelScale
            ),
            window: window,
            element: .unavailable,
            caption: buildManualCaption(mode: target.mode, windowTitle: target.window?.title),
            note: ""
        )
        try await store.insertStep(at: opened.dir, step, atIndex: at)
        log.notice("immediate capture inserted [id \(step.id, privacy: .public)] order=\(order, privacy: .public) at=\(at, privacy: .public)")
        eventsCont.yield(.stepAdded(step))
        return step
    }

    @discardableResult
    public func pause() -> CaptureState {
        session?.paused = true
        disarmMenu() // a pre-pause arm must not leak into resumed recording
        emitState()
        return state()
    }

    @discardableResult
    public func resume() -> CaptureState {
        session?.paused = false
        disarmMenu()
        emitState()
        return state()
    }

    @discardableResult
    public func stop() async -> CaptureState {
        let wasRecording = session != nil
        tearingDown = true // block buffered inputs from enqueuing during the drain
        detachTriggers() // BEFORE draining, so no new captures can enqueue
        await drainQueue()
        session = nil
        tearingDown = false
        if wasRecording { eventsCont.yield(.recordingChanged(false)) }
        emitState()
        log.notice("session stopped wasRecording=\(wasRecording, privacy: .public)")
        return state()
    }

    /// Discard the session's captures. Deletes the WHOLE project only when it
    /// was created this session and had zero steps at start; otherwise deletes
    /// exactly the steps added this session.
    public func discard() async -> (state: CaptureState, projectDeleted: Bool) {
        tearingDown = true // block buffered inputs from enqueuing during the drain
        detachTriggers()
        // Drain while the session is STILL SET so in-flight steps record
        // their ids into addedStepIds and get cleaned up below.
        await drainQueue()
        let s = session
        session = nil
        tearingDown = false
        var projectDeleted = false
        if let s {
            let whole = s.createdThisSession && s.stepCountAtStart == 0
            do {
                if whole {
                    try await store.deleteProject(at: s.projectPath)
                    projectDeleted = true
                } else if !s.addedStepIds.isEmpty {
                    try await store.deleteSteps(at: s.projectPath, ids: s.addedStepIds)
                }
            } catch {
                // Soft: discard cleanup failure never throws.
                log.error("discard cleanup failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
            }
            log.notice("session discarded projectDeleted=\(projectDeleted, privacy: .public) stepsAddedThisSession=\(s.addedStepIds.count, privacy: .public)")
            eventsCont.yield(.recordingChanged(false))
        }
        emitState()
        return (state(), projectDeleted)
    }

    /// Release triggers and end the input/event streams (applicationWill
    /// Terminate — the tap must not outlive the app). Finishing the input
    /// stream ends the consumer loop so the engine can be released.
    public func teardown() {
        detachTriggers()
        inputsCont.finish()
        eventsCont.finish()
    }

    public func listTargets() async -> CaptureTargets {
        let windows = await activeWindows.listWindows()
        let displays = (try? await screenshotter.displays()) ?? []
        let monitors = displays.map { d in
            MonitorInfo(
                id: Int(d.id),
                name: d.name.isEmpty ? "Display \(d.id)" : d.name,
                width: Int(d.frame.width),
                height: Int(d.frame.height),
                isPrimary: d.isPrimary
            )
        }
        return CaptureTargets(windows: windows, monitors: monitors)
    }

    private func attachTriggers(hotkey: Bool) throws {
        guard !triggersAttached else { return }
        let cont = inputsCont
        var hotkeyHandler: (@Sendable () -> Void)?
        if hotkey {
            hotkeyHandler = { cont.yield(.hotkey) }
        }
        try triggers.attach(
            mouse: { cont.yield(.mouse($0)) },
            hotkey: hotkeyHandler
        )
        triggersAttached = true
    }

    private func detachTriggers() {
        disarmMenu() // never carry an armed menu across sessions
        guard triggersAttached else { return }
        triggers.detach()
        triggersAttached = false
    }

    private func drainQueue() async {
        await queueTail?.value
    }

    private func emitState() {
        eventsCont.yield(.stateChanged(state()))
    }

    /// Seed the filename counter past any orphan step-NNNN.png on disk so a
    /// prior shot is NEVER overwritten (deletes leave orphans).
    private func seedStepCounter(projectDir: String, manifestCount: Int) -> Int {
        var count = manifestCount
        let shots = projectDir + "/shots"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: shots) {
            for f in files {
                if let n = CaptureConstants.shotFilenameNumber(f) {
                    count = max(count, n)
                }
            }
        }
        return count
    }

    // MARK: - Event pipeline

    /// Count of fully-processed trigger events — lets tests await pipeline
    /// quiescence deterministically (poll count, then drain the queue).
    private var processedInputs = 0

    public func processedInputCount() -> Int {
        processedInputs
    }

    /// Await completion of every capture enqueued so far.
    public func drainCaptures() async {
        await queueTail?.value
    }

    private func consumeInputs() async {
        for await input in inputs {
            switch input {
            case .mouse(let event): await handleMouseDown(event)
            case .hotkey: handleHotkey()
            }
            processedInputs += 1
        }
    }

    /// Exact branch order of the Windows onMouseDown.
    private func handleMouseDown(_ event: TapEvent) async {
        guard let s = session, !s.paused, !tearingDown else { return }
        let gen = generation
        let point = event.location
        let button = event.button

        // OWN-WINDOW GATE — must run BEFORE the element query. A click on one of
        // our own windows (e.g. the capture pill) never produces a step, AND
        // querying the element at that point is FATAL: AXUIElementCopyElement-
        // AtPosition hit-tests the window under the point, and when that window
        // is ours the call recurses into our in-process SwiftUI accessibility on
        // this background thread, which is main-thread-only → SIGTRAP. So bail
        // here (no step, and the element query never runs).
        if await ownWindows.pointHitsOwnWindow(point) {
            log.debug("own-window click suppressed at mousedown")
            return
        }
        guard sessionAlive(gen) else { return }

        // Element resolution starts NOW (after the own-window gate), before the
        // click's effect mutates the UI (dialog closes, menu dismisses).
        let elements = self.elements
        let elementTask = Task { await elements.elementAt(point) }

        // 1. Double-click collapse (left only): the second mousedown within
        // 400 ms and 6 pt produces NO step; the timestamp/point ALWAYS update
        // so longer bursts collapse pairwise.
        if button == .left {
            let t = now()
            let isDouble = lastLeftClick.map { last in
                t - last.at <= CaptureConstants.doubleClickWindow
                    && GrabMath.withinDistance(
                        point, last.point,
                        dx: CaptureConstants.doubleClickDistance,
                        dy: CaptureConstants.doubleClickDistance)
            } ?? false
            lastLeftClick = (t, point)
            if isDouble { return }
        }

        // 2. Right-click: arm the menu follow-up and capture the target
        // plainly (grabbing the just-opened menu would race its render).
        if button == .right {
            let owner = await activeWindows.activeWindow()?.bounds
            // Re-validate after the activeWindow await: a stop() during the
            // suspension must not leave a stale arm polling into idle / the
            // next session.
            guard sessionAlive(gen) else { return }
            let arm = MenuArm(
                until: now() + CaptureConstants.menuFollowUpWindow,
                ownerBounds: owner, lastPoint: point, chain: 0)
            menuArm = arm
            startMenuPolling(arm: arm)
            log.debug("menu armed on right-click chain=\(arm.chain, privacy: .public)")
            var opts = CaptureOptions()
            opts.elementTask = elementTask
            enqueueCapture(trigger: .click, point: point, button: .right, opts: opts)
            return
        }

        // 3. Menu selection (left click while armed, within proximity)
        if let arm = menuArm, button == .left, now() < arm.until,
           GrabMath.withinDistance(
               point, arm.lastPoint,
               dx: CaptureConstants.menuProximityX,
               dy: CaptureConstants.menuProximityY) {
            let owner = arm.ownerBounds
            // Prefer the polled frame (captured while the menu was painted);
            // else kick a capture NOW — the menu dismisses on mouse-up, so a
            // post-click grab would likely miss it.
            let preGrab: Task<CapturedFrame?, Never>
            if let frame = arm.menuFrame {
                preGrab = Task { frame }
            } else {
                let screenshotter = self.screenshotter
                preGrab = Task {
                    guard let displays = try? await screenshotter.displays(),
                          let mon = GrabMath.display(for: point, in: displays)
                    else { return nil }
                    return try? await screenshotter.captureDisplay(mon.id)
                }
            }
            let chain = arm.chain + 1
            if chain < CaptureConstants.maxMenuChain {
                // Re-arm for submenu/flyout chains; menuFrame resets so the
                // next selection captures the possibly-changed submenu.
                let next = MenuArm(
                    until: now() + CaptureConstants.submenuFollowUpWindow,
                    ownerBounds: owner, lastPoint: point, chain: chain)
                menuArm = next
                startMenuPolling(arm: next)
            } else {
                disarmMenu()
            }
            log.debug("menu selection captured chain=\(chain, privacy: .public) reArmed=\(chain < CaptureConstants.maxMenuChain, privacy: .public)")
            var opts = CaptureOptions()
            opts.menuPopup = true
            opts.menuOwnerBounds = owner
            opts.preGrab = preGrab
            opts.elementTask = elementTask
            enqueueCapture(trigger: .click, point: point, button: .left, opts: opts)
            return
        }

        // 4. Ordinary click: any non-menu click disarms.
        disarmMenu()
        var opts = CaptureOptions()
        opts.elementTask = elementTask
        enqueueCapture(trigger: .click, point: point, button: button, opts: opts)
    }

    private func handleHotkey() {
        guard let s = session, !s.paused, !tearingDown else { return }
        enqueueCapture(trigger: .hotkey, point: nil, button: .left, opts: CaptureOptions())
    }

    /// True iff the SAME session that owned `gen` is still live and recording.
    /// `session != nil` is not enough — a different session may have replaced
    /// it during a suspension.
    private func sessionAlive(_ gen: Int) -> Bool {
        session != nil && generation == gen && !tearingDown
    }

    private func enqueueCapture(
        trigger: ProjectStep.Trigger,
        point: CGPoint?,
        button: MouseButton,
        opts: CaptureOptions
    ) {
        let prev = queueTail
        queueTail = Task { [weak self] in
            await prev?.value
            guard let self else { return }
            do {
                _ = try await self.captureStep(trigger: trigger, point: point, button: button, opts: opts)
            } catch {
                await self.reportCaptureError(error)
            }
        }
    }

    private func reportCaptureError(_ error: Error) {
        log.error("capture failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        eventsCont.yield(.error("Capture failed: \(error.localizedDescription)"))
    }

    /// Resolve a `shots/…`-relative path under the project, refusing it if a
    /// symlinked component would redirect the write outside the folder (a
    /// hostile/shared project could point `shots` elsewhere). Every mkdir and
    /// PNG write goes through here — the invariant is "every project write is
    /// path-confined" (see ShotModel.confinePathNoSymlinks).
    private func confinedShotsPath(projectDir: String, rel: String) throws -> String {
        guard let abs = confinePathNoSymlinks(dir: projectDir, rel: rel) else {
            throw EngineError.shotsPathNotConfined
        }
        return abs
    }

    // MARK: - Menu poll cache

    /// Timer-driven (NOT mouse-move-driven) refresh of the latest full-monitor
    /// frame while a menu is armed — the menu is captured even when the user
    /// clicks an item without moving the cursor.
    private func startMenuPolling(arm: MenuArm) {
        pollTask?.cancel()
        pollTask = Task { await self.menuPollLoop(arm: arm) }
    }

    private func menuPollLoop(arm: MenuArm) async {
        var frames = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(CaptureConstants.menuPollInterval * 1_000_000_000))
            guard menuArm === arm else { return } // disarmed or re-armed since
            // session == nil stops a leaked arm from screenshotting into idle
            // after stop() (a right-click racing Stop could install an arm
            // just after the session ended).
            guard session != nil, now() < arm.until, session?.paused != true else {
                stopMenuPolling()
                return
            }
            guard frames < CaptureConstants.maxPollFrames else {
                // Keep the last frame — the menu is static while open.
                stopMenuPolling()
                return
            }
            if arm.polling { continue } // no pile-up (per-arm)
            guard let displays = try? await screenshotter.displays(),
                  let mon = GrabMath.display(for: arm.lastPoint, in: displays)
            else { continue } // skip tick WITHOUT counting a frame
            arm.polling = true
            frames += 1
            if let frame = try? await screenshotter.captureDisplay(mon.id) {
                // A late frame must not land on a newer arm.
                if menuArm === arm { arm.menuFrame = frame }
            }
            // Per-arm flag: safe to clear unconditionally (it's THIS arm's).
            arm.polling = false
        }
    }

    private func stopMenuPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func disarmMenu() {
        menuArm = nil
        stopMenuPolling()
    }

    // MARK: - captureStep

    /// The single capture routine, ported step-for-step. Returns nil on soft
    /// failures (no step, no error broadcast); throws on loud ones (file
    /// write collision, store failures). Public so tests/self-test drive it.
    @discardableResult
    public func captureStep(
        trigger: ProjectStep.Trigger,
        point: CGPoint?,
        button: MouseButton = .left,
        opts: CaptureOptions = CaptureOptions()
    ) async throws -> ProjectStep? {
        // Re-check inside the queue: a pause/stop landing while tasks were
        // queued suppresses the whole backlog.
        guard let s = session, !s.paused else { return nil }
        let gen = generation

        let active = await activeWindows.activeWindow()

        // OWN-WINDOW EXCLUSION — any signal suppresses the step silently. The
        // geometric test is load-bearing: the non-activating pill never
        // reports as frontmost.
        if await ownWindows.frontmostIsOwnApp() {
            log.debug("step suppressed — frontmost is own app")
            return nil
        }
        if let point, await ownWindows.pointHitsOwnWindow(point) {
            log.debug("step suppressed — click hits own window")
            return nil
        }

        // Right-click late owner fill (the focused window at right-click time
        // is the menu owner; it won't be once the menu takes focus).
        if button == .right, let arm = menuArm, arm.ownerBounds == nil {
            arm.ownerBounds = active?.bounds
        }

        let elements = self.elements
        let elementTask = opts.elementTask ?? Task {
            if let point { await elements.elementAt(point) } else { nil }
        }

        guard let grabbed = await grab(point: point, button: button, opts: opts, active: active) else {
            _ = await elementTask.value // don't leak the query
            // Surface the failure ONCE per failure run so a mid-session Screen
            // Recording revocation doesn't fail silently (the invariant), but a
            // single transient hiccup doesn't spam an error every click. A nil
            // grab because the session was torn down mid-capture is NOT a
            // failure — stay silent (sessionAlive gate).
            if sessionAlive(gen), !lastGrabFailed {
                lastGrabFailed = true
                log.error("screenshot grab returned no frame — surfacing capture failure to user")
                eventsCont.yield(.error("A screenshot could not be captured. If this keeps happening, re-check Screen Recording permission in System Settings."))
            }
            return nil // soft fail: no step
        }
        lastGrabFailed = false

        // Re-validate before COMMITTING: all the awaits above (activeWindow,
        // own-window checks, element query, grab) are suspension points during
        // which stop()/discard() may have cleared the session or a new session
        // replaced it. Committing now would burn a bogus order (0), write
        // step-0000.png, and re-insert a step into a just-discarded manifest.
        guard sessionAlive(gen) else { return nil }

        // Counter increments BEFORE the write — a failed write burns the
        // number; numbering may skip, never reuses.
        session?.stepCount += 1
        let order = session?.stepCount ?? 0
        let filename = CaptureConstants.shotFilename(order: order)
        let projectDir = s.projectPath
        // Re-confine at the write itself (not just at the shots/ mkdir): a
        // symlinked component swapped in mid-session must not redirect the PNG
        // outside the project. Exclusive create: a collision fails loudly
        // rather than silently overwriting a prior shot.
        let dest = try confinedShotsPath(projectDir: projectDir, rel: "shots/\(filename)")
        try grabbed.prepared.png.write(
            to: URL(fileURLWithPath: dest),
            options: .withoutOverwriting
        )

        // Prefer the window auto mode actually framed (the clicked window, which
        // may not be the frontmost app when an INACTIVE window was clicked); fall
        // back to the frontmost for hotkeys and non-auto grabs.
        let window = (grabbed.resolvedWindow ?? active).map {
            CapturedWindow(app: $0.app, title: $0.title, pid: $0.pid, bounds: $0.bounds.map(rect(from:)))
        }
        let element = await elementTask.value ?? .unavailable
        let appName = window?.app ?? "screen"
        let imageScale = grabbed.prepared.imageScale

        let step = ProjectStep(
            id: UUID().uuidString.lowercased(),
            order: order,
            screenshot: "shots/\(filename)",
            trigger: trigger,
            click: point.map { p in
                StepClick(
                    global: Point(x: p.x, y: p.y),
                    image: Point(
                        x: ((p.x - grabbed.originX) * imageScale).rounded(),
                        y: ((p.y - grabbed.originY) * imageScale).rounded()
                    ),
                    button: button,
                    imageScale: imageScale == 1 ? nil : imageScale
                )
            },
            monitor: CapturedMonitor(
                id: Int(grabbed.display.id),
                bounds: rect(from: grabbed.display.frame),
                scaleFactor: grabbed.display.pixelScale
            ),
            window: window,
            element: element,
            caption: trigger == .click
                ? buildClickCaption(button: button, isMenuSelect: opts.menuPopup, appName: appName, element: element)
                : buildHotkeyCaption(windowTitle: window?.title),
            note: ""
        )

        // Insert index: a recording bound to a fixed spot (insertBase, the report's
        // "Capture steps here" flow) advances one slot per step already captured
        // this session, so its steps land in order at the chosen index. No base →
        // append (normal recording).
        let insertIndex: Int? = session?.insertBase.map { $0 + (session?.addedStepIds.count ?? 0) }
        if let insertIndex {
            try await store.insertStep(at: projectDir, step, atIndex: insertIndex)
        } else {
            try await store.addStep(at: projectDir, step)
        }
        // Only record the id against the session it belongs to (defensive: the
        // addStep await is another suspension point).
        if sessionAlive(gen) { session?.addedStepIds.append(step.id) }
        log.info("step captured [id \(step.id, privacy: .public)] order=\(order, privacy: .public) trigger=\(String(describing: trigger), privacy: .public)")
        eventsCont.yield(.stepAdded(step))
        emitState()
        return step
    }

    // MARK: - grab() strategy cascade

    private struct Grabbed {
        var prepared: ImageOutput.Prepared
        var originX: CGFloat
        var originY: CGFloat
        var display: DisplayInfo
        /// The window auto mode actually framed (may differ from `active` when
        /// the click landed on an INACTIVE window). captureStep prefers it for
        /// the step's window metadata/caption. nil → use `active`.
        var resolvedWindow: WindowSnapshot? = nil
    }

    private func grab(
        point: CGPoint?,
        button: MouseButton,
        opts: CaptureOptions,
        active: WindowSnapshot?
    ) async -> Grabbed? {
        guard let s = session else { return nil }
        let mode = s.target.mode
        guard let displays = try? await screenshotter.displays(), !displays.isEmpty else { return nil }
        let clickDisplay = GrabMath.display(for: point, in: displays)
        // In auto mode the window under the CLICK is what we want to frame, not
        // the frontmost app — clicking an inactive window doesn't update the
        // frontmost synchronously, so `active` lags and we'd fall back to a
        // region crop. Use the active window when the click is already inside it
        // (the common case, and it carries a title even for own-title-less apps),
        // else hit-test the window under the point.
        var autoTarget = active
        if mode == .auto, let point {
            if let b = active?.bounds, b.contains(point) {
                autoTarget = active
            } else {
                autoTarget = await activeWindows.windowAt(point) ?? active
            }
        }
        var autoMode: AutoMode? = mode == .auto ? captureModeFor(active: autoTarget) : nil
        // A click in the top menu-bar band is on the system menu bar, which sits
        // ABOVE every window. Framing the active window (autoMode == .window)
        // would crop the menu bar — and the menu it opens — right out. Force a
        // region crop around the click so the bar is captured. (windowAt can
        // return the menu bar's own strip or a fullscreen window that "contains"
        // the click, so this override is needed even though out-of-window clicks
        // normally fall through to a region.)
        if mode == .auto, autoMode == .window, let point,
           let disp = clickDisplay, point.y <= disp.frame.minY + CaptureConstants.menuBarBand {
            autoMode = .region
            log.notice("grab → menu-bar band click, forcing region crop")
        }
        log.debug("""
            grab mode=\(String(describing: mode), privacy: .public) \
            auto=\(String(describing: autoMode), privacy: .public) \
            active=\(active?.app ?? "nil", privacy: .private)/'\(active?.title ?? "", privacy: .private)' \
            target=\(autoTarget?.app ?? "nil", privacy: .private) \
            bundle=\(autoTarget?.bundleID ?? "nil", privacy: .private) \
            bounds=\(String(describing: autoTarget?.bounds), privacy: .public) \
            click=\(String(describing: point), privacy: .public) \
            displays=\(displays.count, privacy: .public)
            """)

        // A. Context-menu selection: crop a frame captured while the menu was
        // painted to owner ∪ click box ('screen' keeps the whole monitor).
        if opts.menuPopup {
            var winRect: CGRect?
            if mode == .window, let ref = s.target.window {
                winRect = await activeWindows.resolveWindow(ref)
            }
            var frame: CapturedFrame?
            let pre = await opts.preGrab?.value
            if mode == .screen, let id = s.target.monitorId {
                // Screen mode always captures the CHOSEN monitor, even for a menu
                // selection made on a different display. Reuse the menu pre-grab
                // only when it IS that monitor (keeps the open menu visible in the
                // shot); otherwise the menu was on another display — capture the
                // chosen monitor fresh so screen mode never leaks a monitor the
                // user didn't pick.
                guard let intended = displays.first(where: { Int($0.id) == id }) ?? clickDisplay
                else { return nil }
                if let pre, pre.display.id == intended.id {
                    frame = pre
                } else {
                    frame = try? await screenshotter.captureDisplay(intended.id)
                }
            } else if let pre {
                frame = pre
            } else {
                var mon = clickDisplay
                if let winRect {
                    mon = GrabMath.display(containing: winRect.origin, in: displays) ?? clickDisplay
                }
                guard let mon else { return nil }
                frame = try? await screenshotter.captureDisplay(mon.id)
            }
            guard let frame else { return nil }
            var region: CGRect?
            if mode != .screen {
                var base: CGRect? = switch mode {
                case .window: winRect
                case .area: s.target.area.map(cgRect(from:))
                default: opts.menuOwnerBounds
                }
                if let point {
                    let box = GrabMath.clickBox(point: point)
                    base = base.map { GrabMath.unionRect($0, box) } ?? box
                }
                region = base
            }
            return prepare(frame: frame, region: region)
        }

        // B. Window: tight crop of the MONITOR image to the window bounds —
        // deliberately not per-window capture, so popups/dropdowns painted as
        // separate windows inside the rect stay visible.
        if mode == .window || autoMode == .window {
            var winRect: CGRect?
            if mode == .window {
                // A nil window ref → nil winRect → monitor fallback (Windows
                // parity); it must NOT silently substitute the active window.
                if let ref = s.target.window {
                    winRect = await activeWindows.resolveWindow(ref)
                }
            } else {
                // auto-window: frame the window the click landed on (autoTarget
                // is the active window when the click is inside it, else the
                // window hit-tested under the point). Only when the click is
                // genuinely inside it — a desktop click resolves no window, so it
                // falls through to a region/fullscreen grab, not a window the user
                // never touched. A hotkey (no point) keeps the active window.
                if let bounds = autoTarget?.bounds, point.map({ bounds.contains($0) }) ?? true {
                    winRect = bounds
                }
                if winRect == nil {
                    log.debug("""
                        grab auto-window → NO winRect (bounds=\(String(describing: autoTarget?.bounds), privacy: .public) \
                        contains-click=\(String(describing: autoTarget?.bounds.map { b in point.map { b.contains($0) } }), privacy: .public)) \
                        → falling through to region/fullscreen
                        """)
                }
            }
            if let winRect {
                let mon = GrabMath.display(containing: winRect.origin, in: displays) ?? clickDisplay
                if let mon, let frame = try? await screenshotter.captureDisplay(mon.id) {
                    if var result = prepare(frame: frame, region: winRect) {
                        // Auto mode framed autoTarget → carry it for the step's
                        // window metadata (explicit .window mode keeps `active`).
                        if mode == .auto { result.resolvedWindow = autoTarget }
                        log.debug("grab → WINDOW crop \(String(describing: result.prepared.png.count), privacy: .public)B origin=(\(result.originX, privacy: .public),\(result.originY, privacy: .public))")
                        return result
                    }
                }
                // capture/crop failed → fall through to monitor capture
            }
            // (mode == .window with an unresolvable window also falls through)
        }

        // C. Area (fixed rect in global points)
        if mode == .area, let area = s.target.area.map(cgRect(from:)) {
            let mon = GrabMath.display(containing: CGPoint(x: area.minX, y: area.minY), in: displays) ?? clickDisplay
            if let mon, let frame = try? await screenshotter.captureDisplay(mon.id) {
                let crop = GrabMath.areaCrop(monitor: mon.frame, area: area)
                if let prepared = ImageOutput.prepare(
                    frame: frame.image, cropLocal: crop.local, pixelScale: frame.display.pixelScale, scale: captureScale) {
                    return Grabbed(
                        prepared: prepared, originX: crop.originX, originY: crop.originY,
                        display: frame.display)
                }
            }
            // fall through to monitor capture
        }

        // D/E. Monitor resolution + auto-region + fullscreen
        var mon = clickDisplay
        if mode == .screen, let id = s.target.monitorId {
            mon = displays.first { Int($0.id) == id } ?? clickDisplay
        }
        guard let mon, let frame = try? await screenshotter.captureDisplay(mon.id) else { return nil }

        // Region crop for auto shell/region clicks AND for auto-window clicks
        // that landed OUTSIDE the active window (menu bar, open menus, window
        // edges): reaching here in .window mode means branch B didn't crop to
        // the window, so a focused region around the click beats a fullscreen
        // grab. Explicit modes (autoMode == nil) still fall through to a full
        // monitor grab, matching the Windows fallback.
        if autoMode == .region || autoMode == .window, let point {
            let crop = GrabMath.regionCrop(monitor: frame.display.frame, point: point)
            if let prepared = ImageOutput.prepare(
                frame: frame.image, cropLocal: crop.local, pixelScale: frame.display.pixelScale, scale: captureScale) {
                return Grabbed(
                    prepared: prepared, originX: crop.originX, originY: crop.originY,
                    display: frame.display)
            }
            // fall through to fullscreen
        }

        log.debug("grab → FULLSCREEN monitor #\(mon.id, privacy: .public) frame=\(String(describing: mon.frame), privacy: .public)")
        return prepare(frame: frame, region: nil)
    }

    /// Full-frame or cropToRegion output for a captured frame.
    private func prepare(frame: CapturedFrame, region: CGRect?) -> Grabbed? {
        if let region {
            let crop = GrabMath.cropToRegion(monitor: frame.display.frame, region: region)
            guard let prepared = ImageOutput.prepare(
                frame: frame.image, cropLocal: crop.local, pixelScale: frame.display.pixelScale, scale: captureScale)
            else { return nil }
            return Grabbed(
                prepared: prepared, originX: crop.originX, originY: crop.originY,
                display: frame.display)
        }
        guard let prepared = ImageOutput.prepare(
            frame: frame.image, cropLocal: nil, pixelScale: frame.display.pixelScale, scale: captureScale)
        else { return nil }
        return Grabbed(
            prepared: prepared,
            originX: frame.display.frame.minX,
            originY: frame.display.frame.minY,
            display: frame.display)
    }

    // MARK: - Geometry bridging

    private func rect(from r: CGRect) -> ShotModel.Rect {
        ShotModel.Rect(x: r.minX, y: r.minY, width: r.width, height: r.height)
    }

    private func cgRect(from r: ShotModel.Rect) -> CGRect {
        CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }
}
