import Foundation
import SOPKit
@testable import EntraKit

/// Canned Entra token-endpoint responses.
struct MockEntraTransport: EntraTransport {
    var handler: @Sendable (URLRequest) -> (Data, Int, [String: String])
    init(_ h: @escaping @Sendable (URLRequest) -> (Data, Int, [String: String])) { handler = h }

    func post(_ request: URLRequest) async throws -> (Data, Int, [String: String]) {
        handler(request)
    }

    /// A successful token response. `roles` is embedded in a fake unsigned JWT so
    /// the local entitlement pre-flight can be exercised.
    static func ok(roles: [String] = ["shotAI.User"], upn: String = "user@example.com",
                   refresh: String = "rt-new", expiresIn: Int = 3600) -> MockEntraTransport {
        MockEntraTransport { _ in
            let jwt = fakeJWT(["roles": roles, "preferred_username": upn,
                               "scp": "user_impersonation", "tid": "tenant-1"])
            let body: [String: Any] = ["access_token": jwt, "expires_in": expiresIn,
                                       "refresh_token": refresh, "token_type": "Bearer"]
            return (try! JSONSerialization.data(withJSONObject: body), 200, [:])
        }
    }

    static func failing(_ json: String, status: Int = 400) -> MockEntraTransport {
        MockEntraTransport { _ in (Data(json.utf8), status, [:]) }
    }
}

/// Build an unsigned JWT with the given payload. Only the payload is ever read —
/// JWTPeek explicitly does not verify signatures.
func fakeJWT(_ payload: [String: Any]) -> String {
    func seg(_ o: [String: Any]) -> String {
        let d = try! JSONSerialization.data(withJSONObject: o)
        return d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(seg(["alg": "none"])).\(seg(payload)).sig"
}

/// Canned Anthropic responses for the exchange leg.
struct MockClaudeTransport: ClaudeTransport {
    var dataHandler: @Sendable (URLRequest) -> (Data, ResponseHead)
    init(_ h: @escaping @Sendable (URLRequest) -> (Data, ResponseHead)) { dataHandler = h }

    func data(for request: URLRequest) async throws -> (Data, ResponseHead) { dataHandler(request) }
    func stream(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, ResponseHead) {
        (AsyncThrowingStream { $0.finish() }, ResponseHead(status: 200))
    }

    /// Counts exchanges, so coalescing can be asserted.
    static func counting(_ counter: Counter, expiresIn: Int = 600) -> MockClaudeTransport {
        MockClaudeTransport { _ in
            counter.bump()
            let body = #"{"access_token":"sk-ant-oat01-tok","expires_in":\#(expiresIn)}"#
            return (Data(body.utf8), ResponseHead(status: 200))
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

struct StubSignIn: InteractiveSignIn {
    var callback: @Sendable (URL) throws -> URL
    func authorize(url: URL, callbackScheme: String, ephemeral: Bool) async throws -> URL {
        try callback(url)
    }
    /// Echo the state back, as a real callback would.
    static func succeeding() -> StubSignIn {
        StubSignIn { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "state" }?.value ?? ""
            return URL(string: "msauth.com.armadillon44.shotai://auth?code=abc&state=\(state)")!
        }
    }
}

let testConfig = FederationConfig(
    entra: EntraConfig(tenantId: "tenant-1", clientId: "client-1", audienceAppId: "aud-1",
                       redirectURI: FederationConfig.redirectURI,
                       callbackScheme: FederationConfig.callbackScheme),
    anthropic: AnthropicFederationIds(federationRuleId: "fdrl_x", organizationId: "org",
                                      serviceAccountId: "svac_x", workspaceId: "wrkspc_x"))
