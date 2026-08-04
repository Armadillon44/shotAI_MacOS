import Foundation
import Security
import ShotModel

/// Detects the TCC grants an app update silently threw away.
///
/// ## The failure this exists for
/// macOS keys a TCC grant to the app's **designated requirement**, not its bundle
/// id. A Developer ID signature makes that requirement `identifier … and anchor
/// apple generic and certificate leaf[subject.OU] = <team>`, which a later build
/// still satisfies, so grants survive an update. An **ad-hoc** signature — what
/// the shipped DMG currently uses — reduces the requirement to a bare `cdhash`,
/// a content hash of the binary. Change one byte and the new build is a
/// different app as far as TCC is concerned, and every grant is orphaned.
///
/// macOS says nothing when that happens. ScreenCaptureKit returns no content, the
/// AX element query is denied, the event tap never fires, and System Settings
/// grows a second dead "shotAI" row in each pane. To the user, capture simply
/// stopped working after an update.
///
/// ## What this does about it
/// Records which permissions were granted, against the identity they were granted
/// to. When the identity changes and something that used to be granted no longer
/// is, that is an update having reset it, and the UI can say so instead of
/// showing the generic first-run wizard.
///
/// This is a better error message, not a fix. The fix is Developer ID signing +
/// notarization (issue #62 Phase 0), which gives a stable designated requirement
/// and makes the whole failure impossible. **Delete this once that ships.**
public enum PermissionLedger {

    /// What was granted, and to which build identity.
    public struct Snapshot: Codable, Equatable, Sendable {
        /// The code identity the grants belonged to — a cdhash when we can read
        /// one, else the version string (see `currentIdentity`).
        public var identity: String
        /// Human-readable build, for the UI and logs ("1.1.2 (8)").
        public var versionLabel: String
        /// `CapturePermission.rawValue`s granted at that point.
        public var granted: [String]

        public init(identity: String, versionLabel: String, granted: [String]) {
            self.identity = identity
            self.versionLabel = versionLabel
            self.granted = granted
        }

        /// Tolerant: a blob from a future version degrades instead of throwing
        /// away the whole record.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            identity = try c.decode(String.self, forKey: .identity)
            versionLabel = (try? c.decodeIfPresent(String.self, forKey: .versionLabel)) ?? ""
            granted = (try? c.decodeIfPresent([String].self, forKey: .granted)) ?? []
        }

        var grantedPermissions: Set<CapturePermission> {
            Set(granted.compactMap(CapturePermission.init(rawValue:)))
        }
    }

    /// The conclusion drawn at launch.
    public struct Verdict: Equatable, Sendable {
        /// Permissions granted under the previous identity that are not granted
        /// now. Non-empty means an update cost the user something.
        public var lost: [CapturePermission]
        /// True on the very first launch (nothing recorded yet) — the ordinary
        /// first-run path, NOT an update.
        public var isFirstLaunch: Bool
        /// True when the code identity differs from the recorded one.
        public var didChangeIdentity: Bool
        /// The build the grants were made under, for the explanation.
        public var previousVersionLabel: String?

        /// Show the update-specific permissions wizard.
        public var shouldPrompt: Bool { !lost.isEmpty }

        /// "Screen Recording and Accessibility" / "Screen Recording, Accessibility,
        /// and Input Monitoring" — for use in a sentence.
        public var lostList: String {
            let names = lost.map(\.title)
            switch names.count {
            case 0: return ""
            case 1: return names[0]
            case 2: return "\(names[0]) and \(names[1])"
            default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
            }
        }
    }

    /// The whole decision, as a pure function so it is testable without TCC,
    /// UserDefaults, or a code signature.
    ///
    /// A loss is only reported when the identity CHANGED. Without that condition
    /// a user who deliberately switches a permission off in System Settings would
    /// be nagged on every launch; with it, the only trigger is "you had this
    /// before the update and you don't now".
    public static func evaluate(
        previous: Snapshot?, identity: String, granted: Set<CapturePermission>
    ) -> Verdict {
        guard let previous else {
            return Verdict(lost: [], isFirstLaunch: true, didChangeIdentity: false,
                           previousVersionLabel: nil)
        }
        let changed = previous.identity != identity
        // `allCases` order, so the list reads Screen Recording → Accessibility →
        // Input Monitoring rather than in Set order.
        let lost = changed
            ? CapturePermission.allCases.filter { previous.grantedPermissions.contains($0) && !granted.contains($0) }
            : []
        return Verdict(lost: lost, isFirstLaunch: false, didChangeIdentity: changed,
                       previousVersionLabel: previous.versionLabel.isEmpty ? nil : previous.versionLabel)
    }

    // MARK: - Identity

    /// The running code's cdhash, hex-encoded — the same value TCC keys an
    /// ad-hoc grant to, so it changes on exactly the rebuilds that orphan grants
    /// (including a re-cut of the *same* version number, which a version-string
    /// comparison would miss).
    ///
    /// nil if the signing information can't be read; `currentIdentity` then falls
    /// back to the version string, which still catches every normal release.
    public static func codeDirectoryHash() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let data = dict[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Version + build, e.g. "1.1.2 (8)".
    public static func versionLabel(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(short) (\(build))"
    }

    /// cdhash when available, else the version label.
    public static func currentIdentity(bundle: Bundle = .main) -> String {
        codeDirectoryHash().map { "cdhash:\($0)" } ?? "version:\(versionLabel(bundle: bundle))"
    }

    // MARK: - Persistence

    /// Stores the snapshot in `UserDefaults`.
    ///
    /// COMMIT RULE, and it is the part that matters: a snapshot is only written
    /// once nothing is lost. While a loss is outstanding the OLD snapshot stays,
    /// so every launch keeps reporting it — capture is still broken and the
    /// reason is still the update. `acknowledge` is the escape hatch for someone
    /// who genuinely doesn't want a permission back.
    public final class Store: @unchecked Sendable {
        public static let defaultKey = "capturePermissionLedger.v1"

        private let defaults: UserDefaults
        private let key: String

        public init(defaults: UserDefaults = .standard, key: String = Store.defaultKey) {
            self.defaults = defaults
            self.key = key
        }

        public func load() -> Snapshot? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(Snapshot.self, from: data)
        }

        public func save(_ snapshot: Snapshot) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: key)
        }

        /// Evaluate this launch and persist if there's nothing outstanding.
        @discardableResult
        public func record(
            identity: String, versionLabel: String, granted: Set<CapturePermission>
        ) -> Verdict {
            let verdict = evaluate(previous: load(), identity: identity, granted: granted)
            if verdict.lost.isEmpty {
                save(Snapshot(identity: identity, versionLabel: versionLabel,
                              granted: granted.map(\.rawValue).sorted()))
            }
            return verdict
        }

        /// Stop reporting the outstanding loss: commit the current state as the
        /// new baseline. Wired to the wizard's dismiss button so a user who has
        /// decided they no longer want a permission isn't asked again.
        public func acknowledge(
            identity: String, versionLabel: String, granted: Set<CapturePermission>
        ) {
            save(Snapshot(identity: identity, versionLabel: versionLabel,
                          granted: granted.map(\.rawValue).sorted()))
        }

        public func reset() { defaults.removeObject(forKey: key) }
    }

    /// Convenience for the app: evaluate this launch against the real bundle,
    /// the real code signature, and the real TCC state.
    @discardableResult
    public static func recordLaunch(store: Store = Store()) -> Verdict {
        let granted = Set(CapturePermission.allCases.filter { $0.isGranted() })
        let verdict = store.record(
            identity: currentIdentity(), versionLabel: versionLabel(), granted: granted)
        if verdict.shouldPrompt {
            Log.capture.notice(
                "update reset \(verdict.lost.count, privacy: .public) TCC grant(s) [\(verdict.lostList, privacy: .public)] — previous build \(verdict.previousVersionLabel ?? "?", privacy: .public)")
        }
        return verdict
    }
}
