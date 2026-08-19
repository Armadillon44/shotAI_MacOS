import CryptoKit
import Foundation
import SOPKit
import XCTest
@testable import EntraKit

final class PkceTests: XCTestCase {
    func testVerifierIsUnreservedAndLongEnough() {
        let p = PkceParameters()
        // RFC 7636 §4.1: 43...128 chars from the unreserved set.
        XCTAssertGreaterThanOrEqual(p.codeVerifier.count, 43)
        XCTAssertLessThanOrEqual(p.codeVerifier.count, 128)
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        XCTAssertTrue(p.codeVerifier.unicodeScalars.allSatisfy(unreserved.contains),
                      "a verifier needing escaping would break the token POST")
    }

    func testChallengeIsS256OfVerifier() {
        let p = PkceParameters()
        let expected = Base64URL.encode(Data(SHA256.hash(data: Data(p.codeVerifier.utf8))))
        XCTAssertEqual(p.codeChallenge, expected)
        XCTAssertEqual(p.codeChallengeMethod, "S256")
    }

    func testEachSignInGetsFreshValues() {
        let a = PkceParameters(), b = PkceParameters()
        XCTAssertNotEqual(a.codeVerifier, b.codeVerifier)
        XCTAssertNotEqual(a.state, b.state, "a reused state would defeat the CSRF check")
    }

    func testConstantTimeEqualsMatchesSemantics() {
        XCTAssertTrue(constantTimeEquals("abc", "abc"))
        XCTAssertFalse(constantTimeEquals("abc", "abd"))
        XCTAssertFalse(constantTimeEquals("abc", "abcd"), "length differences must not pass")
        XCTAssertTrue(constantTimeEquals("", ""))
    }

    func testAadstsExtraction() {
        XCTAssertEqual(aadstsCode(in: "AADSTS50076: MFA required"), 50076)
        XCTAssertNil(aadstsCode(in: "no code here"))
    }
}

final class JWTPeekTests: XCTestCase {
    func testReadsRolesAndLabel() {
        let jwt = fakeJWT(["roles": ["shotAI.User"], "preferred_username": "a@b.com",
                           "tid": "t1", "scp": "user_impersonation"])
        let p = JWTPeek(jwt)
        XCTAssertEqual(p?.roles, ["shotAI.User"])
        XCTAssertTrue(p?.hasRole("shotAI.User") ?? false)
        XCTAssertEqual(p?.accountLabel, "a@b.com")
        XCTAssertEqual(p?.tenantId, "t1")
        XCTAssertFalse(p?.isAppOnly ?? true)
    }

    /// Entra OMITS `roles` for an unassigned user rather than sending []. This is
    /// the case the whole local pre-flight exists for.
    func testAbsentRolesIsEmptyNotCrash() {
        let p = JWTPeek(fakeJWT(["preferred_username": "a@b.com", "scp": "x"]))
        XCTAssertEqual(p?.roles, [])
        XCTAssertFalse(p?.hasRole("shotAI.User") ?? true)
    }

    func testDetectsAppOnlyToken() {
        XCTAssertTrue(JWTPeek(fakeJWT(["idtyp": "app", "roles": ["shotAI.User"]]))?.isAppOnly ?? false)
    }

    func testRejectsGarbage() {
        XCTAssertNil(JWTPeek("not-a-jwt"))
        XCTAssertNil(JWTPeek(""))
        XCTAssertNil(JWTPeek("a.b"))
    }
}

final class FederationConfigTests: XCTestCase {
    private func defaults(_ values: [String: String]) -> UserDefaults {
        let d = UserDefaults(suiteName: "entrakit-test-\(UUID().uuidString)")!
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }
    private var complete: [String: String] {
        [FederationConfig.Key.tenantId: "t", FederationConfig.Key.clientId: "c",
         FederationConfig.Key.audienceAppId: "a", FederationConfig.Key.ruleId: "fdrl_x",
         FederationConfig.Key.organizationId: "o", FederationConfig.Key.serviceAccountId: "svac_x",
         FederationConfig.Key.workspaceId: "wrkspc_x"]
    }

    func testAbsentWhenNothingSet() {
        let s = ManagedFederationConfigStore(defaults: defaults([:]), allowUnmanaged: true)
        XCTAssertEqual(s.load(), .absent)
    }

    /// Partial config is its own state: "IT set this up wrong" needs a different
    /// message from "this Mac isn't set up for SSO", which is normal externally.
    func testPartialConfigNamesTheMissingFieldsOnly() {
        var v = complete
        v.removeValue(forKey: FederationConfig.Key.workspaceId)
        v.removeValue(forKey: FederationConfig.Key.ruleId)
        let s = ManagedFederationConfigStore(defaults: defaults(v), allowUnmanaged: true)
        guard case .invalid(let missing) = s.load() else { return XCTFail("expected .invalid") }
        XCTAssertEqual(Set(missing), [FederationConfig.Key.workspaceId, FederationConfig.Key.ruleId])
    }

    func testCompleteConfigResolves() {
        let s = ManagedFederationConfigStore(defaults: defaults(complete), allowUnmanaged: true)
        guard let c = s.load().config else { return XCTFail("expected .ready") }
        XCTAssertEqual(c.entra.tenantId, "t")
        XCTAssertEqual(c.anthropic.workspaceId, "wrkspc_x")
        // The scope must be the explicit one. `.default` on a client requesting
        // its OWN resource returns an id_token, and the exchange then fails with
        // an opaque 401 that looks exactly like a broken federation rule.
        XCTAssertEqual(c.entra.apiScope, "api://a/user_impersonation")
        XCTAssertFalse(c.entra.scopes.contains(".default"))
        XCTAssertTrue(c.entra.scopes.contains("offline_access"))
    }

    /// Unmanaged values are ignored in the shipping configuration, so a user
    /// cannot `defaults write` themselves into another org's federation.
    func testUnmanagedValuesIgnoredWhenManagedOnly() {
        let s = ManagedFederationConfigStore(defaults: defaults(complete), allowUnmanaged: false)
        XCTAssertEqual(s.load(), .absent, "objectIsForced is false for a plain defaults write")
    }

    func testBlankValuesCountAsMissing() {
        var v = complete
        v[FederationConfig.Key.clientId] = "   "
        let s = ManagedFederationConfigStore(defaults: defaults(v), allowUnmanaged: true)
        XCTAssertEqual(s.load().missingFields, [FederationConfig.Key.clientId])
    }
}

final class EntraAuthClientTests: XCTestCase {
    private func client(_ t: EntraTransport) -> EntraAuthClient {
        EntraAuthClient(config: testConfig.entra, transport: t)
    }

    func testAuthorizeURLCarriesPkceAndRedirect() async {
        let c = client(MockEntraTransport.ok())
        let url = await c.authorizeURL(pkce: PkceParameters(), loginHint: nil, claims: nil,
                                       promptSelectAccount: false)
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
        XCTAssertEqual(url.host, "login.microsoftonline.com")
        XCTAssertTrue(url.path.contains("/tenant-1/"), "tenant-specific authority, never /common")
        XCTAssertEqual(v("response_type"), "code")
        XCTAssertEqual(v("code_challenge_method"), "S256")
        XCTAssertEqual(v("redirect_uri"), FederationConfig.redirectURI)
        XCTAssertNotNil(v("code_challenge"))
        XCTAssertNotNil(v("state"))
    }

    /// A forged callback must never reach the token leg.
    func testCallbackWithWrongStateIsRejected() async {
        let c = client(MockEntraTransport.ok())
        let url = URL(string: "msauth.com.armadillon44.shotai://auth?code=abc&state=WRONG")!
        do {
            _ = try await c.parseCallback(url, expectedState: "RIGHT")
            XCTFail("expected rejection")
        } catch let e as EntraAuthError {
            guard case .callbackInvalid = e else { return XCTFail("wrong case: \(e)") }
        } catch { XCTFail("wrong error") }
    }

    func testCallbackErrorsClassify() async {
        let c = client(MockEntraTransport.ok())
        let base = "msauth.com.armadillon44.shotai://auth?state=S"
        do {
            _ = try await c.parseCallback(URL(string: "\(base)&error=consent_required")!, expectedState: "S")
            XCTFail()
        } catch let e as EntraAuthError {
            guard case .interactionRequired = e else { return XCTFail("wrong case: \(e)") }
        } catch { XCTFail() }
    }

    /// The classification table is what turns an opaque AADSTS number into the
    /// right user action, so each bucket gets pinned.
    func testAadstsClassification() {
        func classify(_ code: Int, error: String = "invalid_grant") -> EntraAuthError {
            let json = #"{"error":"\#(error)","error_description":"AADSTS\#(code): x","error_codes":[\#(code)]}"#
            return EntraAuthClient.classify(status: 400, headers: [:], body: Data(json.utf8))
        }
        guard case .interactionRequired = classify(53003) else { return XCTFail("53003 = CA block") }
        guard case .interactionRequired = classify(50076) else { return XCTFail("50076 = MFA") }
        guard case .reauthenticationRequired = classify(70008) else { return XCTFail("70008 = dead grant") }
        guard case .configuration = classify(50011) else { return XCTFail("50011 = bad redirect URI") }
        guard case .configuration = classify(7000218) else { return XCTFail("7000218 = public client off") }
        // Unrecognised invalid_grant defaults to "the grant is gone", not config.
        guard case .reauthenticationRequired = classify(999999) else { return XCTFail("default") }
    }

    func test5xxAndThrottlingAreTransient() {
        let e = EntraAuthClient.classify(status: 503, headers: ["retry-after": "7"],
                                         body: Data(#"{"error":"server_error"}"#.utf8))
        guard case .transient(_, let after) = e else { return XCTFail("expected transient") }
        XCTAssertEqual(after, 7)
    }
}
