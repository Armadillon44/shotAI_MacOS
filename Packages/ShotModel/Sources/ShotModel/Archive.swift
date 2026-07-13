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

    /// Compress the project's bulk dirs into archive.zip and remove the loose
    /// copies. No-op if already archived, or if there are no bulk files to pack
    /// (an empty project stays live). Fail-closed: the archive is written to a tmp
    /// path and VERIFIED (every entry's name + uncompressed size + CRC re-read from
    /// the zip) BEFORE it replaces archive.zip, and the loose originals are removed
    /// only AFTER the verified archive is in place. Source files are read via a
    /// coordinated read so a cloud placeholder is materialized (and a truly
    /// unreadable file aborts the whole archive — never zips a hollow file).
    /// Does NOT touch the manifest — the caller flips `archived`.
    static func packArchive(_ projectDir: String) throws {
        guard !isArchivedOnDisk(projectDir) else { return }

        // 1. Gather every file under shots/ + export/ (POSIX rel paths).
        var entries: [(name: String, data: Data)] = []
        for d in archivedDirs {
            let base = (projectDir as NSString).appendingPathComponent(d)
            for rel in walkFiles(dirName: d, dir: base) {
                guard let abs = confinePathNoSymlinks(dir: projectDir, rel: rel) else {
                    throw ArchiveError.pathNotConfined(rel)
                }
                entries.append((rel, try coordinatedRead(URL(fileURLWithPath: abs))))
            }
        }
        guard !entries.isEmpty else { return }  // nothing to archive — leave live

        // 2. Build the archive: DEFLATE text under export/, STORED already-compressed shots.
        let zip = try zipArchive(entries) { $0.hasPrefix("export/") }

        // 3. Write to a tmp file and verify it re-reads with the exact entry set
        //    (name + uncompressed size + CRC) before anything is deleted.
        guard let zipPath = confinePathNoSymlinks(dir: projectDir, rel: archiveZipName),
              let tmpPath = confinePathNoSymlinks(dir: projectDir, rel: archiveZipName + ".tmp") else {
            throw ArchiveError.pathNotConfined(archiveZipName)
        }
        try writeFileAtomic(zip, to: tmpPath)
        do {
            let listed = try zipList(try Data(contentsOf: URL(fileURLWithPath: tmpPath)))
            var want: [String: (size: Int, crc: UInt32)] = [:]
            for (name, data) in entries { want[name] = (data.count, crc32(data)) }
            guard listed.count == entries.count else { throw ArchiveError.verifyFailed }
            for it in listed {
                guard let w = want[it.name], it.uncompressedSize == w.size, it.crc == w.crc else {
                    throw ArchiveError.verifyFailed
                }
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tmpPath)
            throw error
        }

        // 4. Place the verified archive, THEN (only now) remove the loose originals.
        try FileManager.default.moveItem(atPath: tmpPath, toPath: zipPath)
        for d in archivedDirs {
            try? FileManager.default.removeItem(atPath: (projectDir as NSString).appendingPathComponent(d))
        }
        Log.store.info("archive: packed \(entries.count, privacy: .public) file(s)")
    }

    /// Files under `dir` (recursively), as POSIX rel paths from the project
    /// (`dirName/…`). Missing dir → empty. Files only (directories skipped).
    private static func walkFiles(dirName: String, dir: String) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
              let en = fm.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        while let e = en.nextObject() as? String {
            let abs = (dir as NSString).appendingPathComponent(e)
            var sub: ObjCBool = false
            if fm.fileExists(atPath: abs, isDirectory: &sub), !sub.boolValue {
                out.append("\(dirName)/\(e.replacingOccurrences(of: "\\", with: "/"))")
            }
        }
        return out
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
