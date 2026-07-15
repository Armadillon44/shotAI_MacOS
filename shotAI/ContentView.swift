import AppKit
import CaptureKit
import EditorKit
import ExportKit
import QuartzCore
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
    /// The editor model for the step currently being annotated (Phase C), or nil.
    @State private var editor: EditorModel?
    /// Message shown when a step can't be opened for editing.
    @State private var editorError: String?
    /// The hosting window, captured once, so we can size it per surface.
    @State private var window: NSWindow?
    /// Honor Reduce Motion for the overlay fades below.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        mainContent
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
            // Shared error channel (open / rename / delete / archive / restore /
            // bulk). Neutral title so it isn't mislabeled — the message carries
            // the specifics ("2 of 5 projects couldn't be archived").
            .alert(
                "Something went wrong",
                isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert(
                "Export failed",
                isPresented: Binding(get: { model.exportError != nil }, set: { if !$0 { model.exportError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.exportError ?? "")
            }
            .alert(
                "Couldn't import package",
                isPresented: Binding(get: { model.importError != nil }, set: { if !$0 { model.importError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.importError ?? "")
            }
            .task {
                await model.startup()  // one-time auto-archive sweep, then list
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

    /// The Home ⇄ detail content plus its window chrome (toolbar, overlays,
    /// file importer). Split out from `body` — with the alerts/task chained on
    /// top the single expression exceeded the Swift type-checker's budget.
    @ViewBuilder private var mainContent: some View {
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
            // Don't let macOS restore this window's state on relaunch: we size it
            // ourselves per surface and always open to Home, so restoration adds
            // nothing — but after an unclean exit (crash/force-quit) it flashes a
            // blank placeholder for any transient sheet/overlay that was open.
            w.isRestorable = false
            applyWindowWidth(w, animated: false)
        })
        .onChange(of: model.opened?.dir) {
            guard let window else { return }
            // Defer to the next runloop tick so the resize animation runs AFTER
            // the Home⇄detail content swap settles. Entering a project happens
            // async (after an await) so it was already clean; Back is synchronous
            // and, run inline, would be preempted mid-swap and snap without
            // animating. Deferring makes both directions animate identically.
            DispatchQueue.main.async { applyWindowWidth(window, animated: true) }
        }
        // The window toolbar is the native title-bar chrome. While editing, we
        // REPLACE its items with the editor's Cancel/Save (keeping the toolbar
        // VISIBLE) so the title bar reads as functional chrome — traffic lights
        // stay native/visible, there's no blank band, and the buttons are native
        // toolbar controls. Outside the editor it shows the usual actions.
        // Three mutually-exclusive toolbar states. Use SEMANTIC placements
        // throughout: default .automatic items LINGER across a conditional
        // toolbar swap on macOS, whereas semantic placements swap out cleanly.
        .toolbar { windowToolbar }
        .fileImporter(isPresented: $showOpenPanel, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.openUserPicked(url) }
            }
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
        // The .transition above only plays inside an animated transaction; the
        // state is flipped by plain assignments elsewhere, so animate it here.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: capture.showWizard)
        // Full-window editor overlay (Phase C) — presented in-window, not a
        // sheet, so it can't veto ⌘Q.
        //
        // Presented with NO transition/animation on purpose (#41 crop freeze): a
        // fading full-window overlay could be left STRANDED — still hit-testable
        // at opacity ~0 — when its removal transition raced the report's
        // re-layout after a crop changed the screenshot's size. The stranded layer
        // swallowed every click and scroll in the report until a window
        // minimize→restore rebuilt the view tree. Instant add/remove can't strand,
        // so the report is immediately interactive again after Save/Cancel.
        .overlay {
            if let editor {
                // Cancel/Save live in the window title bar; this overlay is just
                // the editor canvas + tools.
                EditorOverlay(model: editor)
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
        guard animated else {
            window.setFrame(f, display: true, animate: false)
            return
        }
        // Explicit animation context → smooth, consistent easing in BOTH
        // directions (grow on open, shrink on Back).
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(f, display: true)
        }
    }

    /// The window toolbar's three mutually-exclusive states, extracted into a typed
    /// `@ToolbarContentBuilder` so the (large, conditional) content doesn't blow the
    /// Swift type-checker's budget when inlined in `.toolbar { … }`. Uses SEMANTIC
    /// placements throughout: default `.automatic` items LINGER across a conditional
    /// toolbar swap on macOS, whereas semantic placements swap out cleanly.
    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        if let editor {
            // Editing a step: just Cancel / Save.
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { self.editor = nil }
                    .disabled(editor.saving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task {
                        if await editor.save() {
                            self.editor = nil
                            await model.reloadOpened() // show the flattened render
                            await model.refresh() // updatedAt changed → resort the list
                        }
                    }
                } label: {
                    if editor.saving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .disabled(editor.saving || editor.scanning)
            }
        } else if model.opened != nil {
            // In a project/report: Back + Export. (Record removed — the report's
            // "＋ → Capture steps…" covers recording more steps.)
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { model.closeToHome() }
                    .help("Back to all projects")
            }
            ToolbarItem(placement: .primaryAction) { reportExportMenu }
        } else {
            // Home (project list): open a project, import a package, refresh.
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Open Project…", systemImage: "folder.badge.plus") { showOpenPanel = true }
                Button("Import Package…", systemImage: "square.and.arrow.down") { model.promptImportPackage() }
                    .help("Import a shotAI package (.zip)")
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
        }
    }

    /// The report's Export pull-down. Extracted from the `.toolbar` builder so the
    /// (already large) conditional toolbar closure stays within the Swift
    /// type-checker's budget — inlining the nested package submenu tipped it over.
    @ViewBuilder private var reportExportMenu: some View {
        Menu {
            Button("HTML Document") { export(.html) }
            Button("PDF") { export(.pdf) }
            Button("Markdown") { export(.markdown) }
            Divider()
            Button("HTML for Word / Google Docs") { export(.htmlPlain) }
            Divider()
            Menu("shotAI Package (.zip)") {
                Button("Safe — redactions permanent") {
                    model.confirmAndExportPackageOpened(includeOriginals: false)
                }
                Button("Full — includes editable originals…") {
                    model.confirmAndExportPackageOpened(includeOriginals: true)
                }
            }
        } label: {
            // Force BOTH the word "Export" and the icon: this app's toolbar renders
            // image-bearing labels icon-only by default, and macOS then auto-labels
            // a bare square.and.arrow.up as "Share" — unrecognizable as export.
            Label("Export", systemImage: "square.and.arrow.up")
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .disabled(model.exporting)
        .help("Export this SOP to a shareable document")
    }

    /// Kick off an export of the opened project. The heavy work (flatten + write)
    /// runs on `AppModel`; on success it reveals the file in Finder, on failure it
    /// sets `exportError` (shown by the alert above).
    private func export(_ format: ExportFormat) {
        Task { await model.exportOpened(format: format) }
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
