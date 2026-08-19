import Foundation

/// A read-only peek at an unverified JWT payload.
///
/// **This is not validation.** The signature is never checked, and this must
/// never be treated as a security decision — Anthropic verifies the assertion
/// against the issuer's JWKS, and the federation rule's CEL condition is the
/// actual enforcement point (see `docs/SSO-WIF.md`).
///
/// It exists for one reason. When a signed-in user has NOT been granted the
/// `shotAI.User` app role, Entra issues them a perfectly valid token and
/// Anthropic then refuses it with an opaque 401 that is indistinguishable from a
/// broken rule. Reading `roles` locally is what lets the app say "your sign-in
/// worked, you just don't have access yet" instead of implying the login failed.
///
/// Only the claims the app actually needs are extracted, as typed values, rather
/// than keeping an untyped `[String: Any]` around — that keeps it `Sendable` and
/// keeps the blast radius of a surprising token shape small.
public struct JWTPeek: Sendable, Equatable {
    /// Entra emits `roles` as an array of strings, and OMITS it entirely for a
    /// user with no assignment rather than sending an empty array.
    public let roles: [String]
    public let tenantId: String?
    public let audience: String?
    public let issuer: String?
    /// Delegated-token marker. Absent on app-only tokens.
    public let scope: String?
    /// `"app"` marks an app-only token; a human's token never carries it.
    public let identityType: String?
    public let expiresAt: Date?
    /// Best display label. PERSONAL DATA: fine to show, fine to keep in the
    /// Keychain, never log it.
    public let accountLabel: String?

    public init?(_ jwt: String) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let data = Base64URL.decode(String(parts[1])),
              let c = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func str(_ n: String) -> String? { c[n] as? String }
        self.roles = (c["roles"] as? [String]) ?? []
        self.tenantId = str("tid")
        self.audience = str("aud")
        self.issuer = str("iss")
        self.scope = str("scp")
        self.identityType = str("idtyp")
        self.expiresAt = (c["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        self.accountLabel = str("preferred_username") ?? str("upn") ?? str("email") ?? str("name")
    }

    public func hasRole(_ role: String) -> Bool { roles.contains(role) }

    /// True when this is an app-only token rather than a human's. The probe
    /// (`Scripts/wif-probe.sh`) refuses a PASS on the same signal, because an
    /// app-only token carries byte-identical iss/aud/tid to a user token.
    public var isAppOnly: Bool { identityType == "app" || (scope == nil && accountLabel == nil) }
}
