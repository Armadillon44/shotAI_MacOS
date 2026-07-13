import Foundation

/// App settings the store needs: the projects root + the recents list. Mirrors
/// the Windows `settings.ts` surface (settings.json in userData) with native
/// storage; injectable so store tests run against an in-memory instance.
public protocol SettingsStore: Sendable {
    func projectsDir() -> String
    func setProjectsDir(_ dir: String)
    func recents() -> [String]
    func setRecents(_ paths: [String])
    /// Auto-archive a project untouched for this many days at launch. 0 = never.
    func archiveAgeDays() -> Int
    func setArchiveAgeDays(_ days: Int)
}

/// Default auto-archive age, matching the Windows app.
public let archiveAgeDefault = 90

/// Coerce an archive age: 0 = never (off); otherwise clamp to 1…1825 days.
public func clampArchiveAge(_ v: Int) -> Int {
    v <= 0 ? 0 : min(1825, max(1, v))
}

extension SettingsStore {
    /// Most-recently-touched-first, deduped, capped — same policy as the
    /// Windows `addRecent`.
    public func addRecent(_ path: String) {
        var list = recents().filter { $0 != path }
        list.insert(path, at: 0)
        setRecents(Array(list.prefix(10)))
    }
}

/// Same default as the Windows app: `~/shotAI Projects` — both apps pointed at
/// the same folder see the same projects.
public func defaultProjectsDir() -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent("shotAI Projects")
}

public final class UserDefaultsSettings: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let projectsDirKey = "projectsDir"
    private static let recentsKey = "recentProjects"
    private static let archiveAgeKey = "archiveAgeDays"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func projectsDir() -> String {
        defaults.string(forKey: Self.projectsDirKey) ?? defaultProjectsDir()
    }

    public func setProjectsDir(_ dir: String) {
        defaults.set(dir, forKey: Self.projectsDirKey)
    }

    public func recents() -> [String] {
        defaults.stringArray(forKey: Self.recentsKey) ?? []
    }

    public func setRecents(_ paths: [String]) {
        defaults.set(paths, forKey: Self.recentsKey)
    }

    public func archiveAgeDays() -> Int {
        // `object` (not `integer`) so "unset" → default, distinct from 0 = off.
        clampArchiveAge((defaults.object(forKey: Self.archiveAgeKey) as? Int) ?? archiveAgeDefault)
    }

    public func setArchiveAgeDays(_ days: Int) {
        defaults.set(clampArchiveAge(days), forKey: Self.archiveAgeKey)
    }
}

/// Test double (also handy for previews).
public final class InMemorySettings: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var dir: String
    private var recentsList: [String] = []
    private var archiveAge = archiveAgeDefault

    public init(projectsDir: String) {
        self.dir = projectsDir
    }

    public func projectsDir() -> String {
        lock.withLock { dir }
    }

    public func setProjectsDir(_ dir: String) {
        lock.withLock { self.dir = dir }
    }

    public func recents() -> [String] {
        lock.withLock { recentsList }
    }

    public func setRecents(_ paths: [String]) {
        lock.withLock { recentsList = paths }
    }

    public func archiveAgeDays() -> Int {
        lock.withLock { archiveAge }
    }

    public func setArchiveAgeDays(_ days: Int) {
        lock.withLock { archiveAge = clampArchiveAge(days) }
    }
}
