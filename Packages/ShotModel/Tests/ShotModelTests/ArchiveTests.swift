import Foundation
import Testing
@testable import ShotModel

/// Phase 1 of the archive port: typed archived/archivedAt fields + the read side
/// (unpack) + auto-unarchive-on-open. Fixes the P0 interop bug where a
/// Windows-archived project opened on macOS as "Image missing".
@Suite struct ArchiveTests {
    private func tempDir() throws -> (root: String, proj: String) {
        let root = NSTemporaryDirectory() + "shotai-arch-\(UUID().uuidString)"
        let proj = (root as NSString).appendingPathComponent("proj")
        try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        return (root, proj)
    }

    private func writeArchivedManifest(_ dir: String, updatedAt: String) throws {
        let m = ProjectManifest(id: "p", title: "T", createdAt: "2026-01-01T00:00:00Z",
                                updatedAt: updatedAt, archived: true, archivedAt: "2026-07-01T00:00:00Z")
        try ProjectJSON.encodeManifest(m)
            .write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("project.json")))
    }

    @Test func decodesTypedArchivedFields() throws {
        let json = #"{"version":1,"id":"p","title":"T","createdWith":"shotAI","createdAt":"","updatedAt":"","captureSettings":null,"steps":[],"intro":null,"sopBackup":null,"archived":true,"archivedAt":"2026-07-01T00:00:00Z"}"#
        let m = try ProjectJSON.decodeManifest(Data(json.utf8))
        #expect(m.archived == true)
        #expect(m.archivedAt == "2026-07-01T00:00:00Z")
        // A live project (no fields) decodes to false/nil.
        let live = try ProjectJSON.decodeManifest(Data(#"{"version":1,"id":"p","title":"T","steps":[]}"#.utf8))
        #expect(live.archived == false)
        #expect(live.archivedAt == nil)
    }

    @Test func unpackRestoresBulkDirsAndRemovesZip() throws {
        let (root, dir) = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let zip = zipStored([
            ("shots/step-0001.png", Data([0x89, 0x50, 0x4e, 0x47])),
            ("export/report.html", Data("<html></html>".utf8)),
        ])
        try zip.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("archive.zip")))
        #expect(Archive.isArchivedOnDisk(dir))
        try Archive.unpackArchive(dir)
        #expect(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("shots/step-0001.png")))
        #expect(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("export/report.html")))
        #expect(!Archive.isArchivedOnDisk(dir))  // zip removed after verify
    }

    @Test func unpackRejectsEntryOutsideBulkDirsAndKeepsZip() throws {
        let (root, dir) = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        try zipStored([("evil.txt", Data("x".utf8))])
            .write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("archive.zip")))
        #expect(throws: ArchiveError.self) { try Archive.unpackArchive(dir) }
        #expect(Archive.isArchivedOnDisk(dir))  // fail-closed: zip preserved
    }

    @Test func openProjectAutoUnarchivesWithoutBumpingUpdatedAt() async throws {
        let (root, dir) = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        try writeArchivedManifest(dir, updatedAt: "2026-06-01T00:00:00Z")
        try zipStored([("shots/a.png", Data([1, 2, 3]))])
            .write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("archive.zip")))

        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let opened = try await store.openProject(at: dir)

        #expect(opened.manifest.archived == false)                        // flag cleared
        #expect(opened.manifest.archivedAt == nil)
        #expect(opened.manifest.updatedAt == "2026-06-01T00:00:00Z")       // NOT bumped (open ≠ edit)
        #expect(!Archive.isArchivedOnDisk(dir))                            // restored
        #expect(FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("shots/a.png")))
    }

    @Test func listProjectsMarksArchivedSummaries() async throws {
        let (root, dir) = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        try writeArchivedManifest(dir, updatedAt: "2026-06-01T00:00:00Z")
        try zipStored([("shots/a.png", Data([1]))])
            .write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("archive.zip")))
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let listed = await store.listProjects()
        #expect(listed.first?.archived == true)   // listed (under Archive tab) without unpacking
        #expect(Archive.isArchivedOnDisk(dir))     // listing doesn't restore
    }
}
