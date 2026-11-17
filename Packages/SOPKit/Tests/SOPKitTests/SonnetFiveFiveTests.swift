import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// Sonnet 5.5 replaces Sonnet 5 (2026-11). Three things ride on that: saved settings
/// naming the retired model must not reset, the generation request asks for a
/// server-side fallback, and a stream the fallback continues must still parse.
final class SonnetFiveFiveTests: XCTestCase {

    // MARK: Saved settings survive the model being retired

    private func decode(_ json: String) throws -> SopSettings {
        try JSONDecoder().decode(SopSettings.self, from: Data(json.utf8))
    }

    /// Every saved settings file names "claude-sonnet-5", which this build no longer
    /// has. The synthesized decoder failed the whole struct on it and the app fell
    /// back to defaults — losing the user's tone, effort, enabled switch and custom
    /// instructions. Now only the model moves.
    func testSettingsSavedWithTheRetiredModelKeepEverythingElse() throws {
        let s = try decode(#"{"enabled":false,"model":"claude-sonnet-5","tone":"friendly","effort":"high","customInstructions":"Use our house style."}"#)
        XCTAssertEqual(s.model, .sonnet55, "moved to the new default")
        XCTAssertEqual(s.enabled, false)
        XCTAssertEqual(s.tone, .friendly)
        XCTAssertEqual(s.effort, .high)
        XCTAssertEqual(s.customInstructions, "Use our house style.")
    }

    func testAnyOneUnknownValueFallsBackAloneAndTheLengthCapHolds() throws {
        let long = String(repeating: "x", count: SOP_CUSTOM_INSTRUCTIONS_MAX + 500)
        let s = try decode(#"{"model":"claude-sonnet-5-5","tone":"pirate","effort":"ludicrous","customInstructions":"\#(long)"}"#)
        XCTAssertEqual(s.model, .sonnet55)
        XCTAssertEqual(s.tone, DEFAULT_SOP_TONE)
        XCTAssertEqual(s.effort, DEFAULT_SOP_EFFORT)
        XCTAssertEqual(s.enabled, true, "a missing key takes its default")
        XCTAssertEqual(s.customInstructions.count, SOP_CUSTOM_INSTRUCTIONS_MAX)
    }

    func testSettingsStillRoundTrip() throws {
        let s = SopSettings(enabled: false, model: .sonnet55, tone: .concise, effort: .low, customInstructions: "Short.")
        XCTAssertEqual(try JSONDecoder().decode(SopSettings.self, from: JSONEncoder().encode(s)), s)
    }

    // MARK: The request

    /// Records every request: body and headers.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var reqs: [URLRequest] = []
        func add(_ r: URLRequest) { lock.withLock { reqs.append(r) } }
        var all: [URLRequest] { lock.withLock { reqs } }
    }

    private let good = #"{"title":"A Real Title","intro":null,"steps":[{"stepNumber":1,"kind":"screenshot","caption":"Open Settings","body":"Click the gear.","sectionHeading":null,"sectionBody":null}]}"#

    private func generate(_ replies: [[String]], into rec: Recorder) async throws -> SopEditPlan {
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        let queue = SopValidationTests.Script(replies.map { ($0, ResponseHead(status: 200)) })
        var svc = SopService(
            client: ClaudeClient(transport: MockTransport(streamHandler: { req in rec.add(req); return queue.next(req) })),
            keyStore: StubKeyStore())
        svc.sleep = { _ in }
        return try await svc.generate(dir: dir, manifest: m, settings: SopSettings(), onProgress: { _ in })
    }

    func testTheGenerationRequestAsksSonnet55ForAServerSideFallback() async throws {
        let rec = Recorder()
        _ = try await generate([sseLines(json: good)], into: rec)
        let req = try XCTUnwrap(rec.all.first)
        let body = String(decoding: try XCTUnwrap(req.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"claude-sonnet-5-5""#))
        XCTAssertTrue(body.contains(#""fallbacks":"default""#))
        XCTAssertTrue(body.contains(#""max_tokens":64000"#))
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01",
                       "the parameter without its beta header is a 400 on every request")
    }

    /// The repair turn is built from the same body, so it asks for the fallback too.
    func testTheRepairRequestCarriesTheFallbackToo() async throws {
        let rec = Recorder()
        let filler = #"{"title":"A Real Title","intro":null,"steps":[{"stepNumber":1,"kind":"screenshot","caption":"Placeholder","body":"TBD","sectionHeading":null,"sectionBody":null}]}"#
        _ = try await generate([sseLines(json: filler), sseLines(json: good)], into: rec)
        XCTAssertEqual(rec.all.count, 2, "one repair turn")
        let repair = rec.all[1]
        XCTAssertTrue(String(decoding: repair.httpBody ?? Data(), as: UTF8.self).contains(#""fallbacks":"default""#))
        XCTAssertEqual(repair.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
    }

    /// Token counting is not a generation and takes no fallback: neither the
    /// parameter nor the header.
    func testTheEstimateRequestCarriesNoFallback() async throws {
        let rec = Recorder()
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        let svc = SopService(
            client: ClaudeClient(transport: MockTransport(dataHandler: { req in
                rec.add(req); return (Data(#"{"input_tokens":1000}"#.utf8), ResponseHead(status: 200))
            })),
            keyStore: StubKeyStore())
        _ = try await svc.estimate(dir: dir, manifest: m, settings: SopSettings())
        let req = try XCTUnwrap(rec.all.first)
        XCTAssertFalse(String(decoding: req.httpBody ?? Data(), as: UTF8.self).contains("fallbacks"))
        XCTAssertNil(req.value(forHTTPHeaderField: "anthropic-beta"))
    }

    // MARK: A stream the fallback model continues still parses

    private func event(_ json: String) -> String { "data: " + json }
    private func delta(_ index: Int, _ text: String) -> String {
        event(#"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":\#(jsonStringLiteral(text))}}"#)
    }

    private func stream(_ lines: [String]) async throws -> SopEditRaw {
        let c = ClaudeClient(transport: MockTransport(streamHandler: { _ in (lines, ResponseHead(status: 200)) }))
        return try await c.streamEditPlan(credential: .apiKey("sk-ant-test"), body: [:], onProgress: { _ in })
    }

    /// The documented shape of a mid-stream fallback: the declined model's partial
    /// text stays, a `fallback` content block marks the switch, and the fallback
    /// model's text continues after it on the same stream. Joined, the text is the
    /// whole plan.
    func testAMidStreamFallbackJoinsBothModelsTextIntoOnePlan() async throws {
        let cut = good.index(good.startIndex, offsetBy: 60)
        let lines = [
            event(#"{"type":"message_start","message":{"model":"claude-sonnet-5-5"}}"#),
            event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            delta(0, String(good[..<cut])),
            event(#"{"type":"content_block_stop","index":0}"#),
            event(#"{"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-sonnet-5-5"},"to":{"model":"claude-sonnet-5"}}}"#),
            event(#"{"type":"content_block_stop","index":1}"#),
            event(#"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}"#),
            delta(2, String(good[cut...])),
            event(#"{"type":"content_block_stop","index":2}"#),
            event(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
            event(#"{"type":"message_stop"}"#),
        ]
        let raw = try await stream(lines)
        XCTAssertEqual(raw.steps.first?.caption, "Open Settings")
    }

    /// A decline before any output is seamless: the stream opens on the fallback
    /// model, with the `fallback` block first.
    func testAPreOutputFallbackIsSeamless() async throws {
        let lines = [
            event(#"{"type":"message_start","message":{"model":"claude-sonnet-5"}}"#),
            event(#"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-sonnet-5-5"},"to":{"model":"claude-sonnet-5"}}}"#),
            event(#"{"type":"content_block_stop","index":0}"#),
            event(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            delta(1, good),
            event(#"{"type":"content_block_stop","index":1}"#),
            event(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
            event(#"{"type":"message_stop"}"#),
        ]
        let raw = try await stream(lines)
        XCTAssertEqual(raw.title, "A Real Title")
    }

    /// When every model in the chain declines, it is still a refusal.
    func testAChainThatDeclinesThroughoutIsStillARefusal() async throws {
        let lines = [
            event(#"{"type":"message_start","message":{"model":"claude-sonnet-5"}}"#),
            event(#"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-sonnet-5-5"},"to":{"model":"claude-sonnet-5"}}}"#),
            event(#"{"type":"content_block_stop","index":0}"#),
            event(#"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#),
            event(#"{"type":"message_stop"}"#),
        ]
        do { _ = try await stream(lines); XCTFail("must not succeed") }
        catch { XCTAssertEqual(error as? ClaudeError, .refusal) }
    }
}
