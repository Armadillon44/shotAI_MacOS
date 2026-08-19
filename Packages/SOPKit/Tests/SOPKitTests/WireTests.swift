import Foundation
import XCTest
@testable import SOPKit
import ShotModel

final class SettingsAndPromptTests: XCTestCase {
    func testCoerceFallsBackOnUnknown() {
        let s = coerceSopSettings([
            "enabled": false,
            "model": "gpt-4",              // unknown → base
            "tone": "sarcastic",           // unknown → base
            "effort": "extreme",           // unknown → base
            "customInstructions": String(repeating: "x", count: 5000),
        ])
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.model, DEFAULT_SOP_MODEL)
        XCTAssertEqual(s.tone, DEFAULT_SOP_TONE)
        XCTAssertEqual(s.effort, DEFAULT_SOP_EFFORT)
        XCTAssertEqual(s.customInstructions.count, SOP_CUSTOM_INSTRUCTIONS_MAX)
    }

    func testCoerceAcceptsValid() {
        let s = coerceSopSettings(["model": "claude-sonnet-5", "tone": "friendly", "effort": "high"])
        XCTAssertEqual(s.model, .sonnet5)
        XCTAssertEqual(s.tone, .friendly)
        XCTAssertEqual(s.effort, .high)
    }

    func testSystemPromptComposition() {
        let base = buildSystemPrompt(settings: SopSettings(tone: .concise, customInstructions: "  Keep it under 5 steps.  "))
        XCTAssertTrue(base.hasPrefix(BASE_SYSTEM_PROMPT))
        XCTAssertTrue(base.contains(TONE_PROMPT[.concise]!))
        XCTAssertTrue(base.contains("Additional instructions from the user:\nKeep it under 5 steps."))
        // Empty custom → no trailing "Additional instructions" block.
        let noCustom = buildSystemPrompt(settings: SopSettings(customInstructions: "   "))
        XCTAssertFalse(noCustom.contains("Additional instructions"))
    }

    func testSchemaSerializesAndRawDecodes() throws {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(sopEditJSONSchema()))
        let json = #"{"title":"T","intro":{"heading":"H","body":"B"},"steps":[{"stepNumber":1,"caption":"C","body":"Bd","sectionHeading":"S","sectionBody":"SB"}]}"#
        let raw = try JSONDecoder().decode(SopEditRaw.self, from: Data(json.utf8))
        XCTAssertEqual(raw.title, "T")
        XCTAssertEqual(raw.intro?.heading, "H")
        XCTAssertEqual(raw.steps.first?.stepNumber, 1)
        XCTAssertEqual(raw.steps.first?.sectionHeading, "S")
    }
}

final class ClaudeClientTests: XCTestCase {
    func testCheckModelOkAndError() async throws {
        let ok = ClaudeClient(transport: MockTransport(dataHandler: { _ in (Data("{}".utf8), ResponseHead(status: 200)) }))
        try await ok.checkModel(credential: .apiKey("sk-ant-test"), model: .sonnet5)  // no throw

        let bad = ClaudeClient(transport: MockTransport(dataHandler: { _ in
            (Data(#"{"error":{"message":"nope"}}"#.utf8), ResponseHead(status: 401))
        }))
        do { try await bad.checkModel(credential: .apiKey("sk-ant-test"), model: .sonnet5); XCTFail("expected throw") }
        catch {
            XCTAssertEqual((error as? ClaudeError)?.kind, .invalidKey)
            // The server's own text is kept, not discarded for a canned string.
            XCTAssertEqual(error.localizedDescription, "nope")
        }
    }

    func testCountTokens() async throws {
        let c = ClaudeClient(transport: MockTransport(dataHandler: { _ in
            (Data(#"{"input_tokens":1234}"#.utf8), ResponseHead(status: 200))
        }))
        let n = try await c.countTokens(credential: .apiKey("sk-ant-test"), model: .sonnet5, system: [], messages: [])
        XCTAssertEqual(n, 1234)

        // 429 WITH a small retry-after: a real throttle, worth retrying.
        let limited = ClaudeClient(transport: MockTransport(dataHandler: { _ in
            (Data("{}".utf8), ResponseHead(status: 429, headers: ["Retry-After": "12"]))
        }))
        do { _ = try await limited.countTokens(credential: .apiKey("sk-ant-test"), model: .sonnet5, system: [], messages: []); XCTFail() }
        catch { XCTAssertEqual((error as? ClaudeError)?.kind, .rateLimited) }
    }

    func testStreamDecodesPlan() async throws {
        let json = #"{"title":"My SOP","intro":null,"steps":[{"stepNumber":1,"caption":"Open menu","body":"Click it","sectionHeading":null,"sectionBody":null}]}"#
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: json), ResponseHead(status: 200)) }))
        let raw = try await c.streamEditPlan(credential: .apiKey("sk-ant-test"), body: [:], onProgress: { _ in })
        XCTAssertEqual(raw.title, "My SOP")
        XCTAssertEqual(raw.steps.count, 1)
        XCTAssertEqual(raw.steps[0].caption, "Open menu")
    }

    func testStreamReassemblesChunkedJSONWithThinkingAndPings() async throws {
        // The structured-output JSON arrives split across many text_deltas, after
        // thinking blocks, interleaved with ping/keepalive events. Reassembly must
        // be lossless and decode to the full plan.
        let json = #"{"title":"My SOP","intro":{"heading":"Overview","body":"Do it"},"steps":[{"stepNumber":1,"caption":"Open menu","body":"Click the menu","sectionHeading":null,"sectionBody":null},{"stepNumber":2,"caption":"Save","body":"Click Save","sectionHeading":null,"sectionBody":null}]}"#
        // Chunk into small pieces to simulate real streaming granularity.
        var chunks: [String] = []
        var i = json.startIndex
        while i < json.endIndex {
            let j = json.index(i, offsetBy: 7, limitedBy: json.endIndex) ?? json.endIndex
            chunks.append(String(json[i..<j]))
            i = j
        }
        var lines: [String] = [
            #"event: message_start"#,
            #"data: {"type":"message_start","message":{"id":"m"}}"#,
            #"event: content_block_start"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"reasoning..."}}"#,
            #"event: ping"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        ]
        for c in chunks {
            lines.append("data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\(jsonStringLiteral(c))}}")
        }
        lines.append(contentsOf: [
            #"data: {"type":"content_block_stop","index":1}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":50}}"#,
            #"data: {"type":"message_stop"}"#,
        ])

        let sse = lines
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (sse, ResponseHead(status: 200)) }))
        let raw = try await c.streamEditPlan(credential: .apiKey("sk-ant-test"), body: [:], onProgress: { _ in })
        XCTAssertEqual(raw.title, "My SOP")
        XCTAssertEqual(raw.intro?.heading, "Overview")
        XCTAssertEqual(raw.steps.map(\.stepNumber), [1, 2])
        XCTAssertEqual(raw.steps[1].caption, "Save")
    }

    func testStreamRefusal() async {
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: "{}", stopReason: "refusal"), ResponseHead(status: 200)) }))
        do { _ = try await c.streamEditPlan(credential: .apiKey("sk-ant-test"), body: [:], onProgress: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .refusal) }
    }

    func testStreamCutoffOnTruncatedMaxTokens() async {
        // A truncated (invalid) JSON body with stop_reason max_tokens → cutoff.
        let lines = sseLines(json: #"{"title":"x","steps":["#, stopReason: "max_tokens")
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (lines, ResponseHead(status: 200)) }))
        do { _ = try await c.streamEditPlan(credential: .apiKey("sk-ant-test"), body: [:], onProgress: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .cutoff) }
    }

    func testStreamSurfacesMidStreamErrorEvent() async {
        // A 200 that then streams an `error` event (overloaded under load) must
        // surface the real error, not a generic "no content".
        let lines = [
            #"data: {"type":"message_start"}"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        ]
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (lines, ResponseHead(status: 200)) }))
        do { _ = try await c.streamEditPlan(credential: .apiKey("sk-ant-test"), body: [:], onProgress: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .overloaded) }
    }

    func testStreamHttpError() async {
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in
            ([#"data: {"error":{"message":"boom"}}"#],
             ResponseHead(status: 500, headers: ["request-id": "req_abc123"]))
        }))
        do { _ = try await c.streamEditPlan(credential: .apiKey("sk-ant-test"), body: [:], onProgress: { _ in }); XCTFail() }
        catch {
            guard case .api(let status, let f)? = error as? ClaudeError else { return XCTFail("wrong: \(error)") }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(f.requestId, "req_abc123")
            XCTAssertTrue(error.localizedDescription.contains("req_abc123"),
                          "the request id is the only handle support can act on — it must reach the user")
        }
    }

    // MARK: 429 classification
    //
    // The reason headers cross the transport seam at all. Under federated auth
    // every user shares one workspace's limits, so a 429 is either "slow down"
    // or "the shared budget is spent" — and Anthropic publishes no distinct
    // error type for the second. Only `retry-after` separates them, so getting
    // this table wrong means telling someone to retry something that cannot
    // succeed until next month.

    private func classify(_ headers: [String: String]) -> ClaudeError.Kind? {
        ClaudeError.from(head: ResponseHead(status: 429, headers: headers), message: nil).kind
    }

    func test429WithSmallRetryAfterIsTransient() {
        XCTAssertEqual(classify(["retry-after": "30"]), .rateLimited)
        XCTAssertEqual(classify(["Retry-After": "1"]), .rateLimited, "header lookup is case-insensitive")
    }

    func test429WithoutRetryAfterIsHardStop() {
        // A real throttle tells you when to come back. Silence is not an
        // invitation to hammer the endpoint.
        XCTAssertEqual(classify([:]), .limitReached)
    }

    func test429WithImplausiblyLongRetryAfterIsHardStop() {
        XCTAssertEqual(classify(["retry-after": "86400"]), .limitReached)
    }

    func test429WithShouldRetryFalseIsHardStop() {
        // The explicit signal wins even when a plausible retry-after is present.
        XCTAssertEqual(classify(["retry-after": "5", "x-should-retry": "false"]), .limitReached)
    }

    func testHttpDateRetryAfterFallsBackToHardStop() {
        // Only delta-seconds is parsed. Failing closed is the safe direction:
        // an unnecessary manual re-run beats promising a retry that cannot work.
        XCTAssertEqual(classify(["retry-after": "Wed, 21 Oct 2026 07:28:00 GMT"]), .limitReached)
    }

    func testHardStopDoesNotClaimWhichLimitWasHit() {
        let d = ClaudeError.from(head: ResponseHead(status: 429), message: nil).errorDescription ?? ""
        XCTAssertTrue(d.contains("rate limit or spending cap"),
                      "a spend cap and a sustained rate limit are indistinguishable here; asserting one would be a guess")
        XCTAssertFalse(d.contains("wait a moment"), "must not invite a retry that cannot succeed")
    }

    func test402IsBilling() {
        XCTAssertEqual(ClaudeError.from(head: ResponseHead(status: 402), message: nil).kind, .billing)
    }

    func testRetryableSet() {
        XCTAssertTrue(ClaudeError.from(head: ResponseHead(status: 429, headers: ["retry-after": "5"]), message: nil).isRetryable)
        XCTAssertFalse(ClaudeError.from(head: ResponseHead(status: 429), message: nil).isRetryable)
        XCTAssertFalse(ClaudeError.from(head: ResponseHead(status: 402), message: nil).isRetryable)
    }
}

final class SopServiceTests: XCTestCase {
    func testDisabledAndNoKey() async {
        let svc = SopService(client: ClaudeClient(transport: MockTransport()), keyStore: StubKeyStore())
        do { _ = try await svc.testKey(settings: SopSettings(enabled: false)); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .disabled) }

        let noKey = SopService(client: ClaudeClient(transport: MockTransport()), keyStore: StubKeyStore(stored: nil))
        do { _ = try await noKey.testKey(settings: SopSettings()); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .noKey) }
    }

    func testEstimateComputesCost() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest

        let svc = SopService(
            client: ClaudeClient(transport: MockTransport(dataHandler: { _ in (Data(#"{"input_tokens":1000000}"#.utf8), ResponseHead(status: 200)) })),
            keyStore: StubKeyStore())
        let est = try await svc.estimate(dir: dir, manifest: m, settings: SopSettings())
        XCTAssertEqual(est.inputTokens, 1_000_000)
        // 1M input @ $3/MTok = $3.00; + 2500 output @ $15/MTok ≈ $0.0375.
        XCTAssertEqual(est.estCostUsd, 3.0 + 2500.0 / 1e6 * 15, accuracy: 0.0001)
    }

    func testGenerateRejectsUnderProducedPlan() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        // Model returned an intro but no usable step edits (low-effort under-produce).
        let empty = #"{"title":"T","intro":{"heading":"H","body":"B"},"steps":[]}"#
        let svc1 = SopService(
            client: ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: empty), ResponseHead(status: 200)) })),
            keyStore: StubKeyStore())
        do { _ = try await svc1.generate(dir: dir, manifest: m, settings: SopSettings()); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .incomplete) }

        // Steps present but all blank → also incomplete.
        let blank = #"{"title":"T","intro":null,"steps":[{"stepNumber":1,"caption":"  ","body":"","sectionHeading":null,"sectionBody":null}]}"#
        let svc2 = SopService(
            client: ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: blank), ResponseHead(status: 200)) })),
            keyStore: StubKeyStore())
        do { _ = try await svc2.generate(dir: dir, manifest: m, settings: SopSettings()); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .incomplete) }

        // A real edit passes.
        let good = #"{"title":"T","intro":null,"steps":[{"stepNumber":1,"caption":"Do it","body":"Click","sectionHeading":null,"sectionBody":null}]}"#
        let svc3 = SopService(
            client: ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: good), ResponseHead(status: 200)) })),
            keyStore: StubKeyStore())
        let plan = try await svc3.generate(dir: dir, manifest: m, settings: SopSettings())
        XCTAssertEqual(plan.steps.first?.caption, "Do it")
    }
}

/// The credential must not be readable, printable, or dumpable. This is the
/// `ApiKeyStore` "never surface the key" invariant, carried across a module
/// boundary by the type rather than by convention — so it needs a test that
/// fails loudly if someone "helpfully" adds an accessor or a synthesized
/// Equatable/Codable conformance later.
final class CredentialRedactionTests: XCTestCase {
    private let secret = "sk-ant-api03-SUPERSECRET-do-not-print"

    func testNotLeakedByInterpolationOrDescription() {
        let c = ClaudeCredential.apiKey(secret)
        XCTAssertFalse("\(c)".contains(secret))
        XCTAssertFalse(String(describing: c).contains(secret))
        XCTAssertFalse(String(reflecting: c).contains(secret))
        XCTAssertTrue("\(c)".contains("redacted"))
    }

    func testNotLeakedByDump() {
        // `dump()` walks customMirror, which is the path a plain struct would
        // leak through even with description overridden.
        var out = ""
        dump(ClaudeCredential.federated(secret), to: &out)
        XCTAssertFalse(out.contains(secret))
        XCTAssertTrue(out.contains("redacted"))
    }

    func testKindIsVisibleButSecretIsNot() {
        XCTAssertEqual(ClaudeCredential.apiKey(secret).kind, .apiKey)
        XCTAssertEqual(ClaudeCredential.federated(secret).kind, .federated)
    }

    /// The header actually written differs by kind — the whole point of the type.
    func testAppliesTheRightHeader() {
        var a = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        ClaudeCredential.apiKey("KEYVAL").apply(to: &a)
        XCTAssertEqual(a.value(forHTTPHeaderField: "x-api-key"), "KEYVAL")
        XCTAssertNil(a.value(forHTTPHeaderField: "authorization"))

        var b = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        ClaudeCredential.federated("TOKVAL").apply(to: &b)
        XCTAssertEqual(b.value(forHTTPHeaderField: "authorization"), "Bearer TOKVAL")
        XCTAssertNil(b.value(forHTTPHeaderField: "x-api-key"))
    }
}

final class FederatedAuthTests: XCTestCase {
    private let ids = AnthropicFederationIds(
        federationRuleId: "fdrl_test", organizationId: "org-test",
        serviceAccountId: "svac_test", workspaceId: "wrkspc_test")

    /// A 401 on the federated path must NOT say "Invalid API key." The user has
    /// no key; sending them to check one is the worst available advice.
    func test401WordingDependsOnCredentialKind() {
        let head = ResponseHead(status: 401)
        XCTAssertEqual(ClaudeError.from(head: head, message: nil, kind: .apiKey).kind, .invalidKey)
        XCTAssertEqual(ClaudeError.from(head: head, message: nil, kind: .federated).kind, .sessionRejected)
        let d = ClaudeError.from(head: head, message: nil, kind: .federated).errorDescription ?? ""
        XCTAssertFalse(d.lowercased().contains("api key"))
    }

    func testExchangeReturnsAFederatedCredential() async throws {
        let c = ClaudeClient(transport: MockTransport(dataHandler: { _ in
            (Data(#"{"access_token":"sk-ant-oat01-abc","expires_in":600,"scope":"workspace:inference"}"#.utf8),
             ResponseHead(status: 200))
        }))
        let minted = try await c.exchangeFederatedToken(assertion: "jwt", ids: ids)
        XCTAssertEqual(minted.credential.kind, .federated)
        XCTAssertEqual(minted.scope, "workspace:inference")
        XCTAssertTrue(minted.expiresAt > Date(), "expiry is absolute, computed from now")
        XCTAssertFalse("\(minted)".contains("sk-ant-oat01-abc"), "the token must not print")
    }

    /// The exchange carries the assertion as its own auth, so it must send no
    /// x-api-key and no Authorization header of its own.
    func testExchangeSendsNoAuthHeader() async throws {
        actor Seen { var req: URLRequest?; func set(_ r: URLRequest) { req = r } }
        let seen = Seen()
        let c = ClaudeClient(transport: MockTransport(dataHandler: { r in
            Task { await seen.set(r) }
            return (Data(#"{"access_token":"sk-ant-oat01-x","expires_in":600}"#.utf8), ResponseHead(status: 200))
        }))
        _ = try await c.exchangeFederatedToken(assertion: "jwt", ids: ids)
        try await Task.sleep(nanoseconds: 50_000_000)
        let r = await seen.req
        XCTAssertNil(r?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(r?.value(forHTTPHeaderField: "authorization"))
        XCTAssertEqual(r?.url?.host, "api.anthropic.com", "host pin still holds")
    }

    /// A refused assertion is its own case, so the UI can explain "you signed in
    /// fine, but access wasn't granted" rather than blaming the sign-in.
    func testRefusedExchangeIsNotAnApiKeyError() async {
        let c = ClaudeClient(transport: MockTransport(dataHandler: { _ in
            (Data(#"{"error":{"message":"Authentication failed"}}"#.utf8),
             ResponseHead(status: 401, headers: ["request-id": "req_zz"]))
        }))
        do {
            _ = try await c.exchangeFederatedToken(assertion: "jwt", ids: ids)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual((error as? ClaudeError)?.kind, .federationRefused)
            XCTAssertTrue(error.localizedDescription.contains("req_zz"))
        }
    }

    /// The local pre-flight case: signed in, but no app role. Must not imply the
    /// sign-in failed, and must not invite a retry.
    func testNotEntitledCopyBlamesAccessNotSignIn() {
        let d = ClaudeError.notEntitled(account: "someone@example.com").errorDescription ?? ""
        XCTAssertTrue(d.contains("signed in"))
        XCTAssertTrue(d.contains("someone@example.com"))
        XCTAssertTrue(d.lowercased().contains("ask it"))
        XCTAssertFalse(d.lowercased().contains("failed"))
    }
}
