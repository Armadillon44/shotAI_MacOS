import Foundation
import SOPKit

/// Prefers a federated session, falls back to a stored API key.
///
/// Precedence is `federated → stored key → ANTHROPIC_API_KEY env`, which
/// deliberately INVERTS the order Anthropic's own SDKs use (they put the env var
/// first). The whole point of this work is that a managed Mac needs no key, so a
/// leftover key must not silently shadow SSO. The consequence is the reverse —
/// someone with both sees their key ignored — which Settings states in one line.
///
/// When federation is not configured at all, this behaves exactly like the
/// bring-your-own-key path always did. That matters: both repos are public and
/// external users have no Entra tenant.
public struct CompositeCredentialProvider: CredentialProvider {
    private let federated: FederatedCredentialProvider?
    private let stored: StoredKeyCredentialProvider
    private let configState: FederationConfigState

    public init(configState: FederationConfigState,
                federated: FederatedCredentialProvider?,
                keyStore: ApiKeyStore) {
        self.configState = configState
        self.federated = federated
        self.stored = StoredKeyCredentialProvider(keyStore: keyStore)
    }

    public func credential() async throws -> ClaudeCredential {
        if let federated {
            do {
                return try await federated.credential()
            } catch let e as ClaudeError where Self.shouldFallBack(e) {
                // Not signed in is not a failure when a key is available — an
                // admin testing with their own key should not be forced to sign in.
                if let key = try? await stored.credential() { return key }
                throw e
            }
        }
        if case .invalid(let missing) = configState {
            // Config was delivered but is unusable. Fall back to a key if one
            // exists, otherwise say so — this is an IT problem, not a user one.
            if let key = try? await stored.credential() { return key }
            throw ClaudeError.configInvalid(fields: missing)
        }
        return try await stored.credential()
    }

    /// Only "there is no session" falls through to a key. A signed-in user whose
    /// account lacks the app role, or whose session needs renewing, must SEE that
    /// — silently falling back would hide the thing they need to fix.
    private static func shouldFallBack(_ e: ClaudeError) -> Bool {
        e.kind == .notSignedIn
    }

    public func status() async -> CredentialStatus {
        let keyStatus = await stored.status()
        guard let federated else {
            return CredentialStatus(
                active: keyStatus.active,
                federationConfigured: false,
                configProblems: configState.missingFields,
                apiKey: keyStatus.apiKey)
        }
        let fed = await federated.status()
        return CredentialStatus(
            active: fed.signedIn ? .federated : keyStatus.active,
            signedIn: fed.signedIn,
            accountLabel: fed.accountLabel,
            entitled: fed.entitled,
            federationConfigured: true,
            configProblems: configState.missingFields,
            apiKey: keyStatus.apiKey)
    }
}
