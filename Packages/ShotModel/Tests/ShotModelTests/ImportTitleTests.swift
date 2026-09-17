import Foundation
import Testing
@testable import ShotModel

/// A package whose author cleared the title used to import as a blank Home row.
/// `readManifest` supplies a fallback on the next OPEN, which is too late: the
/// row is unidentifiable precisely while the user is hunting for what they just
/// imported. Windows coerces at the import boundary; this is the macOS half.
struct ImportTitleTests {

    private func store() throws -> ProjectStore {
        let dir = NSTemporaryDirectory() + "shotai-import-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return ProjectStore(settings: InMemorySettings(projectsDir: dir))
    }

    private func manifest(title: String) -> ProjectManifest {
        ProjectManifest(id: "src", title: title, createdAt: "2026-01-01T00:00:00.000Z",
                        updatedAt: "2026-01-01T00:00:00.000Z")
    }

    @Test func anEmptyTitleImportsUnderTheSharedFallback() async throws {
        let store = try store()
        let s = try await store.createProjectFromImport(manifest: manifest(title: ""), files: [])
        #expect(s.title == "Imported project",
                "a blank row is unidentifiable exactly when the user is looking for it")
        // The summary is what Home renders, but the value must be on disk too —
        // otherwise the row is right until something re-reads the manifest.
        let onDisk = try await store.openProject(at: s.path).manifest
        #expect(onDisk.title == "Imported project")
    }

    @Test func arealTitleIsLeftAlone() async throws {
        let store = try store()
        let s = try await store.createProjectFromImport(manifest: manifest(title: "Quarterly Close"), files: [])
        #expect(s.title == "Quarterly Close", "the fallback must not overwrite an author's title")
    }

    /// Windows tests emptiness with a falsy check, so `""` falls back and a
    /// whitespace-only title is KEPT. Trimming here would look like a fix and be
    /// a new divergence, so the asymmetry is pinned rather than left to taste.
    @Test func aWhitespaceOnlyTitleIsKeptToMatchWindows() async throws {
        let store = try store()
        let s = try await store.createProjectFromImport(manifest: manifest(title: "   "), files: [])
        #expect(s.title == "   ", "Windows keeps this; diverging here would be a new bug, not a fix")
    }
}
