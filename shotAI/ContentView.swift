import AppKit
import CaptureKit
import EditorKit
import ShotModel
import SwiftUI

/// Window widths per surface — a narrow Home, a wide project detail, matching
/// the Windows app's list ↔ detail width switch. Referenced by the app's
/// `defaultSize` so the window opens at the Home width.
enum WindowLayout {
    static let home: CGFloat = 800
    static let detail: CGFloat = 1040
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(CaptureCoordinator.self) private var capture
    @State private var showOpenPanel = false
    @State private var recordSheetTarget: RecordTarget?
    /// The editor model for the step currently being annotated (Phase C), or nil.
    @State private var editor: EditorModel?
    /// Message shown when a step can't be opened for editing.
    @State private var editorError: String?
    /// The hosting window, captured once, so we can size it per surface.
    @State private var window: NSWindow?

    private struct RecordTarget: Identifiable {
        let path: String
        /// True when the project was created just for this recording — a
        /// discard then deletes the whole project folder.
        var createdThisSession = false
        var id: String { path }
    }

    var body: some View {
        @Bindable var model = model
        // Full-window Home ⇄ detail switch (the Windows single-window model),
        // not a persistent sidebar. Opening a project shows its report; Back
        // (or closeToHome) returns to the Home card grid.
        Group {
            if let opened = model.opened {
                ReportView(opened: opened, onEdit: { step in openEditor(step, in: opened.dir) })
                    .id(opened.dir)
            } else {
                HomeView(capture: capture, onOpen: { path in
                    Task { await model.open(path: path) }
                })
            }
        }
        .navigationTitle(model.opened?.manifest.title ?? "shotAI")
        // shotAI's brand accent (violet) for selection, controls, and the
        // editor overlay — propagates down the whole window hierarchy.
        .tint(Palette.accent)
        // Capture the hosting window once, then size it per surface: narrow on
        // Home, wide when a project is open. Center-preserving + animated.
        .background(WindowAccessor { w in
            guard window == nil else { return }
            window = w
            w.minSize = NSSize(width: 680, height: 560)
            applyWindowWidth(w, animated: false)
        })
        .onChange(of: model.opened?.dir) {
            if let window { applyWindowWidth(window, animated: true) }
        }
        // Hide the window's Record/Permissions/… toolbar while the editor
        // overlay is up, so its controls can't sit behind the editor's own bar.
        .toolbar(editor == nil ? .automatic : .hidden, for: .windowToolbar)
        .toolbar {
            if model.opened != nil {
                ToolbarItem(placement: .navigation) {
                    Button("Back", systemImage: "chevron.left") { model.closeToHome() }
                        .help("Back to all projects")
                }
                ToolbarItem {
                    Button("Record", systemImage: "record.circle") { startRecordFlow() }
                        .disabled(capture.state.status != .idle)
                        .help("Record more steps into this project")
                }
            }
            ToolbarItem {
                Button("Permissions", systemImage: "lock.shield") {
                    capture.showWizard = true
                }
            }
            ToolbarItem {
                Button("Open Project…", systemImage: "folder.badge.plus") {
                    showOpenPanel = true
                }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
            }
        }
        .fileImporter(isPresented: $showOpenPanel, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.openUserPicked(url) }
            }
        }
        .sheet(item: $recordSheetTarget) { target in
            RecordSheet(
                projectPath: target.path,
                createdThisSession: target.createdThisSession,
                coordinator: capture
            )
        }
        // Overlay, NOT a `.sheet`: a presented sheet vetoes app termination
        // (⌘Q returns -128), and this wizard shows on every launch until Screen
        // Recording is granted — which made the app unquittable except by Force
        // Quit. An overlay never blocks terminate.
        .overlay {
            if capture.showWizard {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    PermissionsWizardView(onClose: { capture.showWizard = false })
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 30)
                }
                .transition(.opacity)
            }
        }
        // Full-window editor overlay (Phase C) — presented in-window, not a
        // sheet, so it can't veto ⌘Q.
        .overlay {
            if let editor {
                EditorOverlay(
                    model: editor,
                    onCancel: { self.editor = nil },
                    onSaved: {
                        self.editor = nil
                        Task {
                            await model.reloadOpened() // show the flattened render
                            await model.refresh() // updatedAt changed → resort the list
                        }
                    }
                )
                .transition(.opacity)
            }
        }
        .alert(
            "Capture error",
            isPresented: Binding(
                get: { capture.lastError != nil },
                set: { if !$0 { capture.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(capture.lastError ?? "")
        }
        .alert(
            "Can't edit this step",
            isPresented: Binding(get: { editorError != nil }, set: { if !$0 { editorError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editorError ?? "")
        }
        .alert(
            "Couldn't open project",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            await model.refresh()
            // Live-refresh the report as steps land; refresh everything when
            // a session ends (stop or discard may even delete the project).
            capture.onStepAdded = { _ in
                Task { await model.reloadOpened() }
            }
            capture.onRecordingEnded = {
                Task {
                    await model.refresh()
                    await model.reloadOpened()
                }
            }
            // First run: surface the wizard when the required permission is
            // missing, before the user hits Record and wonders.
            if !CapturePermission.screenRecording.isGranted() {
                capture.showWizard = true
            }
        }
    }

    /// Size the window to the current surface's width (Home vs. project detail),
    /// keeping the window's horizontal center fixed and clamping to the screen.
    private func applyWindowWidth(_ window: NSWindow, animated: Bool) {
        let target = model.opened == nil ? WindowLayout.home : WindowLayout.detail
        var f = window.frame
        guard abs(f.size.width - target) > 0.5 else { return }
        f.origin.x -= (target - f.size.width) / 2 // preserve center
        f.size.width = target
        if let vis = window.screen?.visibleFrame {
            if f.size.width > vis.size.width { f.size.width = vis.size.width }
            f.origin.x = min(max(f.origin.x, vis.minX), vis.maxX - f.size.width)
        }
        window.setFrame(f, display: true, animate: animated)
    }

    /// Open the annotation editor for a step (loads its raw screenshot). If the
    /// screenshot can't be loaded, tell the user instead of silently no-op'ing.
    private func openEditor(_ step: ProjectStep, in projectDir: String) {
        if let m = EditorModel(step: step, projectDir: projectDir, store: model.store, scanner: VisionOCR()) {
            editor = m
        } else {
            editorError = "This step's screenshot (\(step.screenshot)) couldn't be opened for editing — it may be missing or corrupt."
        }
    }

    /// Record into the opened project, or create a fresh one (which discard
    /// then deletes entirely — the createdThisSession contract).
    private func startRecordFlow() {
        if let opened = model.opened {
            recordSheetTarget = RecordTarget(path: opened.dir)
        } else {
            Task {
                if let path = await model.createAndSelectProject() {
                    recordSheetTarget = RecordTarget(path: path, createdThisSession: true)
                }
            }
        }
    }

    /// "Jul 1, 2026" from the manifest's ISO timestamp; nil for legacy blanks.
    static func formatDate(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Resolves the `NSWindow` hosting this SwiftUI view so it can be sized
/// programmatically. The callback is idempotent (the caller guards to run once).
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onResolve(w) } }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { if let w = nsView.window { onResolve(w) } }
    }
}
