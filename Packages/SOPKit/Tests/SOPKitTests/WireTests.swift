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
        let json = #"{"title":"T","intro":{"heading":"H","body":"B"},"steps":[{"stepNumber":1,"caption":"C","body":"Bd","note":null,"sectionHeading":"S","sectionBody":"SB"}]}"#
        let raw = try JSONDecoder().decode(SopEditRaw.self, from: Data(json.utf8))
        XCTAssertEqual(raw.title, "T")
        XCTAssertEqual(raw.intro?.heading, "H")
        XCTAssertEqual(raw.steps.first?.stepNumber, 1)
        XCTAssertNil(raw.steps.first?.note)
        XCTAssertEqual(raw.steps.first?.sectionHeading, "S")
    }
}

final class ClaudeClientTests: XCTestCase {
    func testCheckModelOkAndError() async throws {
        let ok = ClaudeClient(transport: MockTransport(dataHandler: { _ in (Data("{}".utf8), 200) }))
        try await ok.checkModel(apiKey: "k", model: .sonnet5)  // no throw

        let bad = ClaudeClient(transport: MockTransport(dataHandler: { _ in
            (Data(#"{"error":{"message":"nope"}}"#.utf8), 401)
        }))
        do { try await bad.checkModel(apiKey: "k", model: .sonnet5); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? ClaudeError, .invalidKey) }
    }

    func testCountTokens() async throws {
        let c = ClaudeClient(transport: MockTransport(dataHandler: { _ in
            (Data(#"{"input_tokens":1234}"#.utf8), 200)
        }))
        let n = try await c.countTokens(apiKey: "k", model: .sonnet5, system: [], messages: [])
        XCTAssertEqual(n, 1234)

        let limited = ClaudeClient(transport: MockTransport(dataHandler: { _ in (Data("{}".utf8), 429) }))
        do { _ = try await limited.countTokens(apiKey: "k", model: .sonnet5, system: [], messages: []); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .rateLimited) }
    }

    func testStreamDecodesPlan() async throws {
        let json = #"{"title":"My SOP","intro":null,"steps":[{"stepNumber":1,"caption":"Open menu","body":"Click it","note":null,"sectionHeading":null,"sectionBody":null}]}"#
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: json), 200) }))
        let raw = try await c.streamEditPlan(apiKey: "k", body: [:], onProgress: { _ in })
        XCTAssertEqual(raw.title, "My SOP")
        XCTAssertEqual(raw.steps.count, 1)
        XCTAssertEqual(raw.steps[0].caption, "Open menu")
    }

    func testStreamReassemblesChunkedJSONWithThinkingAndPings() async throws {
        // The structured-output JSON arrives split across many text_deltas, after
        // thinking blocks, interleaved with ping/keepalive events. Reassembly must
        // be lossless and decode to the full plan.
        let json = #"{"title":"My SOP","intro":{"heading":"Overview","body":"Do it"},"steps":[{"stepNumber":1,"caption":"Open menu","body":"Click the menu","note":null,"sectionHeading":null,"sectionBody":null},{"stepNumber":2,"caption":"Save","body":"Click Save","note":"careful","sectionHeading":null,"sectionBody":null}]}"#
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
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (sse, 200) }))
        let raw = try await c.streamEditPlan(apiKey: "k", body: [:], onProgress: { _ in })
        XCTAssertEqual(raw.title, "My SOP")
        XCTAssertEqual(raw.intro?.heading, "Overview")
        XCTAssertEqual(raw.steps.map(\.stepNumber), [1, 2])
        XCTAssertEqual(raw.steps[1].note, "careful")
    }

    func testStreamRefusal() async {
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: "{}", stopReason: "refusal"), 200) }))
        do { _ = try await c.streamEditPlan(apiKey: "k", body: [:], onProgress: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .refusal) }
    }

    func testStreamCutoffOnTruncatedMaxTokens() async {
        // A truncated (invalid) JSON body with stop_reason max_tokens → cutoff.
        let lines = sseLines(json: #"{"title":"x","steps":["#, stopReason: "max_tokens")
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (lines, 200) }))
        do { _ = try await c.streamEditPlan(apiKey: "k", body: [:], onProgress: { _ in }); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .cutoff) }
    }

    func testStreamHttpError() async {
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in
            ([#"data: {"error":{"message":"boom"}}"#], 500)
        }))
        do { _ = try await c.streamEditPlan(apiKey: "k", body: [:], onProgress: { _ in }); XCTFail() }
        catch {
            guard case .api(let status, _)? = error as? ClaudeError else { return XCTFail("wrong: \(error)") }
            XCTAssertEqual(status, 500)
        }
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
            client: ClaudeClient(transport: MockTransport(dataHandler: { _ in (Data(#"{"input_tokens":1000000}"#.utf8), 200) })),
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
            client: ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: empty), 200) })),
            keyStore: StubKeyStore())
        do { _ = try await svc1.generate(dir: dir, manifest: m, settings: SopSettings()); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .incomplete) }

        // Steps present but all blank → also incomplete.
        let blank = #"{"title":"T","intro":null,"steps":[{"stepNumber":1,"caption":"  ","body":"","note":null,"sectionHeading":null,"sectionBody":null}]}"#
        let svc2 = SopService(
            client: ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: blank), 200) })),
            keyStore: StubKeyStore())
        do { _ = try await svc2.generate(dir: dir, manifest: m, settings: SopSettings()); XCTFail() }
        catch { XCTAssertEqual(error as? ClaudeError, .incomplete) }

        // A real edit passes.
        let good = #"{"title":"T","intro":null,"steps":[{"stepNumber":1,"caption":"Do it","body":"Click","note":null,"sectionHeading":null,"sectionBody":null}]}"#
        let svc3 = SopService(
            client: ClaudeClient(transport: MockTransport(streamHandler: { _ in (sseLines(json: good), 200) })),
            keyStore: StubKeyStore())
        let plan = try await svc3.generate(dir: dir, manifest: m, settings: SopSettings())
        XCTAssertEqual(plan.steps.first?.caption, "Do it")
    }
}
