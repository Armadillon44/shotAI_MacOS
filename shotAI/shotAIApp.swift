import AppKit
import CaptureKit
import ExportKit
import ShotModel
import SwiftUI

@main
struct ShotAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var capture: CaptureCoordinator

    init() {
        Log.bootstrap() // banner + uncaught-exception handler, as early as possible
        let model = AppModel()
        _model = State(initialValue: model)
        let capture = CaptureCoordinator(store: model.store)
        _capture = State(initialValue: capture)
        AppDelegate.captureCoordinator = capture
        // Feed live capture prefs (screenshot quality + keep-visible) from Settings.
        capture.capturePrefs = { [weak model] in
            guard let p = model?.preferences else { return (CaptureConstants.captureScale, false) }
            return (CGFloat(p.captureScale), p.captureNoHide)
        }
    }

    var body: some Scene {
        // Identified so the Settings ▸ "Show intro tour" replay can bring the main
        // window forward (or reopen it if closed) via `openWindow(id:)`.
        WindowGroup(id: "main") {
            ContentView()
                .environment(model)
                .environment(capture)
                // Low floor so the Home can sit narrow; ContentView drives the
                // actual width per surface (narrow Home ⇄ wide project detail).
                .frame(minWidth: 680, minHeight: 560)
                // Appearance ▸ Theme override (nil = follow the system).
                .preferredColorScheme(model.preferences.theme.colorScheme)
        }
        .defaultSize(width: WindowLayout.home, height: 760)
        .commands {
            // About shotAI — the native panel (shows the AppIcon + version +
            // copyright automatically) with our tagline added as credits.
            CommandGroup(replacing: .appInfo) {
                Button("About shotAI") { Self.showAboutPanel() }
            }
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
            // File ▸ Export — exports the currently-open project (disabled on Home).
            // Same four formats as the report toolbar's Export menu.
            CommandGroup(after: .importExport) {
                Menu("Export") {
                    Button("HTML Document") { Task { await model.exportOpened(format: .html) } }
                    Button("PDF") { Task { await model.exportOpened(format: .pdf) } }
                    Button("Markdown") { Task { await model.exportOpened(format: .markdown) } }
                    Divider()
                    Button("HTML for Word / Google Docs") { Task { await model.exportOpened(format: .htmlPlain) } }
                    Divider()
                    Menu("shotAI Package (.zip)") {
                        Button("Safe — redactions permanent") { model.confirmAndExportPackageOpened(includeOriginals: false) }
                        Button("Full — includes editable originals…") { model.confirmAndExportPackageOpened(includeOriginals: true) }
                    }
                }
                .disabled(model.opened == nil || model.exporting)
                Button("Import shotAI Package…") { model.promptImportPackage() }
                    .disabled(model.exporting || model.tourActive)
            }
            // Troubleshooting: dump this app's recent log to a file + reveal it,
            // so a user can send it (parity with the Windows log file).
            CommandGroup(after: .help) {
                Button("Export shotAI Logs…") {
                    do {
                        let url = try Log.exportRecentLog(hours: 24)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch {
                        Log.app.error("Log export failed: \(error.localizedDescription, privacy: .private)")
                        NSSound.beep()
                    }
                }
            }
        }

        // (see showAboutPanel below for the About command's implementation)

        // Native Settings window (shotAI ▸ Settings… / ⌘,) — houses Permissions
        // (which the toolbar shield used to open), General, and AI. The AI tab
        // shares the same AppModel instance as the main window (key status + SOP
        // settings stay in sync across both scenes).
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(model.preferences.theme.colorScheme)
        }
    }

    /// The native About panel — it reads the app icon, name, version, and
    /// © (NSHumanReadableCopyright) from the bundle; we add the product tagline
    /// as credits so About shows what shotAI is.
    private static func showAboutPanel() {
        let credits = NSAttributedString(
            string: "Local-first SOP builder — record a process and let Claude write the step-by-step guide.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
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

    /// macOS 14+ handshake for state restoration. Our windows are marked
    /// non-restorable (we size/route them ourselves), so nothing is actually
    /// restored — this just satisfies the requirement and silences the launch
    /// warning without opting into resurrecting a blank window after a crash.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("Application did finish launching")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.notice("Application will terminate")
        Self.captureCoordinator?.teardownTriggers()
    }
}
