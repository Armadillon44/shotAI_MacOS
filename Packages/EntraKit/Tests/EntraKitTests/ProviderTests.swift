import Foundation
import SOPKit
import XCTest
@testable import EntraKit

final class FederatedProviderTests: XCTestCase {
    private func provider(entra: EntraTransport = MockEntraTransport.ok(),
                          claude: ClaudeTransport,
                          account: FederationAccount? = FederationAccount(
                            refreshToken: "rt-old", accountLabel: "a@b.com",
                            hadRequiredRole: true, tenantId: "tenant-1"),
                          store: InMemoryFederationAccountStore? = nil)
    -> (FederatedCredentialProvider, InMemoryFederationAccountStore) {
        let s = store ?? InMemoryFederationAccountStore(account)
        let p = FederatedCredentialProvider(
            config: testConfig,
            auth: EntraAuthClient(config: testConfig.entra, transport: entra),
            claude: ClaudeClient(transport: claude),
            store: s)
        return (p, s)
    }

    func testMintsAFederatedCredential() async throws {
        let counter = Counter()
        let (p, _) = provider(claude: MockClaudeTransport.counting(counter))
        let c = try await p.credential()
        XCTAssertEqual(c.kind, .federated)
        XCTAssertEqual(counter.value, 1)
    }

    /// A second call inside the token's life must not spend another exchange.
    func testCachesWithinLifetime() async throws {
        let counter = Counter()
        let (p, _) = provider(claude: MockClaudeTransport.counting(counter, expiresIn: 600))
        _ = try await p.credential()
        _ = try await p.credential()
        _ = try await p.credential()
        XCTAssertEqual(counter.value, 1, "the cached token should be reused")
    }

    /// A token inside the renew margin is re-minted rather than handed out to
    /// expire mid-request.
    func testReMintsNearExpiry() async throws {
        let counter = Counter()
        // 60s < the 120s renew margin, so every call must re-mint.
        let (p, _) = provider(claude: MockClaudeTransport.counting(counter, expiresIn: 60))
        _ = try await p.credential()
        _ = try await p.credential()
        XCTAssertEqual(counter.value, 2)
    }

    /// estimate() and generate() race in the real app. Without coalescing each
    /// would mint separately, doubling the round trips and the rule's spend.
    func testConcurrentCallsCoalesceIntoOneExchange() async throws {
        let counter = Counter()
        // Sleep widens the window so the three calls genuinely overlap.
        let slow = MockClaudeTransport { _ in
            counter.bump()
            Thread.sleep(forTimeInterval: 0.05)
            return (Data(#"{"access_token":"sk-ant-oat01-t","expires_in":600}"#.utf8),
                    ResponseHead(status: 200))
        }
        let (p, _) = provider(claude: slow)
        async let a = p.credential()
        async let b = p.credential()
        async let c = p.credential()
        _ = try await (a, b, c)
        XCTAssertEqual(counter.value, 1, "three concurrent callers, one exchange")
    }

    /// Entra rotates the refresh token and does NOT revoke the old one, so the
    /// new one must be persisted or the next launch signs the user out.
    func testRotatedRefreshTokenIsPersisted() async throws {
        let (p, store) = provider(entra: MockEntraTransport.ok(refresh: "rt-rotated"),
                                  claude: MockClaudeTransport.counting(Counter()))
        _ = try await p.credential()
        XCTAssertEqual(store.load()?.refreshToken, "rt-rotated")
    }

    /// The centrepiece. Signed in fine, no app role: caught locally so the user
    /// is told to ask IT, instead of getting an opaque 401 from Anthropic.
    func testMissingAppRoleIsCaughtLocally() async {
        let counter = Counter()
        let (p, _) = provider(entra: MockEntraTransport.ok(roles: []),
                              claude: MockClaudeTransport.counting(counter))
        do {
            _ = try await p.credential()
            XCTFail("expected notEntitled")
        } catch {
            XCTAssertEqual((error as? ClaudeError)?.kind, .notEntitled)
            let d = error.localizedDescription
            XCTAssertTrue(d.contains("user@example.com"), "name the account")
            XCTAssertFalse(d.lowercased().contains("sign-in failed"))
            XCTAssertEqual(counter.value, 0, "must not spend an exchange that cannot succeed")
        }
    }

    func testNoAccountIsNotSignedIn() async {
        let (p, _) = provider(claude: MockClaudeTransport.counting(Counter()),
                              store: InMemoryFederationAccountStore(nil))
        do {
            _ = try await p.credential()
            XCTFail("expected notSignedIn")
        } catch {
            XCTAssertEqual((error as? ClaudeError)?.kind, .notSignedIn)
        }
    }

    /// A dead refresh token must ask for interactive sign-in, not look like a
    /// network blip the user should retry.
    func testDeadGrantAsksForSignIn() async {
        let (p, _) = provider(
            entra: MockEntraTransport.failing(#"{"error":"invalid_grant","error_codes":[70008],"error_description":"AADSTS70008"}"#),
            claude: MockClaudeTransport.counting(Counter()))
        do {
            _ = try await p.credential()
            XCTFail("expected signInRequired")
        } catch {
            XCTAssertEqual((error as? ClaudeError)?.kind, .signInRequired)
        }
    }

    func testSignOutClearsTheAccount() async throws {
        let (p, store) = provider(claude: MockClaudeTransport.counting(Counter()))
        _ = try await p.credential()
        try await p.signOut()
        XCTAssertNil(store.load())
        let s = await p.status()
        XCTAssertFalse(s.signedIn)
        XCTAssertEqual(s.active, .none)
    }

    func testInteractiveSignInStoresAccountAndRole() async throws {
        let (p, store) = provider(claude: MockClaudeTransport.counting(Counter()),
                                  store: InMemoryFederationAccountStore(nil))
        let acct = try await p.signIn(using: StubSignIn.succeeding())
        XCTAssertEqual(acct.accountLabel, "user@example.com")
        XCTAssertEqual(acct.hadRequiredRole, true)
        XCTAssertEqual(store.load()?.refreshToken, "rt-new")
    }
}

final class CompositeProviderTests: XCTestCase {
    private func keyStore(_ key: String?) -> ApiKeyStore { StubKeys(key) }

    private struct StubKeys: ApiKeyStore {
        let stored: String?
        init(_ k: String?) { stored = k }
        func key() -> String? { stored }
        func status() -> ApiKeyStatus {
            ApiKeyStatus(hasKey: stored != nil, source: stored != nil ? .stored : .none)
        }
        func set(_ key: String) throws {}
        func clear() throws {}
    }

    private func federated(roles: [String] = ["shotAI.User"],
                           account: FederationAccount? = FederationAccount(
                            refreshToken: "rt", accountLabel: "a@b.com",
                            hadRequiredRole: true, tenantId: "tenant-1"))
    -> FederatedCredentialProvider {
        FederatedCredentialProvider(
            config: testConfig,
            auth: EntraAuthClient(config: testConfig.entra, transport: MockEntraTransport.ok(roles: roles)),
            claude: ClaudeClient(transport: MockClaudeTransport.counting(Counter())),
            store: InMemoryFederationAccountStore(account))
    }

    /// Federation wins over a stored key. This inverts the SDK's own precedence
    /// on purpose: a leftover key must not silently shadow SSO.
    func testFederatedWinsOverStoredKey() async throws {
        let c = CompositeCredentialProvider(configState: .ready(testConfig),
                                            federated: federated(),
                                            keyStore: keyStore("sk-ant-api-xyz"))
        let cred = try await c.credential()
        XCTAssertEqual(cred.kind, .federated)
    }

    /// Not signed in, but a key exists: use it. An admin testing with their own
    /// key should not be forced through SSO.
    func testFallsBackToKeyWhenNotSignedIn() async throws {
        let c = CompositeCredentialProvider(configState: .ready(testConfig),
                                            federated: federated(account: nil),
                                            keyStore: keyStore("sk-ant-api-xyz"))
        let cred = try await c.credential()
        XCTAssertEqual(cred.kind, .apiKey)
    }

    /// But a signed-in user WITHOUT the role must see that, not be silently
    /// switched to some other credential — it is the thing they need to fix.
    func testDoesNotMaskAMissingAppRole() async {
        let c = CompositeCredentialProvider(configState: .ready(testConfig),
                                            federated: federated(roles: []),
                                            keyStore: keyStore("sk-ant-api-xyz"))
        do {
            _ = try await c.credential()
            XCTFail("expected notEntitled to surface")
        } catch {
            XCTAssertEqual((error as? ClaudeError)?.kind, .notEntitled)
        }
    }

    /// With no federation configured at all, behaviour is exactly what it always
    /// was. Both repos are public; external users have no Entra tenant.
    func testUnconfiguredBehavesLikeByoKey() async throws {
        let c = CompositeCredentialProvider(configState: .absent, federated: nil,
                                            keyStore: keyStore("sk-ant-api-xyz"))
        let cred = try await c.credential()
        XCTAssertEqual(cred.kind, .apiKey)
        let s = await c.status()
        XCTAssertFalse(s.federationConfigured)
        XCTAssertEqual(s.active, .storedKey)
    }

    func testUnconfiguredAndNoKeyIsNoKey() async {
        let c = CompositeCredentialProvider(configState: .absent, federated: nil,
                                            keyStore: keyStore(nil))
        do { _ = try await c.credential(); XCTFail() }
        catch { XCTAssertEqual((error as? ClaudeError)?.kind, .noKey) }
    }

    /// Broken MDM config with no key: name it as a config problem, so the user
    /// contacts IT instead of hunting for a setting.
    func testInvalidConfigSurfacesAsConfigProblem() async {
        let c = CompositeCredentialProvider(configState: .invalid(missing: ["federationRuleId"]),
                                            federated: nil, keyStore: keyStore(nil))
        do { _ = try await c.credential(); XCTFail() }
        catch {
            XCTAssertEqual((error as? ClaudeError)?.kind, .configInvalid)
            XCTAssertTrue(error.localizedDescription.contains("federationRuleId"))
        }
    }
}
