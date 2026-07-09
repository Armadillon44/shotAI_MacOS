import AppKit
import Foundation
import Observation
import ShotModel

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
        selectedPath = path
        await openSelected()
    }

    /// Return to the Home surface (the "← Back" affordance).
    func closeToHome() {
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

    private func afterEdit() async {
        await reloadOpened()  // re-render the report
        await refresh()       // updatedAt bumped → Home re-sorts
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
}
