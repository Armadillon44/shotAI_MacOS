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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set at app init; used for synchronous trigger teardown so the event
    /// tap and hotkey can't outlive the process.
    static nonisolated(unsafe) var captureCoordinator: CaptureCoordinator?

    func applicationWillTerminate(_ notification: Notification) {
        Self.captureCoordinator?.teardownTriggers()
    }
}
