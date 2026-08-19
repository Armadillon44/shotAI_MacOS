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
        let found = FederationConfig.Key.all.reduce(into: [String: String]()) { acc, k in
            if let v = value(k) { acc[k] = v }
        }
        if found.isEmpty { return .absent }

        let missing = FederationConfig.Key.all.filter { found[$0] == nil }
        guard missing.isEmpty else { return .invalid(missing: missing) }

        return .ready(FederationConfig(
            entra: EntraConfig(
                tenantId: found[FederationConfig.Key.tenantId]!,
                clientId: found[FederationConfig.Key.clientId]!,
                audienceAppId: found[FederationConfig.Key.audienceAppId]!,
                redirectURI: FederationConfig.redirectURI,
                callbackScheme: FederationConfig.callbackScheme),
            anthropic: AnthropicFederationIds(
                federationRuleId: found[FederationConfig.Key.ruleId]!,
                organizationId: found[FederationConfig.Key.organizationId]!,
                serviceAccountId: found[FederationConfig.Key.serviceAccountId]!,
                workspaceId: found[FederationConfig.Key.workspaceId]!)))
    }
}
