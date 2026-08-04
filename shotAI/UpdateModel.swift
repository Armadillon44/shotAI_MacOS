import AppKit
import Foundation
import Observation
import ShotModel
import SwiftUI
import UpdateKit

/// UI-facing state for the update notifier (#62 Phase 1).
///
/// NOTIFY ONLY. This never downloads anything and never touches the app bundle —
/// "Download" opens the release page in the user's browser, so the DMG arrives
/// through Safari with a normal Gatekeeper quarantine flag. A URLSession fetch
/// would arrive *unquarantined* (we're non-sandboxed and set no
/// `LSFileQuarantineEnabled`), silently skipping that wall on a build that isn't
/// notarized yet. Self-installing updates stay blocked until Developer ID
/// signing lands — see issue #62 for why.
@MainActor
@Observable
final class UpdateModel {
    /// A newer release the user hasn't skipped. Drives the Home badge.
    private(set) var pending: ReleaseInfo?
    /// Result of the most recent check, for the Settings status line.
    private(set) var lastOutcome: UpdateCheckOutcome?
    private(set) var checking = false
    private(set) var lastChecked: Date?
    private(set) var skippedTag: String?
    /// Hidden until the next launch (the ✕ on the badge). Not persisted — a
    /// dismiss is "not now", a skip is "not this version".
    var badgeDismissed = false

    /// True when an MDM configuration profile force-disables checking. The
    /// Settings toggle is hidden and replaced with an explanation.
    let isManagedDisabled: Bool

    @ObservationIgnored private let checker: UpdateChecker
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private var didRunLaunchCheck = false

    init(checker: UpdateChecker = UpdateChecker(), currentVersion: String? = nil) {
        self.checker = checker
        self.currentVersion = currentVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? ""
        self.isManagedDisabled = checker.isManagedDisabled
    }

    /// Restore what the last check learned, without making a request.
    ///
    /// This is what makes the notice persistent. A successful check sets a 24 h
    /// cadence gate, so the next few launches make no request at all — if
    /// `pending` were only ever set by a live check, the badge would appear on
    /// exactly one launch and then vanish for a day.
    func loadPersistedState(enabled: Bool = true) async {
        let s = await checker.state
        lastChecked = s.lastSuccessfulCheck
        skippedTag = s.skippedTag
        guard enabled, !isManagedDisabled else { return }
        if pending == nil, let remembered = await checker.rememberedRelease() {
            pending = remembered
        }
    }

    /// The badge to show on Home, or nil.
    var badgeRelease: ReleaseInfo? { badgeDismissed ? nil : pending }

    /// The daily check, fired a few seconds after launch. Silent about failures:
    /// nobody asked, so an offline laptop must not produce UI.
    ///
    /// Skipped entirely while recording or exporting. A skip leaves the throttle
    /// untouched, so the next launch checks normally.
    func checkAtLaunch(enabled: Bool, busy: Bool) async {
        guard !didRunLaunchCheck else { return }
        guard !busy else {
            Log.updates.notice("launch check skipped — app is busy (recording or exporting)")
            return
        }
        didRunLaunchCheck = true
        await run(reason: .automatic, enabled: enabled)
    }

    /// "Check for Updates…" / the Settings button. Reports its result either way.
    ///
    /// Deliberately passes `enabled: true`. The preference is labelled "check for
    /// updates *automatically*" and governs the daily background check; someone
    /// who turned that off and then explicitly asked should still get an answer.
    /// Only the MDM profile can refuse a manual check, and that's enforced inside
    /// the checker.
    func checkNow() async {
        await run(reason: .manual, enabled: true)
    }

    private func run(reason: UpdateChecker.Reason, enabled: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        let outcome = await checker.check(
            reason: reason, enabled: enabled, currentVersion: currentVersion)
        lastOutcome = outcome
        let state = await checker.state
        lastChecked = state.lastSuccessfulCheck
        skippedTag = state.skippedTag

        switch outcome {
        case .available(let release):
            // A different version than the one dismissed earlier deserves to be
            // seen again.
            if pending?.tag != release.tag { badgeDismissed = false }
            pending = release
        case .upToDate, .disabled, .skipped:
            pending = nil
        case .throttled, .failed:
            break   // leave any existing badge alone
        }
    }

    /// Automatic checks were switched off: retire the notice, since a badge left
    /// behind would contradict the setting the user just changed.
    func automaticChecksDisabled() {
        pending = nil
        lastOutcome = .disabled(managed: false)
    }

    /// Automatic checks were switched back on. Clears the "off" status (which
    /// would otherwise sit there reading "Automatic update checks are off." next
    /// to an ON toggle) and restores any notice the last check had found.
    func automaticChecksEnabled() async {
        if case .disabled(managed: false) = lastOutcome { lastOutcome = nil }
        await loadPersistedState()
    }

    /// Suppress this version (and older) permanently.
    func skipPending() async {
        guard let tag = pending?.tag else { return }
        await checker.skip(tag: tag)
        skippedTag = tag
        if case .available(let r) = lastOutcome { lastOutcome = .skipped(r) }
        pending = nil
    }

    /// Undo a skip. Doesn't re-fetch — the caller follows with `checkNow`.
    func clearSkip() async {
        await checker.clearSkip()
        skippedTag = nil
    }

    /// Open the release page in the default browser. The one and only egress of
    /// the "download" action.
    func openReleasePage() {
        guard let url = pending?.releasePage ?? lastOutcome?.skippedRelease?.releasePage else {
            NSWorkspace.shared.open(Self.releasesPageURL)
            return
        }
        NSWorkspace.shared.open(url)
    }

    static let releasesPageURL = URL(
        string: "https://github.com/\(UpdateFeed.owner)/\(UpdateFeed.repo)/releases/latest")!

    // MARK: - Display

    /// One-line status for Settings ▸ General ▸ Updates.
    var statusText: String {
        if isManagedDisabled { return "Update checks are turned off by your organization." }
        if checking { return "Checking…" }
        switch lastOutcome {
        case .available(let r):
            return "Version \(r.version) is available."
        case .skipped(let r):
            return "Version \(r.version) is available — you chose to skip it."
        case .disabled(managed: false):
            return "Automatic update checks are off."
        case .disabled(managed: true):
            return "Update checks are turned off by your organization."
        case .failed(let e):
            return Self.message(for: e)
        case .throttled(let until):
            if let until, until > Date() {
                return "Checked recently. Next check \(Self.relative(until))."
            }
            return lastCheckedText
        case .upToDate:
            return "You're up to date." + (lastChecked.map { " Last checked \(Self.relative($0))." } ?? "")
        case nil:
            return lastCheckedText
        }
    }

    private var lastCheckedText: String {
        guard let lastChecked else { return "Not checked yet." }
        return "Last checked \(Self.relative(lastChecked))."
    }

    private static func message(for error: UpdateFeedError) -> String {
        switch error {
        case .connection:
            "Couldn't reach GitHub. Check your connection and try again."
        case .rateLimited:
            "GitHub is rate-limiting update checks right now. Try again later."
        case .http(let status):
            "GitHub returned an error (\(status)). Try again later."
        case .malformedResponse:
            "Couldn't read the release information from GitHub."
        case .unexpectedRedirect:
            "The update check was redirected somewhere unexpected and was stopped."
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

extension UpdateCheckOutcome {
    /// The release behind a `.skipped` outcome, if any.
    var skippedRelease: ReleaseInfo? {
        if case .skipped(let r) = self { return r }
        return nil
    }
}
