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

    // A `..` traversal that a lexical prefix check would accept (export/../ still
    // "hasPrefix export/") must be rejected — else auto-unarchive could overwrite
    // project.json at the project root.
    @Test func unpackRejectsDotDotTraversalEntry() throws {
        let (root, dir) = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        try zipStored([("export/../pwned.txt", Data("x".utf8))])
            .write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("archive.zip")))
        #expect(throws: ArchiveError.self) { try Archive.unpackArchive(dir) }
        #expect(!FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("pwned.txt")))
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

    // MARK: - Phase 2 (writer + pack)

    @Test func zipArchiveHybridCompressesTextButStoresImages() throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47] + (0..<200).map { UInt8(truncatingIfNeeded: $0 &* 37) })  // "incompressible-ish"
        let html = Data(String(repeating: "<p>hello world</p>", count: 500).utf8)      // very compressible
        let zip = try zipArchive([("shots/a.png", png), ("export/r.html", html)]) { $0.hasPrefix("export/") }
        let items = try zipList(zip)
        let shot = items.first { $0.name == "shots/a.png" }!
        let doc = items.first { $0.name == "export/r.html" }!
        #expect(shot.method == 0)                 // STORED (image)
        #expect(doc.method == 8)                  // DEFLATE (text)
        #expect(doc.compressedRange.count < html.count)  // actually smaller
        // Both round-trip to identical bytes.
        #expect(try zipExtract(zip, shot) == png)
        #expect(try zipExtract(zip, doc) == html)
    }

    @Test func archiveProjectPacksRestoresAndPreservesUpdatedAt() async throws {
        let (root, dir) = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        // A live project: manifest + shots/ + export/ with real files.
        let m = ProjectManifest(id: "p", title: "T", createdAt: "2026-01-01T00:00:00Z",
                                updatedAt: "2026-05-05T00:00:00Z")
        try ProjectJSON.encodeManifest(m).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("project.json")))
        let png = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4, 5])
        let html = Data(String(repeating: "step ", count: 300).utf8)
        try FileManager.default.createDirectory(atPath: (dir as NSString).appendingPathComponent("shots"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (dir as NSString).appendingPathComponent("export"), withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("shots/step-0001.png")))
        try html.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("export/report.html")))

        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let summary = try await store.archiveProject(at: dir)

        #expect(summary.archived == true)
        #expect(Archive.isArchivedOnDisk(dir))                                             // archive.zip present
        #expect(!FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("shots")))  // loose gone
        #expect(!FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("export")))
        // Manifest flag flipped, updatedAt untouched.
        let onDisk = try ProjectJSON.decodeManifest(try Data(contentsOf: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("project.json"))))
        #expect(onDisk.archived == true)
        #expect(onDisk.updatedAt == "2026-05-05T00:00:00Z")

        // Open restores byte-identical files + clears the flag (no updatedAt bump).
        let opened = try await store.openProject(at: dir)
        #expect(opened.manifest.archived == false)
        #expect(opened.manifest.updatedAt == "2026-05-05T00:00:00Z")
        #expect(try Data(contentsOf: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("shots/step-0001.png"))) == png)
        #expect(try Data(contentsOf: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("export/report.html"))) == html)
    }

    @Test func archiveProjectIsIdempotent() async throws {
        let (root, dir) = try tempDir(); defer { try? FileManager.default.removeItem(atPath: root) }
        let m = ProjectManifest(id: "p", title: "T", createdAt: "", updatedAt: "2026-05-05T00:00:00Z")
        try ProjectJSON.encodeManifest(m).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("project.json")))
        try FileManager.default.createDirectory(atPath: (dir as NSString).appendingPathComponent("shots"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("shots/a.png")))
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        _ = try await store.archiveProject(at: dir)
        let again = try await store.archiveProject(at: dir)  // no-op, no throw
        #expect(again.archived == true)
        #expect(Archive.isArchivedOnDisk(dir))
    }

    // MARK: - Phase 3 (auto-archive)

    @Test func clampArchiveAgeBounds() {
        #expect(clampArchiveAge(0) == 0)      // never (off)
        #expect(clampArchiveAge(-5) == 0)
        #expect(clampArchiveAge(1) == 1)
        #expect(clampArchiveAge(45) == 45)
        #expect(clampArchiveAge(9999) == 1825)
    }

    @Test func autoArchiveStaleArchivesOnlyOldLiveProjects() async throws {
        let root = NSTemporaryDirectory() + "shotai-sweep-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        func makeProj(_ id: String, updatedAt: String, archived: Bool = false) throws {
            let dir = (root as NSString).appendingPathComponent(id)
            try FileManager.default.createDirectory(atPath: (dir as NSString).appendingPathComponent("shots"), withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("shots/a.png")))
            let m = ProjectManifest(id: id, title: id, createdAt: "2020-01-01T00:00:00Z",
                                    updatedAt: updatedAt, archived: archived)
            try ProjectJSON.encodeManifest(m).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("project.json")))
            if archived {  // an already-archived project also has a zip on disk
                try zipStored([("shots/a.png", Data([1]))]).write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("archive.zip")))
            }
        }
        try makeProj("old", updatedAt: "2020-01-01T00:00:00Z")                                  // stale → archive
        try makeProj("recent", updatedAt: ISO8601DateFormatter().string(from: Date()))          // fresh → keep
        try makeProj("done", updatedAt: "2020-01-01T00:00:00Z", archived: true)                 // already archived → skip

        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let n = await store.autoArchiveStale(ageDays: 30)
        #expect(n == 1)  // only "old"
        #expect(Archive.isArchivedOnDisk((root as NSString).appendingPathComponent("old")))
        #expect(!Archive.isArchivedOnDisk((root as NSString).appendingPathComponent("recent")))
        // ageDays 0 disables the sweep entirely.
        let none = await store.autoArchiveStale(ageDays: 0)
        #expect(none == 0)
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
