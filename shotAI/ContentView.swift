import CaptureKit
import EditorKit
import ShotModel
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(CaptureCoordinator.self) private var capture
    @State private var showOpenPanel = false
    @State private var recordSheetTarget: RecordTarget?
    /// The editor model for the step currently being annotated (Phase C), or nil.
    @State private var editor: EditorModel?
    /// Message shown when a step can't be opened for editing.
    @State private var editorError: String?

    private struct RecordTarget: Identifiable {
        let path: String
        /// True when the project was created just for this recording — a
        /// discard then deletes the whole project folder.
        var createdThisSession = false
        var id: String { path }
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.projects, id: \.path, selection: $model.selectedPath) { project in
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(project.stepCount) step\(project.stepCount == 1 ? "" : "s")\(Self.formatDate(project.updatedAt).map { " · \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(project.path)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .overlay {
                if model.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects",
                        systemImage: "folder",
                        description: Text("Projects in \(model.projectsDirDisplay) appear here. Use Open Project… to browse elsewhere.")
                    )
                }
            }
        } detail: {
            if let opened = model.opened {
                ReportView(opened: opened, onEdit: { step in openEditor(step, in: opened.dir) })
                    .id(opened.dir)
            } else if let error = model.errorMessage {
                ContentUnavailableView("Could not open project", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("Select a project", systemImage: "doc.text.image", description: Text("Pick a project from the list to view its report."))
            }
        }
        .navigationTitle(model.opened?.manifest.title ?? "shotAI")
        // Hide the window's Record/Permissions/… toolbar while the editor
        // overlay is up, so its controls can't sit behind the editor's own bar.
        .toolbar(editor == nil ? .automatic : .hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem {
                Button("Record", systemImage: "record.circle") {
                    startRecordFlow()
                }
                .disabled(capture.state.status != .idle)
                .help(model.opened == nil
                    ? "Create a new project and record steps"
                    : "Record steps into this project")
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
        .onChange(of: model.selectedPath) {
            Task { await model.openSelected() }
        }
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
