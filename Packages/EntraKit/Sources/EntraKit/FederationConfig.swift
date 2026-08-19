import Foundation
import SOPKit

/// The six values needed to federate, plus what they resolve into.
///
/// None is a credential — the JWT is what authenticates — but together they map
/// an organization's Entra tenant and Anthropic org, so they are NEVER committed
/// (both repos are public). They arrive from an MDM configuration profile; see
/// `docs/SSO-WIF.md` § Configuration and `Intune/`.
public struct FederationConfig: Sendable, Equatable {
    public let entra: EntraConfig
    public let anthropic: AnthropicFederationIds

    /// Preference keys, matching the profile payload. Kept alongside the reader
    /// so a rename cannot drift from the deployed profile.
    public enum Key {
        public static let tenantId = "federationEntraTenantId"
        public static let clientId = "federationEntraClientId"
        public static let audienceAppId = "federationEntraAudienceAppId"
        public static let ruleId = "federationRuleId"
        public static let organizationId = "federationOrganizationId"
        public static let serviceAccountId = "federationServiceAccountId"
        public static let workspaceId = "federationWorkspaceId"

        public static let all = [tenantId, clientId, audienceAppId, ruleId,
                                 organizationId, serviceAccountId, workspaceId]
    }

    /// Redirect URI registered on the app registration. Must byte-match, and the
    /// scheme half is what ASWebAuthenticationSession listens for.
    public static let callbackScheme = "msauth.com.armadillon44.shotai"
    public static var redirectURI: String { "\(callbackScheme)://auth" }

    /// The app role a user must hold. Checked locally only to explain a denial
    /// early — the federation rule's CEL condition is the enforcement point.
    public static let requiredRole = "shotAI.User"

    /// Build a state from a key lookup. Shared by every source so "what counts as
    /// missing" cannot drift between them.
    static func assemble(_ lookup: (String) -> String?) -> FederationConfigState {
        let found = Key.all.reduce(into: [String: String]()) { acc, k in
            if let v = lookup(k) { acc[k] = v }
        }
        if found.isEmpty { return .absent }
        let missing = Key.all.filter { found[$0] == nil }
        guard missing.isEmpty else { return .invalid(missing: missing) }
        return .ready(FederationConfig(
            entra: EntraConfig(tenantId: found[Key.tenantId]!, clientId: found[Key.clientId]!,
                               audienceAppId: found[Key.audienceAppId]!,
                               redirectURI: redirectURI, callbackScheme: callbackScheme),
            anthropic: AnthropicFederationIds(
                federationRuleId: found[Key.ruleId]!, organizationId: found[Key.organizationId]!,
                serviceAccountId: found[Key.serviceAccountId]!, workspaceId: found[Key.workspaceId]!)))
    }
}

/// Outcome of looking for federation config. Distinguishes "this Mac isn't set up
/// for SSO" (normal for an external user) from "it is, but wrongly" (an IT bug),
/// because those need completely different messages.
public enum FederationConfigState: Sendable, Equatable {
    case absent
    case invalid(missing: [String])
    case ready(FederationConfig)

    public var config: FederationConfig? {
        if case .ready(let c) = self { return c }
        return nil
    }
    public var missingFields: [String] {
        if case .invalid(let m) = self { return m }
        return []
    }
}

/// Where federation config comes from. A protocol so tests can supply values
/// without touching real user defaults.
public protocol FederationConfigSource: Sendable {
    func load() -> FederationConfigState
}

/// Reads config from a plist bundled in the app.
///
/// This is the normal path: the values are baked into the build so a user can
/// download shotAI, sign in, and be done — no profile to deploy, nothing to type.
///
/// They are NOT encrypted or obfuscated, deliberately. Anything shipped inside an
/// app is extractable with `strings` or a debugger, so obfuscation buys minutes
/// against anyone who cares while costing real complexity and creating false
/// confidence. It also isn't needed: none of these is a credential. Using them
/// requires an Entra token from the tenant carrying the required app role, which
/// the federation rule's CEL condition enforces server-side. The OAuth client_id
/// in particular is *expected* to be public — that is precisely what PKCE exists
/// for, because a public client cannot hold a secret.
///
/// What IS avoided is putting them in the public SOURCE, where they would be free
/// reconnaissance (naming a tenant and an Anthropic org) and would live in git
/// history forever. Hence: gitignored plist, baked at build time.
public struct BundledFederationConfig: FederationConfigSource {
    private let info: [String: String]

    /// Reads `Federation.plist` from the app bundle. That file is gitignored, so a
    /// fresh clone of this public repo has none, `load()` returns `.absent`, and
    /// the app uses bring-your-own-key — exactly right for an external user.
    public init(bundle: Bundle = .main, resource: String = "Federation") {
        guard let url = bundle.url(forResource: resource, withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { self.info = [:]; return }
        self.info = raw.compactMapValues { $0 as? String }
    }

    public func load() -> FederationConfigState {
        FederationConfig.assemble { key in
            let v = info[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (v?.isEmpty ?? true) ? nil : v
        }
    }
}

/// Tries each source in order and takes the first that yields anything.
///
/// Managed preferences come FIRST so IT can correct a baked-in value (a rotated
/// federation rule, say) with a configuration profile instead of a new build,
/// without that being the normal requirement.
public struct ChainedFederationConfig: FederationConfigSource {
    private let sources: [any FederationConfigSource]
    public init(_ sources: [any FederationConfigSource]) { self.sources = sources }

    public func load() -> FederationConfigState {
        var firstProblem: FederationConfigState?
        for s in sources {
            switch s.load() {
            case .ready(let c): return .ready(c)
            case .invalid(let m): if firstProblem == nil { firstProblem = .invalid(missing: m) }
            case .absent: continue
            }
        }
        return firstProblem ?? .absent
    }
}

/// Fixed config, for tests and the self-test executable.
public struct StaticFederationConfig: FederationConfigSource {
    private let state: FederationConfigState
    public init(_ state: FederationConfigState) { self.state = state }
    public func load() -> FederationConfigState { state }
}

/// Reads federation config from managed preferences.
///
/// A class, not a struct, because `UserDefaults` is not `Sendable` under Swift 6
/// — the same shape `UpdateKit.UserDefaultsUpdateState` uses. Reads are
/// thread-safe in `UserDefaults` itself; the unchecked conformance covers only
/// the stored reference.
public final class ManagedFederationConfigStore: FederationConfigSource, @unchecked Sendable {
    private let defaults: UserDefaults
    /// When true, accept values that are merely present rather than MDM-forced.
    /// DEBUG builds only — see `init`.
    private let allowUnmanaged: Bool

    public init(defaults: UserDefaults = .standard, allowUnmanaged: Bool? = nil) {
        self.defaults = defaults
        #if DEBUG
        // Dev override: `defaults write com.armadillon44.shotai federationRuleId …`
        // works in a Debug build so the flow can be exercised without enrolling
        // the Mac in MDM. Compiled out of Release, so a shipped app only ever
        // trusts a configuration profile.
        self.allowUnmanaged = allowUnmanaged ?? true
        #else
        self.allowUnmanaged = allowUnmanaged ?? false
        #endif
    }

    /// A value is trusted when it came from a managed domain. `objectIsForced` is
    /// true ONLY for a profile-delivered value, so a user running
    /// `defaults write` cannot switch federation on for themselves and point the
    /// app at an org they do not belong to.
    private func value(_ key: String) -> String? {
        guard allowUnmanaged || defaults.objectIsForced(forKey: key) else { return nil }
        let v = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (v?.isEmpty ?? true) ? nil : v
    }

    public func load() -> FederationConfigState {
        FederationConfig.assemble { value($0) }
    }
}
