import Foundation

/// Everything the checker remembers between launches.
///
/// Persisted to disk (UserDefaults), never just held in memory: GitHub's
/// unauthenticated limit is 60 requests/hour **per originating IP**, so every LFI
/// Mac behind one office NAT shares a single bucket. An in-memory throttle would
/// reset on every relaunch and the whole office could exhaust it between them.
public struct UpdateCheckState: Codable, Equatable, Sendable {
    /// Last check that actually reached GitHub — shown as "Last checked …".
    public var lastSuccessfulCheck: Date?
    /// Routine cadence gate. Automatic checks wait for this; a manual
    /// "Check Now" ignores it (the user is asking on purpose).
    public var nextAttemptNotBefore: Date?
    /// Hard gate from a 403/429. Honored by manual checks too — once GitHub has
    /// said "stop", clicking a button harder must not keep hitting it.
    public var rateLimitedUntil: Date?
    /// The newer release found by the last successful check, or nil when that
    /// check found nothing newer. Persisted so the Home badge survives a
    /// relaunch: inside the 24 h cadence window no request runs, so without this
    /// the notice would appear on exactly one launch and then disappear for a day.
    public var latest: StoredRelease?
    /// Tag the user chose to skip. Suppresses that version and anything older;
    /// a genuinely newer release still notifies.
    public var skippedTag: String?

    public init() {}

    /// Tolerant decode: an unknown or partial blob degrades to defaults rather
    /// than discarding the whole state (same posture as `AppPreferences`).
    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        lastSuccessfulCheck = try? c.decodeIfPresent(Date.self, forKey: .lastSuccessfulCheck)
        nextAttemptNotBefore = try? c.decodeIfPresent(Date.self, forKey: .nextAttemptNotBefore)
        rateLimitedUntil = try? c.decodeIfPresent(Date.self, forKey: .rateLimitedUntil)
        latest = try? c.decodeIfPresent(StoredRelease.self, forKey: .latest)
        skippedTag = try? c.decodeIfPresent(String.self, forKey: .skippedTag)
    }

    /// Guard against a clock that jumped forward and then back, or a hand-edited
    /// plist: a gate implausibly far in the future is treated as bogus and
    /// dropped, so the checker can't be wedged off permanently.
    ///
    /// The `slack` matters. A gate written as `checkTime + 24h` and a ceiling of
    /// `now + 24h` compare as `checkTime > now` — meaning ANY backward clock
    /// adjustment, including a routine one-second NTP correction, would discard a
    /// perfectly good cadence gate and let the next launch re-check. The slack
    /// absorbs ordinary clock drift while still catching a genuinely absurd value.
    mutating func sanitize(now: Date, maxBackoff: TimeInterval, slack: TimeInterval = 3600) {
        let ceiling = now.addingTimeInterval(maxBackoff + slack)
        if let d = nextAttemptNotBefore, d > ceiling { nextAttemptNotBefore = nil }
        if let d = rateLimitedUntil, d > ceiling { rateLimitedUntil = nil }
        if let d = lastSuccessfulCheck, d > now { lastSuccessfulCheck = now }
    }
}

/// A `ReleaseInfo` reduced to what survives a relaunch. Kept separate from
/// `ReleaseInfo` so the persisted shape is explicit and independently tolerant:
/// a blob written by a future version decodes to nil rather than failing the
/// whole state (`URL` and the version string are both re-validated on read, so a
/// hand-edited plist can't smuggle in a non-GitHub link).
public struct StoredRelease: Codable, Equatable, Sendable {
    public var tag: String
    public var name: String
    public var notes: String
    public var page: String
    public var assetName: String?
    public var assetSize: Int?

    public init(_ r: ReleaseInfo) {
        tag = r.tag
        name = r.name
        notes = r.notes
        page = r.releasePage.absoluteString
        assetName = r.assetName
        assetSize = r.assetSize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        page = try c.decode(String.self, forKey: .page)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? tag
        notes = (try? c.decodeIfPresent(String.self, forKey: .notes)) ?? ""
        assetName = try? c.decodeIfPresent(String.self, forKey: .assetName)
        assetSize = try? c.decodeIfPresent(Int.self, forKey: .assetSize)
    }

    /// Rebuild a `ReleaseInfo`, re-running the same validation the feed applies.
    /// nil if the stored blob no longer passes — a stored value is not trusted
    /// any more than a fresh network response.
    public func release() -> ReleaseInfo? {
        guard let version = SemanticVersion(tag),
              let url = URL(string: page),
              UpdateFeed.isAcceptableReleasePage(url)
        else { return nil }
        return ReleaseInfo(
            tag: tag, version: version, name: name, notes: notes,
            releasePage: url, publishedAt: nil,
            assetName: assetName, assetSize: assetSize)
    }
}

/// Persistence seam so the checker is testable without touching UserDefaults.
public protocol UpdateStateStore: Sendable {
    func load() -> UpdateCheckState
    func save(_ state: UpdateCheckState)
    /// True when an MDM configuration profile has force-disabled update checks.
    /// IT can kill the feature fleet-wide without touching the app.
    var isManagedDisabled: Bool { get }
}

/// The shipping store: one JSON blob in `UserDefaults`, same shape as
/// `SopSettings` / `AppPreferences`.
public final class UserDefaultsUpdateState: UpdateStateStore, @unchecked Sendable {
    /// Key IT sets in a configuration profile to disable checks fleet-wide.
    public static let managedDisableKey = "updateCheckDisabled"
    private static let stateKey = "updateCheckState.v1"

    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> UpdateCheckState {
        guard let data = defaults.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(UpdateCheckState.self, from: data)
        else { return UpdateCheckState() }
        return state
    }

    public func save(_ state: UpdateCheckState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }

    /// `objectIsForced` is true only for a value delivered by a managed
    /// (MDM/profile) domain — a user writing the same key with `defaults write`
    /// can't switch this on.
    public var isManagedDisabled: Bool {
        defaults.objectIsForced(forKey: Self.managedDisableKey)
            && defaults.bool(forKey: Self.managedDisableKey)
    }
}

/// Test double.
public final class InMemoryUpdateState: UpdateStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: UpdateCheckState
    private let managed: Bool

    public init(_ initial: UpdateCheckState = UpdateCheckState(), managedDisabled: Bool = false) {
        self.state = initial
        self.managed = managedDisabled
    }

    public func load() -> UpdateCheckState { lock.withLock { state } }
    public func save(_ s: UpdateCheckState) { lock.withLock { state = s } }
    public var isManagedDisabled: Bool { managed }
}
