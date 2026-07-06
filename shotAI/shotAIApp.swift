import CaptureKit
import ShotModel
import SwiftUI

@main
struct ShotAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var capture: CaptureCoordinator

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        let capture = CaptureCoordinator(store: model.store)
        _capture = State(initialValue: capture)
        AppDelegate.captureCoordinator = capture
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .environment(capture)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            // Guarantee ⌘Q / the Quit menu always work, even while a `.sheet`
            // (the Record chooser) is presented — SwiftUI otherwise vetoes
            // termination with a sheet up. We have no unsaved state; release the
            // event tap/hotkey, then exit hard so the veto can't apply.
            CommandGroup(replacing: .appTermination) {
                Button("Quit shotAI") {
                    AppDelegate.captureCoordinator?.teardownTriggers()
                    exit(0)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set at app init; used for synchronous trigger teardown so the event
    /// tap and hotkey can't outlive the process.
    static nonisolated(unsafe) var captureCoordinator: CaptureCoordinator?

    /// Always allow quit. Without this, ⌘Q / the Quit menu / NSApp.terminate
    /// return -128 (userCanceled) while a SwiftUI `.sheet` (the permissions
    /// wizard) is presented — the sheet vetoes termination, so the app could
    /// only be Force-Quit. We have no unsaved-state to guard, so terminate now.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.captureCoordinator?.teardownTriggers()
    }
}
