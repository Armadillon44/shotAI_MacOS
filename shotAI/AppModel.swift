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
    /// Returns its path, or nil on failure.
    func createAndSelectProject() async -> String? {
        do {
            let summary = try await store.createProject()
            await refresh()
            selectedPath = summary.path
            opened = try await store.openProject(at: summary.path)
            return summary.path
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
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
