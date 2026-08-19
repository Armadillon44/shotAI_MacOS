import Foundation
import SOPKit

/// Turns a signed-in Entra account into a short-lived Anthropic credential.
///
/// Two caches, two different lifetimes:
///   - the Entra REFRESH token persists in the Keychain (the only long-lived
///     secret in the design),
///   - the minted `sk-ant-oat01-…` lives in memory only, for ~10 minutes.
///
/// Refresh is LAZY and use-time, never scheduled. A `Timer` set against a
/// wall-clock deadline is unreliable on a laptop that sleeps: the Mac wakes with
/// the timer un-fired and the token long dead. Checking at the moment of use is
/// both simpler and correct across sleep.
public actor FederatedCredentialProvider: CredentialProvider {
    private let config: FederationConfig
    private let auth: EntraAuthClient
    private let claude: ClaudeClient
    private let store: any FederationAccountStore

    /// Re-mint this long before expiry. Generous because Anthropic mints
    /// `min(rule lifetime, 2 x remaining JWT life)` — presenting a nearly-dead
    /// assertion yields a uselessly short session rather than an error.
    private static let renewMargin: TimeInterval = 120

    private var cached: MintedToken?
    /// Coalesces concurrent mints. `estimate` and `generate` can race, and each
    /// mint is a round trip to Entra AND to Anthropic — plus every exchange
    /// spends against the same rule.
    private var inFlight: Task<MintedToken, Error>?

    public init(config: FederationConfig,
                auth: EntraAuthClient? = nil,
                claude: ClaudeClient = ClaudeClient(),
                store: any FederationAccountStore = KeychainFederationAccountStore()) {
        self.config = config
        self.auth = auth ?? EntraAuthClient(config: config.entra)
        self.claude = claude
        self.store = store
    }

    // MARK: CredentialProvider

    public func credential() async throws -> ClaudeCredential {
        try await validToken().credential
    }

    public func status() async -> CredentialStatus {
        let acct = store.load()
        return CredentialStatus(
            active: acct == nil ? .none : .federated,
            signedIn: acct != nil,
            accountLabel: acct?.accountLabel,
            entitled: acct?.hadRequiredRole,
            federationConfigured: true)
    }

    // MARK: Sign in / out

    /// Interactive sign-in. Persists the account on success.
    @discardableResult
    public func signIn(using browser: any InteractiveSignIn,
                       promptSelectAccount: Bool = false,
                       forceLogin: Bool = false) async throws -> FederationAccount {
        let tokens = try await auth.signIn(using: browser,
                                           promptSelectAccount: promptSelectAccount,
                                           forceLogin: forceLogin)
        let peek = JWTPeek(tokens.accessToken)
        let account = FederationAccount(
            refreshToken: tokens.refreshToken ?? "",
            accountLabel: peek?.accountLabel ?? JWTPeek(tokens.idToken ?? "")?.accountLabel,
            hadRequiredRole: peek.map { $0.hasRole(FederationConfig.requiredRole) },
            tenantId: peek?.tenantId)
        try store.save(account)
        cached = nil
        return account
    }

    public func signOut() throws {
        cached = nil
        inFlight?.cancel()
        inFlight = nil
        try store.clear()
    }

    /// Whether the stored account is known to lack the required role. Lets the UI
    /// explain the problem before the user waits for a denial.
    public func entitlement() -> Bool? { store.load()?.hadRequiredRole }

    // MARK: Minting

    private func validToken() async throws -> MintedToken {
        if let t = cached, t.expiresAt.timeIntervalSinceNow > Self.renewMargin { return t }
        if let inFlight { return try await inFlight.value }

        let task = Task<MintedToken, Error> { [self] in try await mint() }
        inFlight = task
        defer { inFlight = nil }
        let minted = try await task.value
        cached = minted
        return minted
    }

    private func mint() async throws -> MintedToken {
        guard let account = store.load(), !account.refreshToken.isEmpty else {
            throw ClaudeError.notSignedIn
        }

        let tokens: EntraTokens
        do {
            tokens = try await auth.refresh(refreshToken: account.refreshToken)
        } catch let e as EntraAuthError {
            throw Self.mapEntra(e, account: account)
        }

        // Entra ROTATES the refresh token and does not revoke the old one, so the
        // new one is persisted BEFORE the access token is used. A crash in the
        // other order leaves a stale token on disk and silently signs the user out.
        if let rotated = tokens.refreshToken, rotated != account.refreshToken {
            let peek = JWTPeek(tokens.accessToken)
            try? store.save(FederationAccount(
                refreshToken: rotated,
                accountLabel: peek?.accountLabel ?? account.accountLabel,
                hadRequiredRole: peek.map { $0.hasRole(FederationConfig.requiredRole) }
                    ?? account.hadRequiredRole,
                tenantId: peek?.tenantId ?? account.tenantId))
        }

        // LOCAL pre-flight. Anthropic's denial for a missing app role is an opaque
        // 401 indistinguishable from a broken rule, so catching it here is the
        // difference between "ask IT for access" and a support ticket saying
        // sign-in is broken. Advisory only — the CEL rule still enforces it.
        if let peek = JWTPeek(tokens.accessToken), !peek.hasRole(FederationConfig.requiredRole) {
            throw ClaudeError.notEntitled(account: peek.accountLabel ?? account.accountLabel)
        }

        return try await claude.exchangeFederatedToken(
            assertion: tokens.accessToken, ids: config.anthropic)
    }

    /// Map Entra's failure modes onto what the user should actually do.
    private static func mapEntra(_ e: EntraAuthError, account: FederationAccount) -> ClaudeError {
        switch e {
        case .interactionRequired(_, _, let d), .reauthenticationRequired(_, let d):
            return .signInRequired(reason: d)
        case .transient:
            return .connection
        case .configuration(_, let d):
            return .configInvalid(fields: [d])
        case .callbackInvalid(let d):
            return .signInRequired(reason: d)
        case .web(.canceled):
            return .signInRequired(reason: nil)
        case .web(let w):
            return .signInRequired(reason: w.errorDescription)
        }
    }
}
