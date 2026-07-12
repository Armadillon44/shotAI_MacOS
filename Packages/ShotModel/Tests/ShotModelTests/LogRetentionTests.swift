import Foundation
import Testing
@testable import ShotModel

/// Retention/rotation for the exported-log folder (`Log.pruneLogExports`). The
/// concern: "Export shotAI Logs…" writes a new timestamped file every time and
/// nothing used to remove old ones, so the folder could grow without bound.
@Suite struct LogRetentionTests {

    /// Make a temp dir, auto-removed by the caller.
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shotai-logtest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write `sizeBytes` of content to a `shotai-<name>.log` file and stamp its
    /// modification date so ordering is deterministic.
    @discardableResult
    private func makeLog(_ dir: URL, name: String, sizeBytes: Int, ageSeconds: Double) throws -> URL {
        let url = dir.appendingPathComponent("shotai-\(name).log")
        try String(repeating: "x", count: sizeBytes).write(to: url, atomically: true, encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_700_000_000 - ageSeconds)  // older = larger age
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    private func remaining(_ dir: URL) -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(items)
    }

    @Test func keepsNewestUpToFileCap() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Five files, oldest → newest by decreasing age.
        for (i, age) in [500.0, 400, 300, 200, 100].enumerated() {
            try makeLog(dir, name: "f\(i)", sizeBytes: 10, ageSeconds: age)
        }
        let removed = Log.pruneLogExports(in: dir, maxFiles: 3, maxBytes: 1_000_000)
        #expect(removed == 2)
        // The three newest (smallest age): f2, f3, f4.
        #expect(remaining(dir) == ["shotai-f2.log", "shotai-f3.log", "shotai-f4.log"])
    }

    @Test func enforcesTotalSizeCap() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 4 files × 10 bytes, newest → oldest. Cap = 25 bytes: newest (10) + next
        // (→20) fit; adding the third (→30) exceeds 25 → stop. Keep 2, remove 2.
        for (i, age) in [400.0, 300, 200, 100].enumerated() {
            try makeLog(dir, name: "f\(i)", sizeBytes: 10, ageSeconds: age)
        }
        let removed = Log.pruneLogExports(in: dir, maxFiles: 100, maxBytes: 25)
        #expect(removed == 2)
        #expect(remaining(dir) == ["shotai-f2.log", "shotai-f3.log"])
    }

    @Test func alwaysKeepsTheNewestEvenIfItAloneExceedsTheSizeCap() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeLog(dir, name: "solo", sizeBytes: 500, ageSeconds: 100)
        let removed = Log.pruneLogExports(in: dir, maxFiles: 10, maxBytes: 10)
        #expect(removed == 0)  // never delete the file we just wrote
        #expect(remaining(dir) == ["shotai-solo.log"])
    }

    @Test func leavesNonExportFilesAlone() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeLog(dir, name: "a", sizeBytes: 10, ageSeconds: 200)
        try makeLog(dir, name: "b", sizeBytes: 10, ageSeconds: 100)
        // A foreign file that must not be touched by pruning.
        let other = dir.appendingPathComponent("notes.txt")
        try "keep me".write(to: other, atomically: true, encoding: .utf8)
        _ = Log.pruneLogExports(in: dir, maxFiles: 1, maxBytes: 1_000_000)
        let left = remaining(dir)
        #expect(left.contains("notes.txt"))
        #expect(left.contains("shotai-b.log"))     // newest kept
        #expect(!left.contains("shotai-a.log"))     // oldest pruned
    }
}
