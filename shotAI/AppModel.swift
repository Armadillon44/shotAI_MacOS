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
            return summary.path
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Open a project into the detail view (Home → detail navigation).
    func open(path: String) async {
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Delete a project's folder, then re-list. Returns to Home if it was open.
    func deleteProject(path: String) async {
        do {
            try await store.deleteProject(at: path)
            if selectedPath == path { closeToHome() }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
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
        }
    }
}
