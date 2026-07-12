import Foundation
import OSLog

/// Centralized operational + error logging for shotAI.
///
/// Native unified logging (`os.Logger`) under one subsystem, split into
/// per-area categories — viewable live in Console.app / `log stream
/// --predicate 'subsystem == "com.armadillon44.shotai"'`, persisted in the
/// system log store, and exportable to a text file the user can send for
/// troubleshooting (the parity intent of the Windows app's `logger.ts`). Lives
/// in ShotModel so every module (and the app) can reach it — CaptureKit /
/// EditorKit / the app target all depend on ShotModel.
///
/// ## Privacy — READ BEFORE ADDING LOGS
/// `os.Logger` string interpolations are **private by default** (rendered as
/// `<private>` in other readers' captures). Keep it that way for anything
/// user-derived. Mark ONLY non-sensitive metadata `.public`:
/// - Public OK: counts, indices, enum/case names, booleans, durations, step
///   *ids* (opaque UUIDs), image dimensions, error *type* names.
/// - MUST stay private (never `.public`): project titles, file paths, captions
///   / instructions / notes, window & element text, OCR text, redaction
///   content, and above all the Anthropic **API key**.
///
/// When in doubt, leave it private — the export flow below still reveals private
/// values in the *user's own* exported file (it's their machine, their data), so
/// troubleshooting doesn't lose information.
public enum Log {
    public static let subsystem = "com.armadillon44.shotai"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let editor = Logger(subsystem: subsystem, category: "editor")
    public static let ocr = Logger(subsystem: subsystem, category: "ocr")
    public static let sop = Logger(subsystem: subsystem, category: "sop")
    public static let export = Logger(subsystem: subsystem, category: "export")
    public static let permissions = Logger(subsystem: subsystem, category: "permissions")

    private nonisolated(unsafe) static var didBootstrap = false

    /// Emit a startup banner and install an uncaught-exception handler. Call once
    /// as early as possible at launch (main thread).
    public static func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        app.notice("shotAI starting — v\(version, privacy: .public) (\(build, privacy: .public)) · \(arch, privacy: .public) · \(os, privacy: .public)")

        NSSetUncaughtExceptionHandler { exception in
            Log.app.critical("Uncaught exception: \(exception.name.rawValue, privacy: .public) — \(exception.reason ?? "", privacy: .public)")
        }
    }

    // MARK: Export-log retention
    //
    // Runtime logging itself goes to the OS unified log store, which macOS caps
    // and rotates on its own — the app can't make *that* grow without bound. The
    // only unbounded disk vector shotAI owns is the export folder below, where
    // every "Export shotAI Logs…" drops a fresh timestamped file. We prune it
    // after each export so it can never accumulate indefinitely.

    /// Keep at most this many exported log files.
    public static let maxExportFiles = 10
    /// Keep the exported-log folder under this combined size (bytes). 50 MB.
    public static let maxExportBytes = 50 * 1024 * 1024
    /// Prefix used for every exported log file (also the prune match pattern).
    private static let exportPrefix = "shotai-"

    /// The directory exported logs live in (`~/Library/Logs/shotAI/`).
    static func exportLogDir() throws -> URL {
        try FileManager.default
            .url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Logs/shotAI", isDirectory: true)
    }

    /// Export this app's recent log entries to a text file for troubleshooting,
    /// returning the file URL (under ~/Library/Logs/shotAI/). Includes private
    /// field values — it's the user's own machine, so the export is genuinely
    /// useful when they choose to send it. Old exports are pruned afterward so
    /// the folder stays bounded (see `pruneLogExports`).
    public static func exportRecentLog(hours: Double = 24) throws -> URL {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let start = store.position(date: Date().addingTimeInterval(-hours * 3600))
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        let entries = try store.getEntries(at: start, matching: predicate)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var text = "shotAI log export — \(iso.string(from: Date()))\n"
        text += "(last \(Int(hours))h · subsystem \(subsystem))\n\n"
        var count = 0
        for case let entry as OSLogEntryLog in entries {
            text += "[\(iso.string(from: entry.date))] [\(levelName(entry.level))] [\(entry.category)] \(entry.composedMessage)\n"
            count += 1
        }

        let dir = try exportLogDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = iso.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = dir.appendingPathComponent("\(exportPrefix)\(stamp).log")
        try text.write(to: file, atomically: true, encoding: .utf8)
        app.notice("Exported \(count, privacy: .public) log entries to a file")
        pruneLogExports(in: dir)  // keep the folder bounded
        return file
    }

    /// Delete the oldest exported log files in `dir` until at most `maxFiles`
    /// remain AND their combined size is ≤ `maxBytes`. Files are ranked by
    /// modification date (newest kept). The single newest file is always kept —
    /// it's the one just written and about to be revealed — even if it alone
    /// exceeds `maxBytes`. Best-effort: a file that can't be removed is skipped,
    /// never fatal to the export.
    @discardableResult
    static func pruneLogExports(in dir: URL,
                                maxFiles: Int = maxExportFiles,
                                maxBytes: Int = maxExportBytes) -> Int {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }

        // Only our own export files, newest first.
        let logs = items
            .filter { $0.lastPathComponent.hasPrefix(exportPrefix) && $0.pathExtension == "log" }
            .map { url -> (url: URL, date: Date, size: Int) in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return (url, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }

        // Find how many of the newest files fit under both caps, then delete the rest.
        var keep = 0
        var bytes = 0
        for (i, item) in logs.enumerated() {
            if i == 0 || (keep < maxFiles && bytes + item.size <= maxBytes) {
                keep += 1
                bytes += item.size
            } else {
                break  // sorted newest-first: everything from here on is older → prune
            }
        }
        var removed = 0
        for item in logs.dropFirst(keep) where (try? fm.removeItem(at: item.url)) != nil {
            removed += 1
        }
        if removed > 0 { app.notice("Pruned \(removed, privacy: .public) old log export(s)") }
        return removed
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        case .undefined: "?"
        @unknown default: "?"
        }
    }
}
