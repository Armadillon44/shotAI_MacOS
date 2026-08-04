import Foundation
import ShotModel

/// What a check concluded. Every case is a terminal, displayable state — the
/// checker never throws at its caller.
public enum UpdateCheckOutcome: Sendable, Equatable {
    /// The running build is the newest published release (or newer).
    case upToDate
    /// A newer release is out.
    case available(ReleaseInfo)
    /// A newer release is out, but the user chose to skip this one.
    case skipped(ReleaseInfo)
    /// Didn't ask GitHub: the cadence gate or a rate limit is still in effect.
    case throttled(until: Date?)
    /// Checking is off — by the user's preference or an MDM profile.
    case disabled(managed: Bool)
    /// Asked and failed. Not shown to the user as an error for `.automatic`.
    case failed(UpdateFeedError)

    /// The release to offer, if this outcome has one.
    public var availableRelease: ReleaseInfo? {
        if case .available(let r) = self { return r }
        return nil
    }
}

/// Backoff schedule. Values are deliberately coarse — this is a once-a-day
/// courtesy check, not a service dependency.
public enum UpdateBackoff {
    /// Cadence after a check that reached GitHub. "Once per day."
    public static let success: TimeInterval = 24 * 3600
    /// Offline / timeout / 5xx — transient, retry within the session.
    public static let transient: TimeInterval = 1 * 3600
    /// 404, a malformed body, a refused redirect — something structural.
    /// Retrying hourly would never fix it.
    public static let structural: TimeInterval = 6 * 3600
    /// Any gate further out than this is treated as corrupt and dropped, so a
    /// clock jump or a bad header can't wedge checking off forever.
    public static let ceiling: TimeInterval = 24 * 3600
}

/// Decides whether to ask GitHub, asks, and interprets the answer.
///
/// ## Actor reentrancy — read before editing `check`
/// Being an actor is NOT by itself enough to serialize this. Actors are
/// reentrant: while `check` is suspended on the network `await`, the executor is
/// free and any other method on this actor runs to completion. Two consequences
/// had to be handled explicitly, and both are easy to reintroduce:
///
/// 1. **No overlapping requests.** Two triggers (the launch check and a Settings
///    click) would otherwise each spend a request against a 60/hour budget that
///    is shared by every machine behind one office NAT. `inFlight` makes the
///    second caller await the first's result instead of starting a second fetch.
/// 2. **No stale write-back.** `check` must not hold a `UpdateCheckState` value
///    across the await and save it afterwards — `skip(tag:)` or `clearSkip()`
///    can persist in that window, and the write-back would silently erase them
///    (the user's "Skip This Version" would come back on the next launch). Every
///    persist goes through `mutate`, which re-reads immediately before writing.
public actor UpdateChecker {
    public enum Reason: Sendable, Equatable {
        /// The daily check. Respects the cadence gate.
        case automatic
        /// The user clicked Check Now. Skips the cadence gate, still honors a
        /// live rate limit.
        case manual
    }

    private let store: UpdateStateStore
    private let makeFeed: @Sendable (String) -> UpdateFeed
    /// The check currently talking to GitHub, so a second caller joins it rather
    /// than spending another request. See the reentrancy note above.
    private var inFlight: Task<UpdateCheckOutcome, Never>?

    public init(
        store: UpdateStateStore = UserDefaultsUpdateState(),
        makeFeed: @escaping @Sendable (String) -> UpdateFeed = { UpdateFeed(appVersion: $0) }
    ) {
        self.store = store
        self.makeFeed = makeFeed
    }

    public var state: UpdateCheckState { store.load() }
    public nonisolated var isManagedDisabled: Bool { store.isManagedDisabled }

    /// The ONLY way this type persists anything: re-read, mutate, write, with no
    /// suspension in between. A `UpdateCheckState` value held across an `await`
    /// must never be written back — `skip(tag:)` can land in that window, and the
    /// write-back would silently erase it.
    @discardableResult
    private func mutate(_ body: (inout UpdateCheckState) -> Void) -> UpdateCheckState {
        var s = store.load()
        body(&s)
        store.save(s)
        return s
    }

    /// Run a check.
    /// - enabled: the user's preference for the DAILY check. An explicit
    ///   "Check Now" passes `true` regardless (see `UpdateModel.checkNow`).
    /// - currentVersion: `CFBundleShortVersionString`. Unparseable → fail closed.
    /// - now: injected for tests.
    public func check(
        reason: Reason, enabled: Bool, currentVersion: String, now: Date = Date()
    ) async -> UpdateCheckOutcome {
        // Join a check already in flight rather than opening a second request.
        if let inFlight { return await inFlight.value }
        let task = Task<UpdateCheckOutcome, Never> { [self] in
            await perform(reason: reason, enabled: enabled, currentVersion: currentVersion, now: now)
        }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func perform(
        reason: Reason, enabled: Bool, currentVersion: String, now: Date
    ) async -> UpdateCheckOutcome {
        if store.isManagedDisabled {
            Log.updates.notice("check skipped — disabled by configuration profile")
            return .disabled(managed: true)
        }
        guard enabled else { return .disabled(managed: false) }

        let gated = mutate { $0.sanitize(now: now, maxBackoff: UpdateBackoff.ceiling) }

        // A live rate limit blocks both reasons; the cadence gate blocks only
        // the automatic one.
        if let limit = gated.rateLimitedUntil, limit > now {
            return .throttled(until: limit)
        }
        if reason == .automatic, let next = gated.nextAttemptNotBefore, next > now {
            return .throttled(until: next)
        }

        guard let running = SemanticVersion(currentVersion) else {
            // Fail closed. We can't tell newer from older, so offer nothing —
            // and don't burn a request finding out.
            Log.updates.error("running version is unparseable — no update will be offered")
            mutate { $0.nextAttemptNotBefore = now.addingTimeInterval(UpdateBackoff.structural) }
            return .upToDate
        }

        let feed = makeFeed(currentVersion)
        do {
            let release = try await feed.fetchLatest()
            let isNewer = release.version > running
            // Re-read: `skip()` may have persisted while we were suspended.
            let fresh = mutate {
                $0.lastSuccessfulCheck = now
                $0.nextAttemptNotBefore = now.addingTimeInterval(UpdateBackoff.success)
                $0.rateLimitedUntil = nil
                // Remember a newer release so the badge survives a relaunch
                // inside the cadence window, when no request runs at all.
                $0.latest = isNewer ? StoredRelease(release) : nil
            }

            guard isNewer else {
                Log.updates.notice("up to date (running \(running.description, privacy: .public), latest \(release.version.description, privacy: .public))")
                return .upToDate
            }
            if let skipped = fresh.skippedTag.flatMap(SemanticVersion.init), skipped >= release.version {
                Log.updates.notice("update \(release.version.description, privacy: .public) available but skipped by the user")
                return .skipped(release)
            }
            Log.updates.notice("update available: \(release.version.description, privacy: .public)")
            return .available(release)
        } catch let error as UpdateFeedError {
            mutate { apply(error, to: &$0, now: now) }
            Log.updates.notice("check failed (\(String(describing: error), privacy: .public))")
            return .failed(error)
        } catch {
            mutate { $0.nextAttemptNotBefore = now.addingTimeInterval(UpdateBackoff.transient) }
            return .failed(.connection)
        }
    }

    /// The newer release remembered from the last successful check, unless the
    /// user has since skipped it. Without this the badge would appear only on the
    /// one launch that happened to make a request, and vanish for the next 24 h.
    public func rememberedRelease() -> ReleaseInfo? {
        let s = store.load()
        guard let release = s.latest?.release() else { return nil }
        if let skipped = s.skippedTag.flatMap(SemanticVersion.init), skipped >= release.version {
            return nil
        }
        return release
    }

    /// Suppress notifications for `tag` and anything older.
    public func skip(tag: String) {
        mutate { $0.skippedTag = tag }
        Log.updates.notice("user skipped \(tag, privacy: .public)")
    }

    /// Clear the skip so the pending version is offered again.
    public func clearSkip() {
        mutate { $0.skippedTag = nil }
    }

    /// Test/support hook: forget the cadence so the next automatic check runs.
    public func resetCadence() {
        mutate { $0.nextAttemptNotBefore = nil }
    }

    private func apply(_ error: UpdateFeedError, to state: inout UpdateCheckState, now: Date) {
        switch error {
        case .rateLimited(let resetAt):
            // Honor the server's reset EXACTLY when it's a sane future time —
            // GitHub knows when the bucket refills, and rounding it up to our own
            // floor would block a manual Check Now for no reason. A missing, past,
            // or absurd header falls back to our schedule instead.
            let until: Date
            if let resetAt, resetAt > now {
                until = min(resetAt, now.addingTimeInterval(UpdateBackoff.ceiling))
            } else {
                until = now.addingTimeInterval(UpdateBackoff.transient)
            }
            state.rateLimitedUntil = until
            state.nextAttemptNotBefore = until
        case .connection:
            state.nextAttemptNotBefore = now.addingTimeInterval(UpdateBackoff.transient)
        case .http(let status):
            let wait = (500...599).contains(status) ? UpdateBackoff.transient : UpdateBackoff.structural
            state.nextAttemptNotBefore = now.addingTimeInterval(wait)
        case .malformedResponse, .unexpectedRedirect:
            state.nextAttemptNotBefore = now.addingTimeInterval(UpdateBackoff.structural)
        }
    }
}
