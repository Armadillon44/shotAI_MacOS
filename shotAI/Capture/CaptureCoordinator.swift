import AppKit
import CaptureKit
import Observation
import ShotModel
import SwiftUI

/// Wires the CaptureEngine to the app: consumes the engine's event stream,
/// drives the pill and main-window visibility (the onRecordingChange
/// contract), runs the area-select flow, and gates recording behind the
/// Screen Recording permission.
@MainActor
@Observable
final class CaptureCoordinator {
    let engine: CaptureEngine
    private(set) var state = CaptureState.idle
    var lastError: String?
    var showWizard = false
    var onStepAdded: ((ProjectStep) -> Void)?
    var onRecordingEnded: (() -> Void)?

    private let store: ProjectStore
    /// Direct reference for synchronous teardown in applicationWillTerminate
    /// (the tap must never outlive the app).
    private let triggers = SystemTriggers()
    private var pill: CapturePillController?
    private let areaSelect = AreaSelectController()

    init(store: ProjectStore) {
        self.store = store
        engine = CaptureEngine(
            store: store,
            screenshotter: SCKScreenshotter(),
            activeWindows: SystemWindowProvider(),
            elements: AXElementLocator(),
            ownWindows: AppOwnWindows(),
            triggers: triggers
        )
        pill = CapturePillController { [weak self] action in
            self?.handlePillAction(action)
        }
        Task { await self.consumeEvents() }
    }

    // MARK: - Recording entry points

    /// Start recording into a project. Returns false when blocked on the
    /// Screen Recording permission (the wizard is shown instead).
    @discardableResult
    func record(
        projectPath: String,
        target: CaptureTarget,
        createdThisSession: Bool = false
    ) async -> Bool {
        guard CapturePermission.screenRecording.isGranted() else {
            CapturePermission.screenRecording.request()
            showWizard = true
            return false
        }
        do {
            try await store.setCaptureSettings(at: projectPath, target)
            try await engine.start(
                projectPath: projectPath,
                target: target,
                createdThisSession: createdThisSession
            )
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// The area-select flow: hide the requesting window so it isn't covering
    /// the selectable area; restore it even on cancel.
    func selectArea() async -> ShotModel.Rect? {
        let main = mainWindow
        main?.orderOut(nil)
        defer {
            main?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        guard let rect = await areaSelect.selectArea() else { return nil }
        return ShotModel.Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    func listTargets() async -> CaptureTargets {
        await engine.listTargets()
    }

    /// Synchronous trigger release for applicationWillTerminate.
    nonisolated func teardownTriggers() {
        triggers.detach()
    }

    // MARK: - Pill actions

    private func handlePillAction(_ action: PillAction) {
        switch action {
        case .pause:
            Task { await engine.pause() }
        case .resume:
            Task { await engine.resume() }
        case .stop:
            Task { await engine.stop() }
        case .discard:
            // Defer so the pill's SwiftUI Button action fully unwinds before
            // runModal spins a nested run loop — otherwise an engine event
            // draining during the modal would re-enter the hosting view's
            // rootView update while that same button action is still on the
            // stack (AttributeGraph re-entrancy).
            Task { @MainActor in self.confirmDiscard() }
        }
    }

    private func confirmDiscard() {
        // The pill is non-activating, so shotAI usually isn't frontmost;
        // activate first so the alert comes to the front with keyboard focus
        // instead of ordering in behind the recorded app.
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Discard this capture?"
        alert.informativeText = "Steps recorded in this session will be deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .modalPanel
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { _ = await engine.discard() }
    }

    // MARK: - Engine events

    private func consumeEvents() async {
        for await event in engine.events {
            switch event {
            case .stateChanged(let newState):
                state = newState
                pill?.update(state: newState)
            case .stepAdded(let step):
                onStepAdded?(step)
            case .error(let message):
                lastError = message
            case .recordingChanged(let recording):
                recordingChanged(recording)
            }
        }
    }

    private func recordingChanged(_ recording: Bool) {
        let noHide = ProcessInfo.processInfo.environment["SHOTAI_CAPTURE_NO_HIDE"] == "1"
        if recording {
            let main = mainWindow
            if !noHide { main?.orderOut(nil) }
            pill?.show(state: state, near: main)
        } else {
            pill?.hide()
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            onRecordingEnded?()
        }
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.contentViewController != nil }
    }
}
