import AppKit
import CoreGraphics
import EditorKit
import ExportKit
import Foundation
import ImageIO
import Observation
import ShotModel
import UniformTypeIdentifiers

/// UI-facing state for the Phase A read-only viewer: the project list and the
/// currently opened project. All disk work happens inside the ProjectStore
/// actor; this object just mirrors results onto the main actor.
@MainActor
@Observable
final class AppModel {
    let store: ProjectStore
    private(set) var projects: [ProjectSummary] = []
    private(set) var opened: ProjectStore.OpenedProject?
    var selectedPath: String?
    var errorMessage: String?

    var projectsDirDisplay: String {
        (defaultProjectsDir() as NSString).abbreviatingWithTildeInPath
    }

    init(store: ProjectStore = ProjectStore(settings: UserDefaultsSettings())) {
        self.store = store
    }

    func refresh() async {
        projects = await store.listProjects()
        Log.store.debug("refresh listed \(self.projects.count, privacy: .public) projects")
        // Keep a live selection when its project vanished from disk.
        if let selectedPath, !projects.contains(where: { $0.path == selectedPath }) {
            self.selectedPath = nil
            opened = nil
        }
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

    /// Flatten every shot that lacks a current marker-baked render, then export
    /// the project at `projectPath` to `format` under its `export/` folder and
    /// reveal the file in Finder. Works whether or not the project is the one
    /// currently open (the Home ⋯ menu exports by path). Fail-closed: if a step
    /// can't be flattened or the render gate refuses (unbaked redaction/crop), the
    /// error is surfaced and NO partial export is written. Mirrors the Windows
    /// flow (ensureFlattened → exportProject).
    func export(projectPath: String, format: ExportFormat) async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            let loaded = try await store.openProject(at: projectPath)
            let manifest = try await ensureFlattened(dir: loaded.dir, manifest: loaded.manifest)
            let result = try await exportProject(dir: loaded.dir, manifest: manifest, format: format)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.outputPath)])
            // If we just re-flattened the project that's on screen, refresh it.
            if opened?.dir == loaded.dir { await reloadOpened() }
            Log.store.notice("exported \(format.rawValue, privacy: .public) (\(manifest.steps.count, privacy: .public) steps)")
        } catch {
            exportError = error.localizedDescription
            Log.store.error("export \(format.rawValue, privacy: .public) failed [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
        }
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
        selectedPath = path
        await openSelected()
    }

    /// Return to the Home surface (the "← Back" affordance).
    func closeToHome() {
        lastMerge = nil
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
        // Load the KEPT (next) step's raw screenshot to re-bake from.
        guard let abs = confinePath(dir: opened.dir, rel: next.screenshot),
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
    private func flattenRender(for step: ProjectStep, dir: String) throws -> Data? {
        guard !step.screenshot.isEmpty,
              let abs = confinePath(dir: dir, rel: step.screenshot),
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
