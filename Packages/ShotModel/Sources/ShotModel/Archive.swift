import Foundation

/// Project archiving (F2) — the macOS port of the Windows `archive.ts`. A live
/// project is a folder with project.json + shots/ + export/. Archiving zips the
/// BULK dirs (shots/, export/) into `archive.zip` at the project root and removes
/// the loose copies; project.json stays put so the project keeps listing
/// (title/dates/step-count) without a full extract. Opening an archived project
/// restores it first (see `ProjectStore.openProject`).
///
/// DATA SAFETY (fail-closed): extraction verifies every entry landed BEFORE the
/// zip is removed; any failure throws and leaves the project's files intact.
///
/// This phase implements the READ side (unpack) only — the existing `Zip` reader
/// already decodes Windows' DEFLATE `archive.zip`, so restoring a Windows-archived
/// project needs no writer. Packing (write side) lands in the next phase.
enum Archive {
    static let archiveZipName = "archive.zip"
    /// Top-level dirs compressed on archive; project.json is never touched.
    static let archivedDirs = ["shots", "export"]
    /// Restore guards (defense-in-depth against a corrupt/tampered zip). This is
    /// the user's own data, so the caps are generous but bounded.
    static let maxEntryBytes = 256 * 1024 * 1024
    static let maxTotalBytes = 2 * 1024 * 1024 * 1024

    /// True if the project folder is archived on disk (archive.zip present).
    static func isArchivedOnDisk(_ projectDir: String) -> Bool {
        FileManager.default.fileExists(
            atPath: (projectDir as NSString).appendingPathComponent(archiveZipName))
    }

    /// Restore a project's files from archive.zip and remove the zip. No-op if not
    /// archived. Fail-closed: each entry is whitelisted to shots/ + export/, path
    /// confined (zip-slip + symlink-rejecting), and verified present BEFORE the
    /// compressed copy is deleted. Overwrites on extract so a half-restored folder
    /// (crash between extract and zip-removal) self-heals on the next open.
    static func unpackArchive(_ projectDir: String) throws {
        guard isArchivedOnDisk(projectDir) else { return }
        let zipPath = (projectDir as NSString).appendingPathComponent(archiveZipName)
        let data = try coordinatedRead(URL(fileURLWithPath: zipPath))
        let items = try zipList(data)

        var total = 0
        var written: [String] = []
        for it in items {
            let rel = it.name.replacingOccurrences(of: "\\", with: "/")
            // Only restore into the dirs we archive — reject anything else (a
            // tampered zip). NOT isImportableImagePath: that's too narrow and would
            // reject legitimate export/ files (report.html, etc.).
            let allowed = archivedDirs.contains { rel == $0 || rel.hasPrefix("\($0)/") }
            guard allowed else { throw ArchiveError.unexpectedEntry(rel) }
            guard it.uncompressedSize <= maxEntryBytes else { throw ArchiveError.entryTooLarge(rel) }
            total += it.uncompressedSize
            guard total <= maxTotalBytes else { throw ArchiveError.tooLarge }
            guard let abs = confinePathNoSymlinks(dir: projectDir, rel: rel) else {
                Log.store.error("SECURITY archive extract refused (not confined) rel=[\(rel, privacy: .private)]")
                throw ArchiveError.pathNotConfined(rel)
            }
            let bytes = try zipExtract(data, it)
            try FileManager.default.createDirectory(
                atPath: (abs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try bytes.write(to: URL(fileURLWithPath: abs))  // overwrite (crash-recovery)
            written.append(abs)
        }

        // Verify every extracted file exists before removing the compressed copy.
        for abs in written where !FileManager.default.fileExists(atPath: abs) {
            throw ArchiveError.verifyFailed
        }
        try FileManager.default.removeItem(atPath: zipPath)
        Log.store.info("archive: restored \(written.count, privacy: .public) file(s)")
    }

    /// A coordinated read — materializes a cloud placeholder (OneDrive/iCloud) on
    /// demand and gives a consistent snapshot. Aborts (throws) if the file can't
    /// be read, so we never proceed on a hollow placeholder.
    static func coordinatedRead(_ url: URL) throws -> Data {
        var coordErr: NSError?
        var readErr: Error?
        var out: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordErr) { u in
            do { out = try Data(contentsOf: u) } catch { readErr = error }
        }
        if let coordErr { throw coordErr }
        if let readErr { throw readErr }
        guard let out else { throw ArchiveError.unreadable(url.lastPathComponent) }
        return out
    }
}

public enum ArchiveError: Error, LocalizedError, Equatable {
    case unexpectedEntry(String)
    case entryTooLarge(String)
    case tooLarge
    case pathNotConfined(String)
    case verifyFailed
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedEntry(let n): "The archive contains an unexpected file: \(n)"
        case .entryTooLarge(let n): "A file in the archive is too large to restore: \(n)"
        case .tooLarge: "The archive is too large to restore."
        case .pathNotConfined(let n): "Refusing to restore a file outside the project: \(n)"
        case .verifyFailed: "The archive could not be fully restored; the compressed copy was kept."
        case .unreadable(let n): "Could not read \(n) (it may be a cloud file that hasn't downloaded)."
        }
    }
}
