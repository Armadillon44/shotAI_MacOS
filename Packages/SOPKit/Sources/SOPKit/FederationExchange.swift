import Foundation

/// The four Anthropic-side identifiers the RFC 7523 exchange needs. None is a
/// credential — the JWT is what authenticates — but together they name an
/// organization, so they ship via MDM and never in source
/// (see `docs/SSO-WIF.md` § Configuration).
public struct AnthropicFederationIds: Sendable, Equatable {
    public let federationRuleId: String
    public let organizationId: String
    public let serviceAccountId: String
    /// `"default"` is a legal literal here, not a sentinel for "unset".
    public let workspaceId: String

    public init(federationRuleId: String, organizationId: String,
                serviceAccountId: String, workspaceId: String) {
        self.federationRuleId = federationRuleId
        self.organizationId = organizationId
        self.serviceAccountId = serviceAccountId
        self.workspaceId = workspaceId
    }
}

/// One exchange's result. The raw token never escapes: callers get a
/// `ClaudeCredential`, which has no accessor.
public struct MintedToken: Sendable, CustomStringConvertible, CustomReflectable {
    public let credential: ClaudeCredential
    public let expiresAt: Date
    public let scope: String?

    public var description: String {
        "MintedToken(expires: \(expiresAt), scope: \(scope ?? "-"))"
    }
    public var customMirror: Mirror {
        Mirror(self, children: ["expiresAt": expiresAt, "scope": scope as Any])
    }
}

extension ClaudeClient {
    /// `POST /v1/oauth/token` — the assertion exchange proven by
    /// `Scripts/wif-probe.sh`.
    ///
    /// Deliberately does NOT go through `makeRequest`: this request carries no
    /// auth header because the assertion *is* the authentication. It still uses
    /// `Self.baseURL` and `transport`, so the host pin holds and `MockTransport`
    /// covers it in tests.
    ///
    /// Deliberately does NOT map its 401 through `ClaudeError.from` either.
    /// That would produce "Invalid API key." — the single worst sentence to show
    /// someone who has no key and just signed in successfully. Every denial here
    /// is the same opaque 401 by design, so the message must not guess a cause.
    public func exchangeFederatedToken(
        assertion: String, ids: AnthropicFederationIds
    ) async throws -> MintedToken {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent("/v1/oauth/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
            "federation_rule_id": ids.federationRuleId,
            "organization_id": ids.organizationId,
            "service_account_id": ids.serviceAccountId,
            "workspace_id": ids.workspaceId,
        ])

        let (data, head) = try await transport.data(for: req)
        let failure = ApiFailure(message: Self.apiMessage(data), requestId: head.requestId,
                                 retryAfter: head.retryAfter, shouldRetry: head.shouldRetry)
        guard head.status == 200 else {
            switch head.status {
            case 401, 403: throw ClaudeError.federationRefused(failure)
            case 429: throw ClaudeError.rateLimited(failure)
            case 500...: throw ClaudeError.overloaded
            default: throw ClaudeError.api(status: head.status, failure: failure)
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String, !token.isEmpty
        else { throw ClaudeError.malformed }

        let ttl = (obj["expires_in"] as? Int) ?? 600
        return MintedToken(
            credential: .federated(token),
            // An absolute Date, re-checked against `Date()` at every use. Never a
            // cached "seconds remaining", and never a monotonic clock: a Mac that
            // slept for six hours barely advanced its monotonic clock while the
            // token expired on wall time.
            expiresAt: Date().addingTimeInterval(TimeInterval(ttl)),
            scope: obj["scope"] as? String)
    }
}
