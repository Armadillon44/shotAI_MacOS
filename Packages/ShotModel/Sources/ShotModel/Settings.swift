import Foundation

/// App settings the store needs: the projects root + the recents list. Mirrors
/// the Windows `settings.ts` surface (settings.json in userData) with native
/// storage; injectable so store tests run against an in-memory instance.
public protocol SettingsStore: Sendable {
    func projectsDir() -> String
    func setProjectsDir(_ dir: String)
    func recents() -> [String]
    func setRecents(_ paths: [String])
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
}

/// Test double (also handy for previews).
public final class InMemorySettings: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var dir: String
    private var recentsList: [String] = []

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
}
