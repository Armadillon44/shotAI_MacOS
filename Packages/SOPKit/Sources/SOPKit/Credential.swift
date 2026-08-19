import Foundation

/// A resolved Anthropic credential, ready to stamp on a request.
///
/// The secret is `private` with no accessor, so nothing outside this file can
/// read it back. That carries the `ApiKeyStore` invariant — "FOR THE CLAUDE
/// CLIENT ONLY — never surface the return value to UI" — across the type
/// system rather than by convention.
///
/// An `enum` with a public associated `String` would NOT do this: `if case
/// .federated(let raw)` hands the secret to any caller, and it would leak
/// through string interpolation, `String(describing:)`, and `dump()`. Hence a
/// struct with private storage and every printing path overridden —
/// `description`, `debugDescription`, and `customMirror`, which is what
/// `dump()` walks.
///
/// Deliberately NOT `Equatable`. Comparing credentials is not a real need, and
/// a failing equality assertion is exactly how a secret reaches test output.
public struct ClaudeCredential: Sendable, CustomStringConvertible,
                                CustomDebugStringConvertible, CustomReflectable {
    public enum Kind: Sendable, Equatable {
        /// Static `sk-ant-api…` key — bring-your-own, Settings ▸ AI ▸ Advanced.
        case apiKey
        /// Short-lived `sk-ant-oat01-…` minted by the WIF exchange (#69).
        case federated
    }

    public let kind: Kind
    private let secret: String

    private init(kind: Kind, _ secret: String) {
        self.kind = kind
        self.secret = secret
    }

    public static func apiKey(_ s: String) -> Self { .init(kind: .apiKey, s) }
    public static func federated(_ s: String) -> Self { .init(kind: .federated, s) }

    /// The ONLY place an Anthropic auth header is written. Internal on purpose:
    /// `ClaudeClient.makeRequest` is the sole caller.
    func apply(to req: inout URLRequest) {
        switch kind {
        case .apiKey:
            req.setValue(secret, forHTTPHeaderField: "x-api-key")
        case .federated:
            req.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        }
    }

    /// True when the value at least looks like the token type it claims to be.
    /// Cheap sanity check for the smoke test; NOT validation — only the server
    /// can say whether a credential works.
    var looksWellFormed: Bool {
        switch kind {
        case .apiKey: secret.hasPrefix("sk-ant-")
        case .federated: secret.hasPrefix("sk-ant-oat")
        }
    }

    public var description: String { "ClaudeCredential(\(kind), <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["kind": kind, "secret": "<redacted>"])
    }
}

/// Resolves the credential to use for a request. Implementations live in SOPKit
/// (stored key) and EntraKit (federated, and the composite that prefers it).
public protocol CredentialProvider: Sendable {
    /// The credential to send, refreshing it if that is cheap and silent.
    /// Throws `ClaudeError.noKey` / `.notSignedIn` when nothing is available.
    func credential() async throws -> ClaudeCredential
    /// UI-safe snapshot. Never carries a secret.
    func status() async -> CredentialStatus
}

/// UI-safe view of which credential path is live. Never carries a secret.
public struct CredentialStatus: Sendable, Equatable {
    public enum Active: Sendable, Equatable { case none, federated, storedKey, envKey }

    public let active: Active
    /// A federated account record exists (it may still need a refresh).
    public let signedIn: Bool
    /// Display label for the signed-in account. Personal data: never logged.
    public let accountLabel: String?
    /// nil = not yet observed. false = the last Entra token carried no
    /// `shotAI.User` role. Advisory only — the CEL rule is the enforcement
    /// point, this just lets the UI explain a denial before it happens.
    public let entitled: Bool?
    /// Federation config was delivered (by MDM or a dev override).
    public let federationConfigured: Bool
    /// Field NAMES only, never values, for config that is missing or malformed.
    public let configProblems: [String]
    public let apiKey: ApiKeyStatus

    public init(active: Active, signedIn: Bool = false, accountLabel: String? = nil,
                entitled: Bool? = nil, federationConfigured: Bool = false,
                configProblems: [String] = [],
                apiKey: ApiKeyStatus = ApiKeyStatus(hasKey: false, source: .none)) {
        self.active = active
        self.signedIn = signedIn
        self.accountLabel = accountLabel
        self.entitled = entitled
        self.federationConfigured = federationConfigured
        self.configProblems = configProblems
        self.apiKey = apiKey
    }

    /// Can a request be made at all right now?
    public var canGenerate: Bool { active != .none }
}

/// The bring-your-own-key path, unchanged in behaviour from before federation.
public struct StoredKeyCredentialProvider: CredentialProvider {
    private let keyStore: ApiKeyStore
    public init(keyStore: ApiKeyStore) { self.keyStore = keyStore }

    public func credential() async throws -> ClaudeCredential {
        guard let key = keyStore.key() else { throw ClaudeError.noKey }
        return .apiKey(key)
    }

    public func status() async -> CredentialStatus {
        let s = keyStore.status()
        return CredentialStatus(
            active: s.hasKey ? (s.source == .env ? .envKey : .storedKey) : .none,
            apiKey: s)
    }
}
