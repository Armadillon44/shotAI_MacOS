import Foundation

// MARK: - Configuration

/// Everything needed to talk to one tenant's Entra app registration. None of it
/// is a secret — a PUBLIC client has no client_secret — but together these map
/// an organization, so they ship via an MDM configuration profile, not source.
public struct EntraConfig: Sendable, Equatable {
    /// Directory (tenant) ID GUID. Never `"common"`: the WIF rule pins `tid`, and
    /// a tenant-specific authority is what makes AADSTS50194 impossible.
    public let tenantId: String
    /// Application (client) ID of the app registration.
    public let clientId: String
    /// App registration exposing `api://<id>` as the audience. Currently the same
    /// registration as the client; kept separate so splitting them later is a
    /// config change, not a code change.
    public let audienceAppId: String
    /// Must byte-match a registered redirect URI, including case.
    public let redirectURI: String
    /// Scheme half of `redirectURI`, without "://".
    public let callbackScheme: String

    public init(tenantId: String, clientId: String, audienceAppId: String,
                redirectURI: String, callbackScheme: String) {
        self.tenantId = tenantId
        self.clientId = clientId
        self.audienceAppId = audienceAppId
        self.redirectURI = redirectURI
        self.callbackScheme = callbackScheme
    }

    /// The resource scope.
    ///
    /// NEVER `api://<APP_ID>/.default`. A client requesting its OWN `.default` is
    /// documented to return an id_token rather than an access token; the WIF
    /// exchange would then fail with an opaque 401 that looks exactly like a
    /// broken federation rule. `Scripts/wif-probe.sh` may use `.default` safely
    /// only because the Azure CLI is a DIFFERENT client — do not port that line.
    public var apiScope: String { "api://\(audienceAppId)/user_impersonation" }

    /// `offline_access` buys the refresh token; `openid profile` buys an id_token
    /// so the UI can say "Signed in as …" without a Graph call.
    public var scopes: String { "\(apiScope) offline_access openid profile" }

    var authorizeURL: URL {
        URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/authorize")!
    }
    var tokenURL: URL {
        URL(string: "https://login.microsoftonline.com/\(tenantId)/oauth2/v2.0/token")!
    }
}

// MARK: - Wire types

public struct EntraTokens: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let expiresAt: Date
    public let scope: String?
}

private struct TokenResponseDTO: Decodable {
    let access_token: String
    let expires_in: Int?
    let scope: String?
    let refresh_token: String?
    let id_token: String?
}

private struct EntraErrorDTO: Decodable {
    let error: String?
    let error_description: String?
    let error_codes: [Int]?
    /// Present on a Conditional Access challenge; must be replayed verbatim.
    let claims: String?
}

// MARK: - Errors

public enum EntraAuthError: Error, LocalizedError, Sendable {
    /// Sign in again interactively. `claims` is non-nil for a CA step-up.
    case interactionRequired(aadsts: Int?, claims: String?, description: String)
    /// Refresh token is dead (expired, revoked, password changed). Start over.
    case reauthenticationRequired(aadsts: Int?, description: String)
    /// Retry with backoff: 5xx, throttling, network loss.
    case transient(description: String, retryAfter: TimeInterval?)
    /// The app registration or deployment is wrong. Retrying never helps.
    case configuration(aadsts: Int?, description: String)
    /// `state` mismatch on the callback, or no `code` in it.
    case callbackInvalid(String)
    case web(WebAuthError)

    public var errorDescription: String? {
        switch self {
        case .interactionRequired(_, _, let d): d
        case .reauthenticationRequired(_, let d): d
        case .transient(let d, _): d
        case .configuration(_, let d): d
        case .callbackInvalid(let d): d
        case .web(let e): e.errorDescription
        }
    }
}

// MARK: - Transport

/// Network seam for the two Entra token legs, so the AADSTS classification
/// table is unit-testable headless. Mirrors `SOPKit.ClaudeTransport`.
public protocol EntraTransport: Sendable {
    func post(_ request: URLRequest) async throws -> (Data, Int, [String: String])
}

/// Refuses any redirect that leaves login.microsoftonline.com, so an off-host
/// 302 cannot carry a refresh token away. Same posture as UpdateKit's RedirectPin.
private final class EntraRedirectPin: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.host?.lowercased() == "login.microsoftonline.com" ? request : nil)
    }
}

public struct URLSessionEntraTransport: EntraTransport {
    private let session: URLSession
    private let pin = EntraRedirectPin()

    /// Ephemeral: token responses must never touch an on-disk URLCache, and there
    /// is no cookie state worth keeping (the browser owns that jar).
    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func post(_ request: URLRequest) async throws -> (Data, Int, [String: String]) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: pin)
        } catch let e as URLError {
            throw EntraAuthError.transient(description: e.localizedDescription, retryAfter: nil)
        }
        guard let http = response as? HTTPURLResponse else { return (data, 0, [:]) }
        var h: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { h[k.lowercased()] = v }
        }
        return (data, http.statusCode, h)
    }
}

// MARK: - Client

public actor EntraAuthClient {
    private let config: EntraConfig
    private let transport: EntraTransport

    public init(config: EntraConfig, transport: EntraTransport = URLSessionEntraTransport()) {
        self.config = config
        self.transport = transport
    }

    // MARK: Interactive sign-in

    /// Full authorization-code + PKCE round trip.
    public func signIn(using browser: any InteractiveSignIn,
                       loginHint: String? = nil,
                       claims: String? = nil,
                       promptSelectAccount: Bool = false,
                       forceLogin: Bool = false) async throws -> EntraTokens {
        let pkce = PkceParameters()
        let url = authorizeURL(pkce: pkce, loginHint: loginHint, claims: claims,
                               promptSelectAccount: promptSelectAccount, forceLogin: forceLogin)
        let callback: URL
        do {
            callback = try await browser.authorize(url: url,
                                                   callbackScheme: config.callbackScheme,
                                                   ephemeral: false)
        } catch let e as WebAuthError {
            throw EntraAuthError.web(e)
        }
        let code = try parseCallback(callback, expectedState: pkce.state)
        return try await redeem(code: code, verifier: pkce.codeVerifier)
    }

    // MARK: URL construction

    func authorizeURL(pkce: PkceParameters, loginHint: String?, claims: String?,
                      promptSelectAccount: Bool, forceLogin: Bool = false) -> URL {
        var q: [(String, String)] = [
            ("client_id", config.clientId),
            ("response_type", "code"),
            ("redirect_uri", config.redirectURI),
            ("response_mode", "query"),
            ("scope", config.scopes),
            ("state", pkce.state),
            ("code_challenge", pkce.codeChallenge),
            ("code_challenge_method", pkce.codeChallengeMethod),
        ]
        if let loginHint { q.append(("login_hint", loginHint)) }
        // Replay a Conditional Access claims challenge verbatim, so the user is
        // stepped up (MFA / compliant device) inside this same session.
        if let claims { q.append(("claims", claims)) }
        if forceLogin { q.append(("prompt", "login")) }
        else if promptSelectAccount { q.append(("prompt", "select_account")) }

        var c = URLComponents(url: config.authorizeURL, resolvingAgainstBaseURL: false)!
        // Encoded by hand: URLComponents leaves ":" "/" "@" "+" legal-but-unescaped
        // in a query, and Entra documents redirect_uri as URL-encoded.
        c.percentEncodedQuery = q.map { "\(Self.pct($0.0))=\(Self.pct($0.1))" }.joined(separator: "&")
        return c.url!
    }

    // MARK: Callback parsing

    func parseCallback(_ url: URL, expectedState: String) throws -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            throw EntraAuthError.callbackInvalid("Sign-in returned no parameters.")
        }
        func value(_ n: String) -> String? { items.first { $0.name == n }?.value }

        // `state` FIRST — an attacker-forged callback must not reach the token leg.
        guard let state = value("state"), constantTimeEquals(state, expectedState) else {
            throw EntraAuthError.callbackInvalid("Sign-in response failed its anti-forgery check.")
        }
        if let err = value("error") {
            let desc = value("error_description") ?? err
            let code = aadstsCode(in: desc)
            switch err {
            case "interaction_required", "login_required", "consent_required":
                throw EntraAuthError.interactionRequired(aadsts: code, claims: value("claims"), description: desc)
            case "access_denied":
                throw EntraAuthError.interactionRequired(aadsts: code, claims: nil, description: desc)
            case "server_error", "temporarily_unavailable":
                throw EntraAuthError.transient(description: desc, retryAfter: nil)
            default:
                throw EntraAuthError.configuration(aadsts: code, description: desc)
            }
        }
        guard let code = value("code"), !code.isEmpty else {
            throw EntraAuthError.callbackInvalid("Sign-in response contained no authorization code.")
        }
        return code
    }

    // MARK: Token legs

    /// authorization_code grant. PUBLIC client: no client_secret, no assertion.
    func redeem(code: String, verifier: String) async throws -> EntraTokens {
        try await post([
            "client_id": config.clientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier,
            "scope": config.scopes,
        ])
    }

    /// refresh_token grant.
    ///
    /// IMPORTANT: Entra ROTATES the refresh token — every successful call returns
    /// a new one and does not revoke the old. The caller MUST persist the new
    /// refresh token before using the new access token, or a crash in between
    /// leaves a stale token on disk and silently signs the user out.
    public func refresh(refreshToken: String) async throws -> EntraTokens {
        try await post([
            "client_id": config.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": config.scopes,
        ])
    }

    private func post(_ fields: [String: String]) async throws -> EntraTokens {
        var req = URLRequest(url: config.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Data(Self.formEncode(fields).utf8)

        let (data, status, headers) = try await transport.post(req)
        guard status == 200 else { throw Self.classify(status: status, headers: headers, body: data) }
        guard let dto = try? JSONDecoder().decode(TokenResponseDTO.self, from: data) else {
            throw EntraAuthError.transient(description: "Entra returned an unreadable token response.", retryAfter: nil)
        }
        return EntraTokens(
            accessToken: dto.access_token,
            refreshToken: dto.refresh_token,
            idToken: dto.id_token,
            // 60s of slack: the token must still be valid when Anthropic evaluates
            // it, and Anthropic mints min(rule lifetime, 2x remaining JWT life) —
            // so a nearly-expired assertion yields a uselessly short session.
            expiresAt: Date().addingTimeInterval(TimeInterval(max(0, (dto.expires_in ?? 3600) - 60))),
            scope: dto.scope)
    }

    // MARK: Error classification

    /// Codes meaning "an interactive session is the only way forward".
    static let interactionRequiredCodes: Set<Int> = [
        50076,  // UserStrongAuthClientAuthNRequired — CA/per-user MFA now required
        50078,  // UserStrongAuthExpired — MFA claim aged out
        50079,  // UserStrongAuthEnrollmentRequired
        50158,  // External security challenge not satisfied (3rd-party MFA, ToU)
        53000,  // DeviceNotCompliant (Intune)
        53001,  // DeviceNotDomainJoined
        53002,  // ApplicationUsedIsNotAnApprovedApp
        53003,  // BlockedByConditionalAccess
        50005,  // DevicePolicyError — platform blocked by CA
        50097,  // DeviceAuthenticationRequired
        65001,  // DelegationDoesNotExist — consent not granted yet
        16000,  // InteractionRequired — account picker needed
        50058,  // UserInformationNotProvided — no SSO session
    ]

    /// Codes meaning "the refresh token is dead; start over".
    static let reauthCodes: Set<Int> = [
        50173,  // Grant revoked — password change/reset, admin revocation
        70008,  // ExpiredOrRevokedGrant — inactivity
        700082, // ExpiredOrRevokedGrantInactiveToken
        // 700084 is the SPA 24h refresh-token ceiling. It should NEVER fire for a
        // publicClient redirect — if it does, the redirect URI got registered
        // under the "Single-page application" platform instead of "Mobile and
        // desktop applications". Kept as that canary.
        700084,
        50089,  // Flow token expired
        50085,  // Refresh token needs social IdP login
        54005,  // Authorization code already redeemed
        65004,  // UserDeclinedConsent
    ]

    /// Codes that are always a misconfiguration. Retrying is pointless.
    static let configCodes: Set<Int> = [
        50011,   // InvalidReplyTo — redirect_uri not registered / case mismatch
        7000218, // Public client not recognised — "Allow public client flows" off,
                 //   or the redirect URI sits under the wrong platform
        7000215, // Invalid client secret supplied (a public client must send none)
        650057,  // Resource not in the client's requiredResourceAccess
        500011,  // Resource principal not found in the tenant
        700016,  // App not found in the directory/tenant
        70011,   // invalid_scope
        50194,   // App is single-tenant but /common was used
        900144,  // Missing required body parameter
    ]

    static func classify(status: Int, headers: [String: String], body: Data) -> EntraAuthError {
        let dto = try? JSONDecoder().decode(EntraErrorDTO.self, from: body)
        let desc = dto?.error_description
            ?? String(data: body, encoding: .utf8)
            ?? "Entra returned HTTP \(status)."
        let codes = dto?.error_codes ?? []
        let primary = codes.first ?? aadstsCode(in: desc)
        let retryAfter = headers["retry-after"].flatMap(TimeInterval.init)

        if status == 429 || status >= 500 {
            return .transient(description: desc, retryAfter: retryAfter ?? 5)
        }
        if let c = codes.first(where: { interactionRequiredCodes.contains($0) }) {
            return .interactionRequired(aadsts: c, claims: dto?.claims, description: desc)
        }
        if let c = codes.first(where: { reauthCodes.contains($0) }) {
            return .reauthenticationRequired(aadsts: c, description: desc)
        }
        if let c = codes.first(where: { configCodes.contains($0) }) {
            return .configuration(aadsts: c, description: desc)
        }
        switch dto?.error {
        case "interaction_required", "consent_required", "login_required":
            return .interactionRequired(aadsts: primary, claims: dto?.claims, description: desc)
        case "invalid_grant":
            // Default for invalid_grant with an unrecognised code: the grant is gone.
            return .reauthenticationRequired(aadsts: primary, description: desc)
        case "temporarily_unavailable", "server_error":
            return .transient(description: desc, retryAfter: retryAfter ?? 5)
        default:
            return .configuration(aadsts: primary, description: desc)
        }
    }

    // MARK: Helpers

    /// Percent-encode down to the RFC 3986 unreserved set.
    static func pct(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    static func formEncode(_ fields: [String: String]) -> String {
        fields.keys.sorted().map { "\(pct($0))=\(pct(fields[$0]!))" }.joined(separator: "&")
    }
}
