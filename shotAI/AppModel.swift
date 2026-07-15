import AppKit
import CoreGraphics
import EditorKit
import ExportKit
import Foundation
import ImageIO
import Observation
import ShotModel
import SOPKit
import UniformTypeIdentifiers

/// UI-facing state for the Phase A read-only viewer: the project list and the
/// currently opened project. All disk work happens inside the ProjectStore
/// actor; this object just mirrors results onto the main actor.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let store: ProjectStore
    private(set) var projects: [ProjectSummary] = []
    private(set) var opened: ProjectStore.OpenedProject?
    var selectedPath: String?
    var errorMessage: String?

    var projectsDirDisplay: String {
        (settings.projectsDir() as NSString).abbreviatingWithTildeInPath
    }

    init(settings: SettingsStore = UserDefaultsSettings()) {
        self.settings = settings
        self.store = ProjectStore(settings: settings)
        self.sopSettings = Self.loadSopSettings()
        self.preferences = Self.loadPreferences()
        refreshApiKeyStatus()
    }

    @ObservationIgnored private var didStartupSweep = false

    /// Launch entry point: run the one-time auto-archive sweep (stale projects →
    /// Archive), then list. Idempotent — the sweep runs at most once per launch.
    func startup() async {
        if !didStartupSweep {
            didStartupSweep = true
            _ = await store.autoArchiveStale(ageDays: settings.archiveAgeDays())
        }
        // autoRefresh (not refresh) so this launch list coalesces with HomeView's
        // own appear-refresh — otherwise both fire at launch and scan twice.
        await autoRefresh()
    }

    /// Set the auto-archive age (0 = never). Bound by Settings ▸ General.
    func setArchiveAgeDays(_ days: Int) { settings.setArchiveAgeDays(days) }

    func refresh() async {
        let listed = await store.listProjects()
        // Only publish when the list actually changed. @Observable fires on every
        // assignment (no equality check), so an unchanged periodic poll would
        // otherwise re-run Home's whole filter/sort/group pipeline every tick.
        // ProjectSummary is Equatable, and listProjects returns a stable order.
        if listed != projects { projects = listed }
        Log.store.debug("refresh listed \(listed.count, privacy: .public) projects")
        // Keep a live selection when its project vanished from disk.
        if let selectedPath, !listed.contains(where: { $0.path == selectedPath }) {
            self.selectedPath = nil
            opened = nil
        }
    }

    @ObservationIgnored private var autoRefreshInFlight = false

    /// Coalesced, best-effort re-list for background triggers — return-to-Home,
    /// window activation, and the periodic Home poll. Keeps the list in sync with
    /// on-disk changes made elsewhere (opening an archived project auto-restores
    /// it; the Windows app touching the shared folder). Skips if a refresh is
    /// already running: the in-flight pass reflects the latest state, so a skip
    /// never leaves the list stale. Never runs while a project is open (the report
    /// is re-synced by capture callbacks; auto-reloading it could clobber edits).
    func autoRefresh() async {
        guard opened == nil, !autoRefreshInFlight else { return }
        autoRefreshInFlight = true
        defer { autoRefreshInFlight = false }
        await refresh()
    }

    func openSelected() async {
        guard let selectedPath else {
            opened = nil
            return
        }
        do {
            opened = try await store.openProject(at: selectedPath)
            errorMessage = nil
        } catch {
            opened = nil
            errorMessage = error.localizedDescription
            Log.store.error("openSelected failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Re-read the opened project from disk (after captured steps landed).
    func reloadOpened() async {
        guard let selectedPath else { return }
        opened = try? await store.openProject(at: selectedPath)
    }

    // MARK: - Export

    /// True while an export (flatten + write) is in flight — drives the Export
    /// menu's disabled/spinner state.
    private(set) var exporting = false
    /// Set on export failure → surfaced by ContentView's alert. Success reveals
    /// the file in Finder instead (no alert needed).
    var exportError: String?
    /// Set on package-import failure → surfaced by a separate ContentView alert.
    var importError: String?

    /// Export the currently-opened project to `format`. Thin wrapper over
    /// `export(projectPath:format:)` (used by the report toolbar + File ▸ Export).
    func exportOpened(format: ExportFormat) async {
        guard let path = selectedPath ?? opened?.dir else { return }
        await export(projectPath: path, format: format)
    }

    /// Flatten every shot that lacks a current marker-baked render, then ask the
    /// user where to save (a Save dialog pre-pointed at the project's `export/`
    /// folder — Save there for the default spot, or navigate anywhere for Save
    /// As), write the export, and reveal it in Finder. Works whether or not the
    /// project is the one currently open (the Home ⋯ menu exports by path).
    /// Fail-closed: if a step can't be flattened or the render gate refuses
    /// (unbaked redaction/crop), the error is surfaced and NO partial export is
    /// written — and the Save dialog only appears once the export is confirmed
    /// clean, so the user is never asked where to put something that can't be made.
    func export(projectPath: String, format: ExportFormat) async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            let loaded = try await store.openProject(at: projectPath)
            let manifest = try await ensureFlattened(dir: loaded.dir, manifest: loaded.manifest)
            // Prepared and safe — now let the user choose the destination.
            guard let dest = chooseExportDestination(dir: loaded.dir, title: manifest.title, format: format) else {
                return  // user cancelled the Save dialog
            }
            let result = try await exportProject(dir: loaded.dir, manifest: manifest, format: format, byline: preferences.exportByline, to: dest)
            // For a custom Markdown save, reveal the self-contained folder itself;
            // otherwise reveal the written file.
            let revealPath: String
            if case .custom(let d, _) = dest, format == .markdown {
                revealPath = d
            } else {
                revealPath = result.outputPath
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealPath)])
            // If we just re-flattened the project that's on screen, refresh it.
            if opened?.dir == loaded.dir { await reloadOpened() }
            Log.store.notice("exported \(format.rawValue, privacy: .public) (\(manifest.steps.count, privacy: .public) steps)")
        } catch {
            exportError = error.localizedDescription
            Log.store.error("export \(format.rawValue, privacy: .public) failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Save dialog for a single-project export: pre-pointed at the project's
    /// `export/` folder with the default filename, so clicking **Save** lands the
    /// export where it always would, while the user can navigate anywhere else for
    /// a Save-As. Returns nil if the user cancels.
    @MainActor
    private func chooseExportDestination(dir: String, title: String, format: ExportFormat) -> ExportDestination? {
        let exportDir = (dir as NSString).appendingPathComponent("export")
        try? FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.title = "Export"
        panel.message = format == .markdown
            ? "Choose where to save this export. Markdown is saved as a self-contained folder."
            : "Choose where to save this export."
        panel.prompt = "Save"
        panel.nameFieldStringValue = defaultExportFilename(title: title, format: format)
        panel.directoryURL = URL(fileURLWithPath: exportDir)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        switch format {
        case .html, .htmlPlain: panel.allowedContentTypes = [.html]
        case .pdf:              panel.allowedContentTypes = [.pdf]
        case .markdown:         panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        }
        // Bring the app fully forward first — otherwise the panel can open while
        // the app isn't the active app and its title-bar controls (move/resize)
        // don't respond until it's clicked.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent().path
        // Markdown writes a .md plus a sibling images folder. When the user picks
        // an arbitrary location, nest BOTH inside a single self-contained
        // <name>/ folder so the chosen spot stays tidy (one item, not two loose
        // ones). The default export/ folder is already dedicated, so it's left flat.
        if format == .markdown {
            let container = (parent as NSString).appendingPathComponent(stem)
            // The Save panel's overwrite prompt guarded "<stem>.md", but we write
            // into the "<stem>/" folder instead — so confirm replacement of an
            // existing export folder ourselves, or a re-export would silently
            // overwrite a prior (possibly edited) Markdown export + wipe its images.
            let fm = FileManager.default
            let mdInside = (container as NSString).appendingPathComponent("\(stem).md")
            let imgsInside = (container as NSString).appendingPathComponent("\(stem)-images")
            if fm.fileExists(atPath: mdInside) || fm.fileExists(atPath: imgsInside) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Replace the existing “\(stem)” export folder?"
                alert.informativeText = "A Markdown export named “\(stem)” already exists there. Saving replaces its Markdown file and images."
                alert.addButton(withTitle: "Replace")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            }
            return .custom(directory: container, stem: stem)
        }
        return .custom(directory: parent, stem: stem)
    }

    // MARK: - Shareable package (.zip)

    /// Confirm (for full mode) then export a shareable package. Full mode ships the
    /// un-redacted originals, so it gets an explicit warning first — centralized
    /// here so every entry point (toolbar / File menu / Home ⋯) shares it.
    func confirmAndExportPackage(projectPath: String, includeOriginals: Bool) {
        if includeOriginals {
            let alert = NSAlert()
            alert.messageText = "Include original screenshots?"
            alert.informativeText = "A full package includes the un-redacted original images so the recipient can fully re-edit the project — any redactions become recoverable. Choose Safe if redactions must stay permanent."
            alert.addButton(withTitle: "Include Originals")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await exportPackage(projectPath: projectPath, includeOriginals: includeOriginals) }
    }

    /// Convenience for the currently-open project (toolbar + File ▸ Export).
    func confirmAndExportPackageOpened(includeOriginals: Bool) {
        guard let path = selectedPath ?? opened?.dir else { return }
        confirmAndExportPackage(projectPath: path, includeOriginals: includeOriginals)
    }

    /// Flatten shots (safe mode needs current baked renders), assemble the .zip,
    /// and reveal it in Finder. Fail-closed like the document exports.
    func exportPackage(projectPath: String, includeOriginals: Bool) async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            let loaded = try await store.openProject(at: projectPath)
            let manifest = try await ensureFlattened(dir: loaded.dir, manifest: loaded.manifest)
            let result = try ExportKit.exportPackage(dir: loaded.dir, manifest: manifest, includeOriginals: includeOriginals)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.outputPath)])
            if opened?.dir == loaded.dir { await reloadOpened() }
            Log.store.notice("exported package originals=\(includeOriginals, privacy: .public)")
        } catch {
            exportError = error.localizedDescription
            Log.store.error("export package failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Prompt for a .zip and import it (File ▸ Import + Home). Uses an AppKit open
    /// panel so it works identically from a menu command or a button.
    func promptImportPackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a shotAI package (.zip) to import."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importPackage(from: url) }
    }

    /// Import an (untrusted) package into a fresh project, then open it.
    func importPackage(from url: URL) async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            let summary = try await ExportKit.importPackage(zipPath: url.path, into: store)
            await refresh()
            await open(path: summary.path)
            Log.store.notice("imported package → new project")
        } catch {
            importError = error.localizedDescription
            Log.store.error("import package failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Re-bake any shot whose render is missing or predates marker-baking, so the
    /// export gate only ever reads current, redaction-baked renders (with the
    /// click ring baked in — the report draws that as an overlay, but an exported
    /// file has no overlay layer). Persists each and returns the fresh manifest.
    /// Throws a friendly, step-scoped error (and exports nothing) if a shot can't
    /// be prepared — mirrors the Windows sop-prepare.ts flow.
    private func ensureFlattened(dir: String, manifest: ProjectManifest) async throws -> ProjectManifest {
        var changed = false
        var shotNo = 0
        for step in manifest.steps {
            if step.kind == .text { continue }              // text steps have no image
            shotNo += 1
            // Treat flattened:"" as "no render" — the SAME emptiness test the
            // render gate and the report use (a bare `!= nil` would skip re-baking
            // a step the gate would then read raw, dropping the click marker).
            let hasRender = !(step.flattened ?? "").isEmpty
            if hasRender, step.markerBaked == true { continue }
            if step.screenshot.isEmpty { continue }
            do {
                guard let png = try flattenRender(for: step, dir: dir) else {
                    throw ExportPrepError.stepFailed(shotNo, step.caption, "its screenshot couldn't be read")
                }
                var patch = StepPatch()
                patch.markerBaked = true
                _ = try await store.updateStep(at: dir, stepId: step.id, patch: patch, flattenedPng: png)
                changed = true
            } catch let e as ExportPrepError {
                throw e
            } catch {
                // Wrap Flatten/store errors (e.g. a redaction rounding to <1px) so
                // the user sees which step failed rather than a raw message.
                throw ExportPrepError.stepFailed(shotNo, step.caption, error.localizedDescription)
            }
        }
        guard changed else { return manifest }
        return try await store.openProject(at: dir).manifest    // fresh: now has flattened paths
    }

    /// A step-scoped preparation failure surfaced by `ensureFlattened`.
    private enum ExportPrepError: LocalizedError {
        case stepFailed(Int, String, String)
        var errorDescription: String? {
            switch self {
            case .stepFailed(let n, let caption, let why):
                let name = caption.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Step \(n) (\"\(name.isEmpty ? "untitled" : name)\") couldn't be prepared for export: \(why)"
            }
        }
    }

    // MARK: - SOP (Claude AI generation)

    /// Persisted generation settings (bound by Settings ▸ AI). Call
    /// `saveSopSettings()` after mutating.
    var sopSettings: SopSettings
    /// Observable mirror of the Keychain key status (so UI re-renders on change).
    private(set) var apiKeyPresent = false
    private(set) var apiKeySource: ApiKeySource = .none
    /// True while any SOP op (prepare/generate/revert) is in flight.
    private(set) var sopBusy = false
    /// Human-readable progress line shown while generating.
    private(set) var sopProgress: String?
    /// Set once a cost estimate is ready → drives the confirm dialog.
    var sopEstimate: SopEstimate?
    /// Surfaced by the report's alert.
    var sopError: String?

    @ObservationIgnored private let apiKeyStore: ApiKeyStore = KeychainApiKeyStore()
    @ObservationIgnored private lazy var sopService = SopService(keyStore: apiKeyStore)
    @ObservationIgnored private var sopTask: Task<Void, Never>?

    private static let sopSettingsKey = "sopSettings.v1"
    static func loadSopSettings() -> SopSettings {
        guard let data = UserDefaults.standard.data(forKey: sopSettingsKey),
              let s = try? JSONDecoder().decode(SopSettings.self, from: data) else { return DEFAULT_SOP_SETTINGS }
        return s
    }

    /// Persist the current settings (call from the Settings tab after edits).
    func saveSopSettings() {
        if let data = try? JSONEncoder().encode(sopSettings) {
            UserDefaults.standard.set(data, forKey: Self.sopSettingsKey)
        }
    }

    // MARK: - App preferences (theme / byline / capture)

    /// Persisted app preferences (bound by Settings ▸ Appearance/Capture). Call
    /// `savePreferences()` after mutating.
    var preferences: AppPreferences

    private static let preferencesKey = "appPreferences.v1"
    static func loadPreferences() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: preferencesKey),
              var p = try? JSONDecoder().decode(AppPreferences.self, from: data) else { return AppPreferences() }
        p.normalize()
        return p
    }

    /// Normalize + persist preferences (call from the Settings tabs after edits).
    func savePreferences() {
        preferences.normalize()
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: Self.preferencesKey)
        }
    }

    /// Change the projects folder (Settings ▸ General). Persists the new root and
    /// re-lists; the ProjectStore reads `settings.projectsDir()` live, so the new
    /// location takes effect immediately.
    func setProjectsDir(_ dir: String) async {
        let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.setProjectsDir(trimmed)
        // A folder switch is a deliberate reset: clear recents so the previous
        // root's projects (which listProjects also merges in, to support
        // "Open Project…" from anywhere) don't linger on Home. The new folder is
        // authoritative; recents rebuild as projects are opened.
        settings.setRecents([])
        // Leaving the current project — tear down the same transient state
        // closeToHome() does, so an in-flight SOP run can't outlive the switch.
        resetSopState()
        lastMerge = nil
        selectedPath = nil
        opened = nil
        await refresh()
        Log.store.notice("projects folder changed")
    }

    /// Refresh the observable key-status mirror from the Keychain.
    func refreshApiKeyStatus() {
        let s = apiKeyStore.status()
        apiKeyPresent = s.hasKey
        apiKeySource = s.source
    }

    /// Store the key (Keychain). Returns an error message, or nil on success. The
    /// key value never returns to the caller.
    @discardableResult func setApiKey(_ key: String) -> String? {
        defer { refreshApiKeyStatus() }
        do { try apiKeyStore.set(key); return nil } catch { return error.localizedDescription }
    }

    @discardableResult func clearApiKey() -> String? {
        defer { refreshApiKeyStatus() }
        do { try apiKeyStore.clear(); return nil } catch { return error.localizedDescription }
    }

    /// Validate the key/model with a cheap call; returns a user-facing status line.
    func testApiKey() async -> String {
        do {
            let m = try await sopService.testKey(settings: sopSettings)
            return "Connected — the key works with \(m.rawValue)."
        } catch { return error.localizedDescription }
    }

    /// Generate is available when SOP is on, a key exists, and there's a shot step.
    var canGenerateSop: Bool {
        sopSettings.enabled && apiKeyPresent
            && (opened?.manifest.steps.contains { $0.kind != .text } ?? false)
    }
    /// Revert is available when an AI snapshot exists.
    var canRevertSop: Bool { opened?.manifest.sopBackup != nil }

    /// Flatten shots (fail-closed, like export), then compute a cost estimate →
    /// sets `sopEstimate`, which drives the confirm dialog before any generation.
    /// Runs inside `sopTask` so Cancel works during this phase too (a hung
    /// count_tokens can otherwise leave the panel stuck busy with a dead Cancel).
    func prepareSop() {
        guard let current = opened, !sopBusy else { return }
        guard sopSettings.enabled else { sopError = ClaudeError.disabled.errorDescription; return }
        guard apiKeyPresent else { sopError = "Add your Anthropic API key in Settings ▸ AI first."; return }
        sopBusy = true; sopError = nil; sopProgress = "Preparing…"
        let dir = current.dir
        let manifest = current.manifest
        let settings = sopSettings
        sopTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.ensureFlattened(dir: dir, manifest: manifest)
                await self.reloadOpened()
                guard let fresh = self.opened else { self.finishSop(error: nil); return }
                let est = try await self.sopService.estimate(dir: fresh.dir, manifest: fresh.manifest, settings: settings)
                self.finishSop(error: nil)
                self.sopEstimate = est   // triggers the confirm dialog
            } catch {
                self.finishSop(error: Task.isCancelled ? nil : error.localizedDescription)
            }
        }
    }

    /// After the user confirms the estimate: stream the generation and apply it
    /// inline (snapshotting for revert). Cancelable via `cancelSop()`.
    func confirmGenerateSop() {
        guard let current = opened, sopEstimate != nil, !sopBusy else { return }
        sopEstimate = nil
        sopBusy = true; sopError = nil; sopProgress = "Preparing…"
        let dir = current.dir
        let path = selectedPath ?? current.dir
        let manifest = current.manifest
        let settings = sopSettings
        sopTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await self.sopService.generate(dir: dir, manifest: manifest, settings: settings) { p in
                    Task { @MainActor in self.sopProgress = Self.progressText(p) }
                }
                _ = try await SOPKit.applySopEdits(
                    store: self.store, projectPath: path, plan: plan, model: settings.model, tone: settings.tone)
                await self.reloadOpened()
                await self.refresh()
                self.finishSop(error: nil)
                Log.store.notice("SOP generated (\(plan.steps.count, privacy: .public) step edits)")
            } catch {
                // A user cancel surfaces as a transport error; treat it as silent.
                self.finishSop(error: Task.isCancelled ? nil : error.localizedDescription)
            }
        }
    }

    private func finishSop(error: String?) {
        sopBusy = false
        sopProgress = nil
        sopTask = nil
        if let error { sopError = error }
    }

    /// Cancel an in-flight generation.
    func cancelSop() { sopTask?.cancel() }
    /// Dismiss the estimate confirm dialog without generating.
    func dismissSopEstimate() { sopEstimate = nil }

    /// Clear all transient SOP run state (cancelling any in-flight task). Called
    /// on navigation so one project's generation/busy state can't leak onto
    /// another project's report (the state is global to the shared AppModel).
    private func resetSopState() {
        sopTask?.cancel()
        sopTask = nil
        sopBusy = false
        sopProgress = nil
        sopEstimate = nil
        sopError = nil
    }

    /// Restore the pre-AI snapshot (Revert AI edits).
    func revertSop() async {
        guard let current = opened, !sopBusy else { return }
        let path = selectedPath ?? current.dir
        sopBusy = true; sopError = nil
        defer { sopBusy = false }
        do {
            _ = try await SOPKit.revertSop(store: store, projectPath: path)
            await reloadOpened()
            await refresh()
        } catch {
            sopError = error.localizedDescription
        }
    }

    private static func progressText(_ p: SopProgress) -> String {
        switch p {
        case .preparing: "Preparing…"
        case .thinking: "Claude is thinking…"
        case .writing(let chars): "Writing the SOP… (\(chars) characters)"
        case .done: "Finishing…"
        }
    }

    /// Create a project and select it (the "record into a new project" flow).
    /// An optional title names it; nil falls back to the store's timestamp name.
    /// Returns its path, or nil on failure.
    @discardableResult
    func createAndSelectProject(title: String? = nil) async -> String? {
        do {
            let summary = try await store.createProject(title: title)
            await refresh()
            selectedPath = summary.path
            opened = try await store.openProject(at: summary.path)
            Log.store.notice("createAndSelectProject succeeded")
            return summary.path
        } catch {
            errorMessage = error.localizedDescription
            Log.store.error("createAndSelectProject failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// Open a project into the detail view (Home → detail navigation).
    func open(path: String) async {
        Log.ui.info("open(path:) navigating to project detail")
        lastMerge = nil
        resetSopState()  // don't carry a prior project's SOP run/state across
        selectedPath = path
        await openSelected()
    }

    /// Return to the Home surface (the "← Back" affordance).
    func closeToHome() {
        lastMerge = nil
        resetSopState()  // cancel/clear any in-flight generation on navigate-away
        selectedPath = nil
        opened = nil
        errorMessage = nil
    }

    /// Rename a project, then re-list. Empty/whitespace names are ignored.
    func renameProject(path: String, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await store.renameProject(at: path, title: trimmed)
            await refresh()
            if selectedPath == path { await reloadOpened() }
            Log.store.notice("renameProject succeeded")
        } catch {
            errorMessage = error.localizedDescription
            Log.store.error("renameProject failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Delete a project's folder, then re-list. Returns to Home if it was open.
    func deleteProject(path: String) async {
        do {
            try await store.deleteProject(at: path)
            if selectedPath == path { closeToHome() }
            await refresh()
            Log.store.notice("deleteProject succeeded")
        } catch {
            errorMessage = error.localizedDescription
            Log.store.error("deleteProject failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Archive a project (compress its files in place) and re-list. It stays under
    /// the Archive tab and auto-restores on open.
    func archiveProject(path: String) async {
        do {
            try await store.archiveProject(at: path)
            await refresh()
            Log.store.notice("archiveProject succeeded")
        } catch {
            errorMessage = error.localizedDescription
            Log.store.error("archiveProject failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Restore an archived project (without opening it) and re-list.
    func unarchiveProject(path: String) async {
        do {
            try await store.unarchiveProject(at: path)
            await refresh()
            Log.store.notice("unarchiveProject succeeded")
        } catch {
            errorMessage = error.localizedDescription
            Log.store.error("unarchiveProject failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Bulk operations (Home multi-select)

    /// Archive several projects, then re-list once. Best-effort: each is attempted
    /// independently and failures are counted into a single message (a project
    /// already archived is a no-op in the store, not a failure).
    func archiveProjects(paths: [String]) async {
        var failed = 0
        for path in paths {
            do { try await store.archiveProject(at: path) }
            catch {
                failed += 1
                Log.store.error("bulk archive failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
            }
        }
        await refresh()
        if failed > 0 { errorMessage = "\(failed) of \(paths.count) project\(paths.count == 1 ? "" : "s") couldn’t be archived." }
        Log.store.notice("bulk archive: \(paths.count - failed, privacy: .public)/\(paths.count, privacy: .public) ok")
    }

    /// Restore several archived projects, then re-list once.
    func unarchiveProjects(paths: [String]) async {
        var failed = 0
        for path in paths {
            do { try await store.unarchiveProject(at: path) }
            catch {
                failed += 1
                Log.store.error("bulk restore failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
            }
        }
        await refresh()
        if failed > 0 { errorMessage = "\(failed) of \(paths.count) project\(paths.count == 1 ? "" : "s") couldn’t be restored." }
        Log.store.notice("bulk restore: \(paths.count - failed, privacy: .public)/\(paths.count, privacy: .public) ok")
    }

    /// Delete several projects' folders, then re-list once. Returns to Home if the
    /// open project is among them.
    func deleteProjects(paths: [String]) async {
        var failed = 0
        for path in paths {
            do {
                try await store.deleteProject(at: path)
                if selectedPath == path { closeToHome() }
            } catch {
                failed += 1
                Log.store.error("bulk delete failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
            }
        }
        await refresh()
        if failed > 0 { errorMessage = "\(failed) of \(paths.count) project\(paths.count == 1 ? "" : "s") couldn’t be deleted." }
        Log.store.notice("bulk delete: \(paths.count - failed, privacy: .public)/\(paths.count, privacy: .public) ok")
    }

    /// Export several projects to `format` (each into its own export/ folder), then
    /// reveal the projects root. Same fail-closed flatten as the single export;
    /// failures are counted. Opening a project flattens+may auto-restore it, so a
    /// re-list follows.
    func exportProjects(paths: [String], format: ExportFormat) async {
        guard !exporting, !paths.isEmpty else { return }
        // Claim `exporting` BEFORE showing any modal. The chooser below spins a
        // nested (common-mode) run loop, during which a queued exportProjects
        // Task could otherwise pass the `!exporting` guard and stack a second
        // dialog / double-run (the Home button's disable is gated on this flag).
        // Matches the single-project export() path. The early returns below reset
        // it via defer.
        exporting = true
        defer { exporting = false }
        // Ask up front: drop each export in its own project folder, or gather all
        // of them into one folder the user picks. Cancelling backs out entirely.
        guard let target = chooseBulkExportTarget(count: paths.count, format: format) else { return }
        var failed = 0
        var usedStems = Set<String>()  // dedup filenames within a single-folder batch
        for path in paths {
            do {
                let loaded = try await store.openProject(at: path)
                let manifest = try await ensureFlattened(dir: loaded.dir, manifest: loaded.manifest)
                let dest: ExportDestination
                switch target {
                case .eachProjectFolder:
                    dest = .projectFolder
                case .oneFolder(let dir):
                    dest = bulkCustomDestination(in: dir, title: manifest.title, format: format, used: &usedStems)
                }
                _ = try await exportProject(dir: loaded.dir, manifest: manifest, format: format, byline: preferences.exportByline, to: dest)
            } catch {
                failed += 1
                Log.store.error("bulk export \(format.rawValue, privacy: .public) failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
            }
        }
        if opened != nil { await reloadOpened() }
        await refresh()
        // Reveal only when something was actually written (matches single export()).
        // For a chosen folder, reveal that folder; otherwise the projects dir.
        if failed < paths.count {
            let revealDir: String
            if case .oneFolder(let dir) = target { revealDir = dir } else { revealDir = settings.projectsDir() }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealDir)])
        }
        if failed > 0 { exportError = "\(failed) of \(paths.count) export\(paths.count == 1 ? "" : "s") failed." }
        Log.store.notice("bulk export \(format.rawValue, privacy: .public): \(paths.count - failed, privacy: .public)/\(paths.count, privacy: .public) ok")
    }

    /// Where a bulk export should land.
    private enum BulkExportTarget {
        case eachProjectFolder                 // per-project export/ (historical)
        case oneFolder(directory: String)      // all exports in one chosen folder
    }

    /// Ask whether to save each guide in its own project's `export/` folder or
    /// gather them all into one folder of the user's choosing. Returns nil if the
    /// user cancels either the choice or the folder picker.
    @MainActor
    private func chooseBulkExportTarget(count: Int, format: ExportFormat) -> BulkExportTarget? {
        let alert = NSAlert()
        alert.messageText = "Export \(count) project\(count == 1 ? "" : "s")"
        alert.informativeText = "Save each guide in its own project’s export folder, or gather them all into one folder you choose."
        alert.addButton(withTitle: "Each Project’s Folder")  // .alertFirstButtonReturn
        alert.addButton(withTitle: "Choose One Folder…")     // .alertSecondButtonReturn
        alert.addButton(withTitle: "Cancel")                 // .alertThirdButtonReturn
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .eachProjectFolder
        case .alertSecondButtonReturn:
            let panel = NSOpenPanel()
            panel.title = "Choose Export Folder"
            panel.message = "Choose a folder to save all \(count) export\(count == 1 ? "" : "s") into."
            panel.prompt = "Export Here"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            return .oneFolder(directory: url.path)
        default:
            return nil
        }
    }

    /// A collision-safe destination inside one shared folder. Non-Markdown lands
    /// as "<stem><ext>"; Markdown gets its own self-contained "<stem>/" subfolder
    /// (matching the single custom-Markdown export, and keeping each guide's
    /// images with its `.md`). Dedupes against BOTH the filesystem and the stems
    /// already claimed earlier in this batch, so two same-titled projects — or a
    /// re-export over a prior one — never clobber each other.
    @MainActor
    private func bulkCustomDestination(
        in directory: String, title: String, format: ExportFormat, used: inout Set<String>
    ) -> ExportDestination {
        let base = (defaultExportFilename(title: title, format: format) as NSString).deletingPathExtension
        let fm = FileManager.default
        func taken(_ stem: String) -> Bool {
            if used.contains(stem.lowercased()) { return true }
            // Markdown occupies a "<stem>/" folder; others a "<stem><ext>" file.
            let probe = format == .markdown ? stem : "\(stem)\(format.ext)"
            return fm.fileExists(atPath: (directory as NSString).appendingPathComponent(probe))
        }
        var stem = base
        var n = 2
        while taken(stem) { stem = "\(base) (\(n))"; n += 1 }
        used.insert(stem.lowercased())
        if format == .markdown {
            return .custom(directory: (directory as NSString).appendingPathComponent(stem), stem: stem)
        }
        return .custom(directory: directory, stem: stem)
    }

    /// Reveal a project's folder in Finder (confined to a known project path).
    func revealInFinder(path: String) {
        guard projects.contains(where: { $0.path == path }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// The "Open Project…" panel flow: a user-picked folder becomes a known
    /// project (validated, recorded in recents), then selected.
    func openUserPicked(_ url: URL) async {
        do {
            let openedProject = try await store.openUserSelectedProject(at: url.path)
            errorMessage = nil
            await refresh()
            selectedPath = openedProject.dir
            opened = openedProject
        } catch {
            errorMessage = "Not a shotAI project: \(url.path) (\(error.localizedDescription))"
            Log.store.error("openUserPicked failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Report authoring (R1: inline text + callouts)

    /// One-level undo for the most recent merge (cleared by any other edit).
    struct MergeUndo { let projectDir: String; let dropped: ProjectStep; let dropIndex: Int; let keptPre: ProjectStep }
    private(set) var lastMerge: MergeUndo?
    var canUndoMerge: Bool { lastMerge != nil && lastMerge?.projectDir == opened?.dir }

    private func reloadOnly() async {
        await reloadOpened()  // re-render the report
        await refresh()       // updatedAt bumped → Home re-sorts
    }

    private func afterEdit() async {
        lastMerge = nil       // any normal edit invalidates a pending merge-undo
        await reloadOnly()
    }

    /// Set the overview preamble (stored even when empty — shows an editable box).
    func setIntro(heading: String, body: String) async {
        guard let dir = opened?.dir else { return }
        do { try await store.setIntro(at: dir, heading: heading, body: body); await afterEdit() }
        catch {
            errorMessage = error.localizedDescription
            Log.store.error("setIntro failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Remove the overview preamble.
    func removeIntro() async {
        guard let dir = opened?.dir else { return }
        do { try await store.removeIntro(at: dir); await afterEdit() }
        catch {
            errorMessage = error.localizedDescription
            Log.store.error("removeIntro failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Add a text step or note/caution/warning callout (append when atIndex nil).
    func addTextStep(heading: String = "", body: String = "", callout: CalloutKind? = nil, atIndex: Int? = nil) async {
        guard let dir = opened?.dir else { return }
        do { try await store.addTextStep(at: dir, atIndex: atIndex, heading: heading, body: body, callout: callout); await afterEdit() }
        catch {
            errorMessage = error.localizedDescription
            Log.store.error("addTextStep failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Edit a step's text fields (only the non-nil ones are written).
    func editStepText(
        stepId: String, caption: String? = nil, note: String? = nil,
        heading: String? = nil, body: String? = nil, callout: CalloutKind? = nil
    ) async {
        guard let dir = opened?.dir else { return }
        do {
            try await store.editStepText(
                at: dir, stepId: stepId, caption: caption, note: note,
                heading: heading, body: body, callout: callout
            )
            await afterEdit()
        } catch {
            errorMessage = error.localizedDescription
            Log.store.error("editStepText failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Convert a text step to a callout (`kind`) or back to plain text (`nil`).
    /// The visible step numbers renumber automatically since callouts aren't
    /// numbered.
    func setStepCallout(stepId: String, to kind: CalloutKind?) async {
        guard let dir = opened?.dir else { return }
        do {
            try await store.setStepCallout(at: dir, stepId: stepId, callout: kind)
            await afterEdit()
        } catch {
            errorMessage = error.localizedDescription
            Log.store.error("setStepCallout failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Report display zoom/pan (R3 — per-step, display-only)

    /// Set a step's report zoom (clamped 1…max; 1 = fit). Display-only: the patch
    /// doesn't touch annotations/crop, so updateStep leaves the baked render alone.
    func setReportZoom(stepId: String, _ zoom: Double) async {
        guard let dir = opened?.dir else { return }
        var patch = StepPatch()
        patch.reportZoom = min(max(zoom, 1), ReportPresentation.zoomMax)
        await applyDisplayPatch(dir: dir, stepId: stepId, patch: patch, what: "setReportZoom")
    }

    /// Set a step's report pan (fractions 0…1 of the scrollable range; 0.5 = center).
    func setReportPan(stepId: String, panX: Double, panY: Double) async {
        guard let dir = opened?.dir else { return }
        var patch = StepPatch()
        patch.reportPanX = min(max(panX, 0), 1)
        patch.reportPanY = min(max(panY, 0), 1)
        await applyDisplayPatch(dir: dir, stepId: stepId, patch: patch, what: "setReportPan")
    }

    private func applyDisplayPatch(dir: String, stepId: String, patch: StepPatch, what: String) async {
        do {
            _ = try await store.updateStep(at: dir, stepId: stepId, patch: patch, flattenedPng: nil)
            await reloadOnly() // display-only → don't clear a pending merge-undo
        } catch {
            errorMessage = error.localizedDescription
            Log.store.error("\(what, privacy: .public) failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Report structure (R2: delete / reorder)

    /// Delete one step (and its screenshot/render), then re-render + re-list.
    func deleteStep(id: String) async {
        guard let dir = opened?.dir else { return }
        do { try await store.deleteSteps(at: dir, ids: [id]); await afterEdit() }
        catch {
            errorMessage = error.localizedDescription
            Log.store.error("deleteStep failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Move a step up (-1) or down (+1) among the steps, clamped at the ends.
    func moveStep(id: String, by offset: Int) async {
        guard let opened else { return }
        var ids = opened.manifest.steps.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return }
        let j = i + offset
        guard j >= 0, j < ids.count else { return }
        ids.swapAt(i, j)
        do { try await store.reorderSteps(at: opened.dir, orderedIds: ids); await afterEdit() }
        catch {
            errorMessage = error.localizedDescription
            Log.store.error("moveStep failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Move a numbered step to a new display position (1-based over the numbered,
    /// i.e. non-callout, steps — matching the badge). It lands adjacent to the
    /// step currently at that position; everything renumbers in turn. Callout
    /// steps (unnumbered) keep their place.
    func moveStep(id: String, toPosition position: Int) async {
        guard let opened else { return }
        let steps = opened.manifest.steps
        let numbered = steps.filter { !ReportPresentation.isCalloutStep($0) }.map(\.id)
        guard let cur = numbered.firstIndex(of: id) else { return } // only numbered steps have a position
        let currentPos = cur + 1
        let target = max(1, min(position, numbered.count))
        guard target != currentPos else { return }
        let targetId = numbered[target - 1]
        var order = steps.map(\.id)
        order.removeAll { $0 == id }
        guard let ti = order.firstIndex(of: targetId) else { return }
        order.insert(id, at: target > currentPos ? ti + 1 : ti) // after when moving down, before when up
        do { try await store.reorderSteps(at: opened.dir, orderedIds: order); await afterEdit() }
        catch {
            errorMessage = error.localizedDescription
            Log.store.error("moveStep(toPosition) failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Drag-and-drop reorder: move `draggedId` to just before `targetId`
    /// (any step kind — callouts included). `targetId == nil` moves it to the end.
    func dropStep(_ draggedId: String, before targetId: String?) async {
        guard let opened, draggedId != targetId else { return }
        var order = opened.manifest.steps.map(\.id)
        guard let from = order.firstIndex(of: draggedId) else { return }
        order.remove(at: from)
        if let targetId, let ti = order.firstIndex(of: targetId) {
            order.insert(draggedId, at: ti) // before the target (uses its post-removal index)
        } else {
            order.append(draggedId)
        }
        do { try await store.reorderSteps(at: opened.dir, orderedIds: order); await afterEdit() }
        catch {
            errorMessage = error.localizedDescription
            Log.store.error("dropStep failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Import an image file as a new step at `atIndex` (nil → append).
    func importImageStep(data: Data, atIndex: Int?) async {
        guard let dir = opened?.dir else { return }
        do { try await store.importImageStep(at: dir, atIndex: atIndex, imageData: data); await afterEdit() }
        catch {
            errorMessage = error.localizedDescription
            Log.store.error("importImageStep failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Merge a step into the following step (the Windows right-click→menu-selection
    /// fold): keep the NEXT step's screenshot, bake this step's click marker onto
    /// it (so both clicks show), drop this step. Shot→shot only.
    func mergeIntoNext(id: String) async {
        guard let opened else { return }
        let steps = opened.manifest.steps
        guard let i = steps.firstIndex(where: { $0.id == id }), i + 1 < steps.count else { return }
        let current = steps[i], next = steps[i + 1]
        guard current.kind != .text, next.kind != .text, !next.screenshot.isEmpty else { return }
        // Load the KEPT (next) step's raw screenshot to re-bake from. No-symlinks:
        // the merged render is egress-able, so refuse a symlinked source.
        guard let abs = confinePathNoSymlinks(dir: opened.dir, rel: next.screenshot),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: abs) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            errorMessage = "Couldn't load the next step's screenshot to merge into."
            return
        }
        // next's own annotations + this step's click carried in as a marker,
        // its GLOBAL coords mapped into the kept step's image space (both clicks
        // are on the same monitor, so global maps exactly — origin recovered from
        // the kept click; fall back to the dropped step's own image coords).
        var merged = next.annotations
        if let dc = current.click {
            let mx: Double, my: Double
            if let kc = next.click {
                let ks = kc.imageScale ?? 1
                let originX = kc.global.x - kc.image.x / ks
                let originY = kc.global.y - kc.image.y / ks
                mx = (dc.global.x - originX) * ks
                my = (dc.global.y - originY) * ks
            } else {
                mx = dc.image.x
                my = dc.image.y
            }
            let cw = Double(cg.width), ch = Double(cg.height)
            merged.append(.marker(MarkerAnnotation(
                id: "merge-\(current.id)",
                x: min(max(mx, 0), max(0, cw - 1)),
                y: min(max(my, 0), max(0, ch - 1)),
                color: AnnotationStyle.markerColor(for: current), radius: dc.radius)))
        }
        let keepMarker: Flatten.Marker? = next.click.map { c in
            Flatten.Marker(x: c.image.x, y: c.image.y,
                           color: AnnotationStyle.markerColor(for: next), radius: c.radius.map { CGFloat($0) })
        }
        do {
            let png = try Flatten.toPNG(image: cg, annotations: merged, crop: next.crop, marker: keepMarker)
            var patch = StepPatch()
            patch.annotations = merged
            patch.crop = .set(next.crop)
            patch.markerBaked = true
            // Combine the two steps' text (dropped → kept), dropping empties.
            let cap = Self.joinText(current.caption, next.caption, " → ")
            if !cap.isEmpty { patch.caption = cap }
            let bod = Self.joinText(current.body, next.body, "\n\n")
            if !bod.isEmpty { patch.body = bod }
            let nte = Self.joinText(current.note, next.note, "\n\n")
            if !nte.isEmpty { patch.note = nte }
            // Snapshot for one-level undo BEFORE the merge mutates the manifest.
            lastMerge = MergeUndo(projectDir: opened.dir, dropped: current, dropIndex: i, keptPre: next)
            try await store.mergeSteps(at: opened.dir, keepId: next.id, dropId: current.id, patch: patch, flattenedPng: png)
            await reloadOnly() // NOT afterEdit — keep lastMerge so "Undo merge" can offer it
        } catch {
            lastMerge = nil
            errorMessage = error.localizedDescription
            Log.store.error("mergeIntoNext failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Undo the most recent merge: restore the kept step's pre-merge state,
    /// re-insert the dropped step, and regenerate the kept step's render if it had
    /// one (the merge overwrote it).
    func undoLastMerge() async {
        guard let m = lastMerge, let opened, m.projectDir == opened.dir else { return }
        lastMerge = nil
        do {
            let keptPng = m.keptPre.flattened != nil ? try flattenRender(for: m.keptPre, dir: opened.dir) : nil
            try await store.restoreMerge(at: opened.dir, keptPre: m.keptPre, dropped: m.dropped, dropIndex: m.dropIndex, keptPng: keptPng)
            await reloadOnly()
        } catch {
            errorMessage = error.localizedDescription
            Log.store.error("undoLastMerge failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Re-bake a step's own render (raw + its annotations/crop + its click marker).
    /// Reads the source via `confinePathNoSymlinks`: the render this produces is
    /// egress-able (Claude/export), so a symlinked screenshot must not launder an
    /// off-project image into it — refuse the bake instead.
    private func flattenRender(for step: ProjectStep, dir: String) throws -> Data? {
        guard !step.screenshot.isEmpty,
              let abs = confinePathNoSymlinks(dir: dir, rel: step.screenshot),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: abs) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        let marker: Flatten.Marker? = step.click.map { c in
            Flatten.Marker(x: c.image.x, y: c.image.y, color: AnnotationStyle.markerColor(for: step), radius: c.radius.map { CGFloat($0) })
        }
        return try Flatten.toPNG(image: cg, annotations: step.annotations, crop: step.crop, marker: marker)
    }

    /// Join two text fields (dropped → kept), trimming and dropping empties.
    private static func joinText(_ a: String?, _ b: String?, _ separator: String) -> String {
        [a, b].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }
}
