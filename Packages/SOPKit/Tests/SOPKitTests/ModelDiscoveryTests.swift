import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// Model discovery: reading Anthropic's model list, deciding what to offer, keeping
/// a chosen model across launches, and building requests for it without a code
/// change. The list entries below have the shape of the live response of
/// 2026-11-16 (`GET /v1/models` with the server-side-fallback beta).
final class ModelDiscoveryTests: XCTestCase {

    // MARK: Fixtures

    /// One entry in the live response's shape. Every capability shotAI needs is
    /// supported unless a test removes it.
    static func entry(
        _ id: String, line: String = "sonnet", created: String = "2026-09-28T00:00:00Z",
        lifecycle: String? = "active", retires: String? = nil, maxTokens: Int = 128000,
        maxInput: Int = 1_000_000, fallbacks: [String] = [], drop: Set<String> = [],
        displayName: String? = nil
    ) -> [String: Any] {
        var effort: [String: Any] = ["supported": true]
        for level in ["low", "medium", "high", "xhigh", "max"] where !drop.contains("effort.\(level)") {
            effort[level] = ["supported": true]
        }
        var caps: [String: Any] = [
            "batch": ["supported": true],
            "effort": effort,
            "image_input": ["supported": true],
            "pdf_input": ["supported": true],
            "structured_outputs": ["supported": true],
            "thinking": ["supported": true, "types": [
                "enabled": ["supported": false], "adaptive": ["supported": true],
                "disabled": ["supported": false], "between_tools": ["supported": true],
            ]],
        ]
        for key in drop where !key.hasPrefix("effort.") {
            if key == "adaptive" {
                caps["thinking"] = ["supported": true, "types": ["adaptive": ["supported": false]]]
            } else {
                caps.removeValue(forKey: key)
            }
        }
        var e: [String: Any] = [
            "type": "model", "id": id, "display_name": displayName ?? id, "created_at": created,
            "line": line, "max_input_tokens": maxInput, "max_tokens": maxTokens,
            "capabilities": caps, "deprecated_at": NSNull(),
            "retires_at": retires.map { $0 as Any } ?? NSNull(),
            "allowed_fallback_models": fallbacks,
        ]
        e["lifecycle"] = lifecycle.map { $0 as Any } ?? nil
        return e
    }

    static func page(_ entries: [[String: Any]], hasMore: Bool = false, lastId: String? = nil) -> Data {
        let obj: [String: Any] = [
            "data": entries, "has_more": hasMore,
            "first_id": (entries.first?["id"] as? String).map { $0 as Any } ?? NSNull(),
            "last_id": (lastId ?? entries.last?["id"] as? String).map { $0 as Any } ?? NSNull(),
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    static func listed(_ entries: [[String: Any]]) throws -> [ListedModel] {
        try ModelList.parsePage(page(entries)).models
    }

    /// The account's list as of 2026-11-16, Sonnets plus one of each other line.
    static var today: [[String: Any]] { [
        entry("claude-fable-5-2", line: "fable", created: "2026-11-09T18:30:00Z", fallbacks: ["claude-opus-5"]),
        entry("claude-sonnet-5-5", created: "2026-09-28T00:00:00Z", fallbacks: ["claude-sonnet-5"],
              displayName: "Claude Sonnet 5.5"),
        entry("claude-opus-5-5", line: "opus", created: "2026-09-21T16:24:00Z"),
        entry("claude-sonnet-5", created: "2026-06-29T00:00:00Z"),
        entry("claude-sonnet-4-5-20250929", created: "2025-09-29T00:00:00Z", lifecycle: "deprecated",
              retires: "2026-11-30T17:00:00Z", maxTokens: 64000, maxInput: 200_000),
    ] }

    static var sonnet6: [String: Any] {
        entry("claude-sonnet-6", created: "2027-03-01T00:00:00Z", fallbacks: ["claude-sonnet-5-5"],
              displayName: "Claude Sonnet 6")
    }

    // MARK: Parsing the list

    /// Two entries exactly as the live API returned them on 2026-11-16, so the
    /// synthetic `entry` helper cannot drift from the real shape unnoticed.
    static let liveResponse = #"{"data":[{"type":"model","id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5","created_at":"2026-09-28T00:00:00Z","line":"sonnet","max_input_tokens":1000000,"max_tokens":128000,"capabilities":{"batch":{"supported":true},"citations":{"supported":true},"code_execution":{"supported":true},"context_management":{"supported":true,"clear_tool_uses_20250919":{"supported":true},"clear_thinking_20251015":{"supported":true},"compact_20260112":{"supported":true}},"effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":true},"max":{"supported":true}},"image_input":{"supported":true},"pdf_input":{"supported":true},"server_tools":{"supported":true,"code_execution":{"supported":true},"web_search":{"supported":true}},"structured_outputs":{"supported":true},"thinking":{"supported":true,"types":{"enabled":{"supported":false},"adaptive":{"supported":true},"disabled":{"supported":false},"between_tools":{"supported":true}}}},"lifecycle":"active","deprecated_at":null,"retires_at":null,"allowed_fallback_models":["claude-sonnet-5"]},{"type":"model","id":"claude-sonnet-4-5-20250929","display_name":"Claude Sonnet 4.5","created_at":"2025-09-29T00:00:00Z","line":"sonnet","max_input_tokens":200000,"max_tokens":64000,"capabilities":{"batch":{"supported":true},"citations":{"supported":true},"code_execution":{"supported":true},"context_management":{"supported":true,"clear_tool_uses_20250919":{"supported":true},"clear_thinking_20251015":{"supported":true},"compact_20260112":{"supported":false}},"effort":{"supported":false,"low":{"supported":false},"medium":{"supported":false},"high":{"supported":false},"xhigh":{"supported":false},"max":{"supported":false}},"image_input":{"supported":true},"pdf_input":{"supported":true},"server_tools":{"supported":true,"code_execution":{"supported":true},"web_search":{"supported":true}},"structured_outputs":{"supported":true},"thinking":{"supported":true,"types":{"enabled":{"supported":true},"adaptive":{"supported":false},"disabled":{"supported":true},"between_tools":{"supported":false}}}},"lifecycle":"deprecated","deprecated_at":"2026-09-30T18:30:00Z","retires_at":"2026-11-30T17:00:00Z","allowed_fallback_models":[]}],"has_more":false,"first_id":"claude-sonnet-5-5","last_id":"claude-sonnet-4-5-20250929"}"#

    func testTheLiveResponseParses() throws {
        let models = try ModelList.parsePage(Data(Self.liveResponse.utf8)).models
        XCTAssertEqual(models.map(\.id), ["claude-sonnet-5-5", "claude-sonnet-4-5-20250929"])
        let s55 = models[0], s45 = models[1]
        XCTAssertEqual(s55.sopGaps, [])
        XCTAssertEqual(s55.effortLevels, ["high", "low", "max", "medium", "xhigh"])
        XCTAssertEqual(s55.fallbackModels, ["claude-sonnet-5"])
        XCTAssertEqual(s55.maxOutputTokens, 128000)
        XCTAssertEqual(s55.maxInputTokens, 1_000_000)
        XCTAssertEqual(s55.createdAt, ISO8601DateFormatter().date(from: "2026-09-28T00:00:00Z"))
        XCTAssertTrue(s55.isActive)
        XCTAssertFalse(s55.isRetiring)
        // The real deprecated Sonnet 4.5: no effort, no adaptive thinking, a retirement date.
        XCTAssertEqual(s45.sopGaps, ["adaptive thinking", "low effort", "medium effort", "high effort"])
        XCTAssertTrue(s45.isRetiring)
        XCTAssertEqual(s45.retiresAt, ISO8601DateFormatter().date(from: "2026-11-30T17:00:00Z"))
        XCTAssertNil(modelOffer(listed: models, complete: true, current: .sonnet55),
                     "an older, retiring Sonnet is never an offer")
    }

    func testTheListAsItIsTodayParses() throws {
        let models = try Self.listed(Self.today)
        XCTAssertEqual(models.count, 5)
        let s55 = try XCTUnwrap(models.first { $0.id == "claude-sonnet-5-5" })
        XCTAssertEqual(s55.sopGaps, [], "the built-in default must pass the check it is held to")
        XCTAssertEqual(s55.line, "sonnet")
        XCTAssertEqual(s55.displayName, "Claude Sonnet 5.5")
        XCTAssertEqual(s55.profile.maxOutputTokens, 128000)
        XCTAssertEqual(s55.profile.fallbackModels, ["claude-sonnet-5"])
        XCTAssertNotNil(s55.createdAt)
        XCTAssertFalse(s55.isRetiring)

        let old = try XCTUnwrap(models.first { $0.id == "claude-sonnet-4-5-20250929" })
        XCTAssertTrue(old.isRetiring)
        XCTAssertNotNil(old.retiresAt)
    }

    /// Each capability the generation request depends on, removed one at a time,
    /// is named as a gap — and so keeps the model from being offered.
    func testEachMissingCapabilityIsAGap() throws {
        let cases: [(String, [String: Any])] = [
            ("image input", Self.entry("m", drop: ["image_input"])),
            ("structured output", Self.entry("m", drop: ["structured_outputs"])),
            ("adaptive thinking", Self.entry("m", drop: ["adaptive"])),
            ("low effort", Self.entry("m", drop: ["effort.low"])),
            ("medium effort", Self.entry("m", drop: ["effort.medium"])),
            ("high effort", Self.entry("m", drop: ["effort.high"])),
            ("output length", Self.entry("m", maxTokens: 16000)),
            ("context length", Self.entry("m", maxInput: 100_000)),
        ]
        for (gap, e) in cases {
            let m = try XCTUnwrap(try Self.listed([e]).first)
            XCTAssertEqual(m.sopGaps, [gap], gap)
        }
        // Effort as a whole unsupported: every level is missing, whatever it lists.
        var noEffort = Self.entry("m")
        var caps = noEffort["capabilities"] as! [String: Any]
        var effort = caps["effort"] as! [String: Any]
        effort["supported"] = false
        caps["effort"] = effort
        noEffort["capabilities"] = caps
        XCTAssertEqual(try Self.listed([noEffort]).first?.sopGaps, ["low effort", "medium effort", "high effort"])
    }

    /// An id from the network reaches a URL path and request bodies, so anything
    /// outside the id alphabet is dropped at parse time.
    func testIdsOutsideTheModelIdShapeAreDropped() throws {
        for bad in ["../v1/files", "claude/sonnet", "Claude-Sonnet", "a b", "x?y=1", "", "-x", "9x",
                    "claude-..-x", String(repeating: "a", count: 101), "claude-sönnet"] {
            XCTAssertFalse(isValidModelId(bad), bad)
            XCTAssertEqual(try Self.listed([Self.entry(bad)]).count, 0, bad)
        }
        for good in ["claude-sonnet-5-5", "claude-haiku-4-5-20251001", "claude-2.1"] {
            XCTAssertTrue(isValidModelId(good), good)
        }
    }

    func testTheDisplayNameIsCleanedBeforeTheUIShowsIt() throws {
        let noisy = try Self.listed([Self.entry("claude-sonnet-6", displayName: "  Claude\u{0007} Sonnet\n6  ")])
        XCTAssertEqual(noisy.first?.displayName, "Claude Sonnet6")
        let blank = try Self.listed([Self.entry("claude-sonnet-6", displayName: " \n ")])
        XCTAssertEqual(blank.first?.displayName, "claude-sonnet-6", "an empty name falls back to the id")
        let long = try Self.listed([Self.entry("claude-sonnet-6", displayName: String(repeating: "x", count: 500))])
        XCTAssertEqual(long.first?.displayName.count, 60)
    }

    func testAPageThatIsNotAModelListIsMalformed() {
        XCTAssertThrowsError(try ModelList.parsePage(Data(#"{"error":"nope"}"#.utf8))) {
            XCTAssertEqual($0 as? ClaudeError, .malformed)
        }
        XCTAssertThrowsError(try ModelList.parsePage(Data("not json".utf8)))
    }

    // MARK: What is offered

    private func offer(_ entries: [[String: Any]], current: SopModelId = .sonnet55,
                       complete: Bool = true) throws -> ModelOffer? {
        modelOffer(listed: try Self.listed(entries), complete: complete, current: current)
    }

    func testNothingIsOfferedWhenTheModelInUseIsTheNewestSonnet() throws {
        XCTAssertNil(try offer(Self.today), "newer Fable and Opus models are a different line")
    }

    func testANewerCompatibleSonnetIsOffered() throws {
        let o = try XCTUnwrap(try offer(Self.today + [Self.sonnet6]))
        XCTAssertEqual(o.reason, .newer)
        XCTAssertEqual(o.candidate?.id, "claude-sonnet-6")
        XCTAssertEqual(o.candidate?.displayName, "Claude Sonnet 6")
        XCTAssertEqual(o.current, .sonnet55)
    }

    func testOnlyTheNewestOfSeveralIsOffered() throws {
        let s61 = Self.entry("claude-sonnet-6-1", created: "2027-06-01T00:00:00Z")
        XCTAssertEqual(try offer(Self.today + [Self.sonnet6, s61])?.candidate?.id, "claude-sonnet-6-1")
    }

    func testANewerSonnetMissingSomethingTheRequestUsesIsNotOffered() throws {
        let noThinking = Self.entry("claude-sonnet-6", created: "2027-03-01T00:00:00Z", drop: ["adaptive"])
        XCTAssertNil(try offer(Self.today + [noThinking]))
    }

    func testANewerSonnetThatIsAlreadyDeprecatedIsNotOffered() throws {
        let dep = Self.entry("claude-sonnet-6", created: "2027-03-01T00:00:00Z", lifecycle: "deprecated")
        XCTAssertNil(try offer(Self.today + [dep]))
        let dated = Self.entry("claude-sonnet-6", created: "2027-03-01T00:00:00Z", retires: "2027-04-01T00:00:00Z")
        XCTAssertNil(try offer(Self.today + [dated]))
    }

    /// Without both release dates nothing says which is newer, and an offer that
    /// could be a downgrade is worse than none.
    func testNewerNeedsBothDates() throws {
        let undated = Self.entry("claude-sonnet-6", created: "not a date")
        XCTAssertNil(try offer(Self.today + [undated]))
        var today = Self.today
        today[1] = Self.entry("claude-sonnet-5-5", created: "")
        XCTAssertNil(try offer(today + [Self.sonnet6]))
    }

    /// The newest model shotAI could switch to is not always newer than the one in
    /// use: here the model in use does not pass the capability check itself, so the
    /// best candidate is older. That is a downgrade, never a "newer" offer.
    func testAnOlderCandidateIsNeverOfferedAsNewer() throws {
        let mine = Self.entry("claude-sonnet-6", created: "2027-03-01T00:00:00Z", drop: ["structured_outputs"])
        XCTAssertNil(try offer(Self.today + [mine], current: SopModelId(rawValue: "claude-sonnet-6")))
    }

    func testARetiringModelInUseIsFlaggedWithItsDateAndAReplacement() throws {
        let o = try XCTUnwrap(try offer(Self.today, current: SopModelId(rawValue: "claude-sonnet-4-5-20250929")))
        guard case .retiring(let date) = o.reason else { return XCTFail("\(o.reason)") }
        XCTAssertNotNil(date)
        XCTAssertEqual(o.candidate?.id, "claude-sonnet-5-5", "the newest usable Sonnet, not the retiring one")
    }

    func testARetiringModelWithNoReplacementIsStillFlagged() throws {
        let only = [Self.entry("claude-sonnet-5-5", lifecycle: "deprecated")]
        let o = try XCTUnwrap(try offer(only))
        XCTAssertEqual(o.reason, .retiring(retiresAt: nil))
        XCTAssertNil(o.candidate)
    }

    /// Only a listing that covered every page can say the model is missing from it.
    func testAMissingModelIsReportedOnlyFromACompleteListing() throws {
        let withoutMine = Self.today.filter { ($0["id"] as? String) != "claude-sonnet-5-5" }
        let o = try XCTUnwrap(try offer(withoutMine))
        XCTAssertEqual(o.reason, .unavailable)
        XCTAssertEqual(o.candidate?.id, "claude-sonnet-5", "the newest usable Sonnet left")
        XCTAssertNil(try offer(withoutMine, complete: false))
    }

    func testAnEmptyListingSaysNothing() throws {
        XCTAssertNil(modelOffer(listed: [], complete: true, current: .sonnet55))
    }

    func testNotNowHidesThatOfferButNotTheNextOne() throws {
        var state = ModelDiscoveryState()
        let first = try XCTUnwrap(try offer(Self.today + [Self.sonnet6]))
        state.dismiss(first)
        XCTAssertTrue(state.isDismissed(first))
        let s61 = Self.entry("claude-sonnet-6-1", created: "2027-06-01T00:00:00Z")
        let next = try XCTUnwrap(try offer(Self.today + [Self.sonnet6, s61]))
        XCTAssertFalse(state.isDismissed(next), "a newer model is news again")

        let missing = try XCTUnwrap(try offer(Self.today.filter { ($0["id"] as? String) != "claude-sonnet-5-5" }))
        state.dismiss(missing)
        XCTAssertFalse(state.isDismissed(missing), "an unavailable model is not dismissible: generation would fail")
    }

    // MARK: The chosen model across launches

    private let sonnet6Profile = SopModelProfile(
        id: "claude-sonnet-6", displayName: "Claude Sonnet 6", maxOutputTokens: 128000,
        fallbackModels: ["claude-sonnet-5-5"])

    private func decode(_ json: String) throws -> SopSettings {
        try JSONDecoder().decode(SopSettings.self, from: Data(json.utf8))
    }

    func testAChosenModelSurvivesARelaunch() throws {
        var s = SopSettings(tone: .concise)
        s.selectModel(sonnet6Profile)
        XCTAssertEqual(s.model.rawValue, "claude-sonnet-6")
        XCTAssertEqual(s.discoveredModel, sonnet6Profile)
        let back = try JSONDecoder().decode(SopSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testAnUnknownIdWithoutItsProfileFallsBackToTheDefault() throws {
        let s = try decode(#"{"model":"claude-sonnet-6","tone":"friendly"}"#)
        XCTAssertEqual(s.model, DEFAULT_SOP_MODEL)
        XCTAssertNil(s.discoveredModel)
        XCTAssertEqual(s.tone, .friendly, "everything else is kept")
    }

    func testAProfileForADifferentModelIsDropped() throws {
        let s = try decode(#"{"model":"claude-sonnet-6","discoveredModel":{"id":"claude-sonnet-7","displayName":"x","maxOutputTokens":128000,"fallbackModels":[]}}"#)
        XCTAssertEqual(s.model, DEFAULT_SOP_MODEL)
        XCTAssertNil(s.discoveredModel)
    }

    func testAnUnusableProfileFallsBackToTheDefault() throws {
        for profile in [
            #"{"id":"claude-sonnet-6","displayName":"x","maxOutputTokens":1000,"fallbackModels":[]}"#,
            #"{"id":"../claude-sonnet-6","displayName":"x","maxOutputTokens":128000,"fallbackModels":[]}"#,
            #"{"id":"claude-sonnet-6"}"#,
            #""claude-sonnet-6""#,
        ] {
            let id = profile.contains("../") ? "../claude-sonnet-6" : "claude-sonnet-6"
            let s = try decode(#"{"model":"\#(id)","discoveredModel":\#(profile)}"#)
            XCTAssertEqual(s.model, DEFAULT_SOP_MODEL, profile)
            XCTAssertNil(s.discoveredModel, profile)
        }
    }

    func testABuiltInModelDropsAStaleProfile() throws {
        let s = try decode(#"{"model":"claude-sonnet-5-5","discoveredModel":{"id":"claude-sonnet-6","displayName":"x","maxOutputTokens":128000,"fallbackModels":[]}}"#)
        XCTAssertEqual(s.model, .sonnet55)
        XCTAssertNil(s.discoveredModel)
    }

    /// A model a later build knows in code is taken as built in, so its known
    /// price and request shape win over the profile captured from the list.
    func testChoosingAModelThisBuildKnowsTakesTheBuiltIn() {
        var s = SopSettings()
        s.selectModel(SopModelProfile(id: "claude-sonnet-5-5", displayName: "x", maxOutputTokens: 128000))
        XCTAssertEqual(s.model, .sonnet55)
        XCTAssertNil(s.discoveredModel)
    }

    func testSettingsCannotBeBuiltAroundAnIdWithoutAProfile() {
        XCTAssertEqual(SopSettings(model: SopModelId(rawValue: "claude-made-up")).model, DEFAULT_SOP_MODEL)
        var s = SopSettings()
        s.selectModel(SopModelId(rawValue: "claude-made-up"))
        XCTAssertEqual(s.model, DEFAULT_SOP_MODEL)
    }

    // MARK: Requests for a chosen model

    private func generate(with profile: SopModelProfile, into rec: SonnetFiveFiveTests.Recorder) async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        let good = #"{"title":"A Real Title","intro":null,"steps":[{"stepNumber":1,"kind":"screenshot","caption":"Open Settings","body":"Click the gear.","sectionHeading":null,"sectionBody":null}]}"#
        var svc = SopService(
            client: ClaudeClient(transport: MockTransport(streamHandler: { req in
                rec.add(req); return (sseLines(json: good), ResponseHead(status: 200))
            })),
            keyStore: StubKeyStore())
        svc.sleep = { _ in }
        var settings = SopSettings()
        settings.selectModel(profile)
        _ = try await svc.generate(dir: dir, manifest: m, settings: settings, onProgress: { _ in })
    }

    private func body(_ req: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
    }

    func testAChosenModelIsAskedForWithTheSameRequestShape() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        try await generate(with: sonnet6Profile, into: rec)
        let req = try XCTUnwrap(rec.all.first)
        let b = try body(req)
        XCTAssertEqual(b["model"] as? String, "claude-sonnet-6")
        XCTAssertEqual(b["max_tokens"] as? Int, SOP_GENERATION_MAX_TOKENS, "capped at what shotAI asks of any model")
        XCTAssertEqual((b["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual((b["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual(b["fallbacks"] as? String, "default", "the list names a fallback for it")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), SopService.fallbackBeta)
    }

    func testAChosenModelWithNoFallbackIsNotAskedForOne() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        try await generate(with: SopModelProfile(id: "claude-sonnet-6", displayName: "S6", maxOutputTokens: 128000),
                           into: rec)
        let req = try XCTUnwrap(rec.all.first)
        XCTAssertNil(try body(req)["fallbacks"])
        XCTAssertNil(req.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testAChosenModelWithALowerCeilingIsAskedForNoMoreThanItAllows() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        try await generate(with: SopModelProfile(id: "claude-sonnet-6", displayName: "S6", maxOutputTokens: 48000),
                           into: rec)
        XCTAssertEqual(try body(try XCTUnwrap(rec.all.first))["max_tokens"] as? Int, 48000)
    }

    /// The Models API publishes no prices; the estimate gives tokens and no figure.
    func testTheEstimateForAChosenModelHasNoPrice() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        let rec = SonnetFiveFiveTests.Recorder()
        let svc = SopService(
            client: ClaudeClient(transport: MockTransport(dataHandler: { req in
                rec.add(req); return (Data(#"{"input_tokens":1234}"#.utf8), ResponseHead(status: 200))
            })),
            keyStore: StubKeyStore())
        var settings = SopSettings()
        settings.selectModel(sonnet6Profile)
        let est = try await svc.estimate(dir: dir, manifest: m, settings: settings)
        XCTAssertEqual(est.inputTokens, 1234)
        XCTAssertNil(est.estCostUsd)
        XCTAssertEqual(est.model.rawValue, "claude-sonnet-6")
        XCTAssertEqual(try body(try XCTUnwrap(rec.all.first))["model"] as? String, "claude-sonnet-6",
                       "tokens are counted for the model that will be used")
    }

    // MARK: When the failure alert offers another model

    func testOnlyFailuresAnotherModelCouldAvoidOfferOne() {
        let f = ApiFailure(message: nil, requestId: nil)
        for builtIn in [true, false] {
            XCTAssertTrue(ClaudeError.modelUnavailable(f).isModelFault(builtInModel: builtIn))
            XCTAssertTrue(ClaudeError.permissionDenied(f).isModelFault(builtInModel: builtIn))
            for other: ClaudeError in [.overloaded, .connection, .refusal, .cutoff, .malformed, .noContent,
                                       .rateLimited(f), .billing(f), .invalidKey(f), .sessionRejected(f),
                                       .incomplete(wroteNothing: true), .api(status: 500, failure: f)] {
                XCTAssertFalse(other.isModelFault(builtInModel: builtIn), "\(other.kind)")
            }
        }
        XCTAssertTrue(ClaudeError.api(status: 400, failure: f).isModelFault(builtInModel: false),
                      "a model from the list may not accept a request shaped like shotAI's")
        XCTAssertFalse(ClaudeError.api(status: 400, failure: f).isModelFault(builtInModel: true),
                       "the built-in request shape is known good; a 400 there is the project's")
    }

    func testTheRequestModelIsTheResolvedOne() {
        var s = SopSettings()
        XCTAssertEqual(SopService.requestModel(s), .sonnet55)
        s.selectModel(sonnet6Profile)
        XCTAssertEqual(SopService.requestModel(s).rawValue, "claude-sonnet-6")
    }

    // MARK: Fetching the list

    private func client(_ pages: @escaping @Sendable (URLRequest) -> (Data, ResponseHead),
                        into rec: SonnetFiveFiveTests.Recorder) -> ClaudeClient {
        ClaudeClient(transport: MockTransport(dataHandler: { req in rec.add(req); return pages(req) }))
    }

    private func query(_ req: URLRequest) -> [String: String] {
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testTheListIsFetchedPageByPageWithTheFallbackBeta() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        let c = client({ req in
            let after = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "after_id" }?.value
            return after == nil
                ? (Self.page([Self.today[0], Self.today[1]], hasMore: true), ResponseHead(status: 200))
                : (Self.page([Self.today[2]]), ResponseHead(status: 200))
        }, into: rec)
        let result = try await c.listModels(credential: .apiKey("sk-ant-test"))
        XCTAssertEqual(result.models.map(\.id), ["claude-fable-5-2", "claude-sonnet-5-5", "claude-opus-5-5"])
        XCTAssertTrue(result.complete)
        XCTAssertEqual(rec.all.count, 2)
        for req in rec.all {
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertEqual(req.url?.host, "api.anthropic.com")
            XCTAssertEqual(req.url?.path, "/v1/models")
            XCTAssertEqual(query(req)["limit"], "100")
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), SopService.fallbackBeta,
                           "without it the entries carry no allowed_fallback_models")
        }
        XCTAssertNil(query(rec.all[0])["after_id"])
        XCTAssertEqual(query(rec.all[1])["after_id"], "claude-sonnet-5-5")
    }

    func testAListingThatNeverEndsStopsAtThePageCapAsIncomplete() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        let c = client({ _ in
            (Self.page([Self.entry("claude-sonnet-x-\(UUID().uuidString.prefix(8).lowercased())")], hasMore: true),
             ResponseHead(status: 200))
        }, into: rec)
        let result = try await c.listModels(credential: .apiKey("sk-ant-test"))
        XCTAssertEqual(rec.all.count, ClaudeClient.maxModelPages)
        XCTAssertFalse(result.complete)
    }

    func testACursorThatDoesNotMoveEndsTheListingAsIncomplete() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        let c = client({ _ in (Self.page([Self.today[1]], hasMore: true, lastId: "stuck"), ResponseHead(status: 200)) },
                       into: rec)
        let result = try await c.listModels(credential: .apiKey("sk-ant-test"))
        XCTAssertEqual(rec.all.count, 2, "the second page repeats the cursor; nothing more is asked")
        XCTAssertFalse(result.complete)
    }

    func testAFailedListingIsClassifiedLikeAnyOtherCall() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        let denied = client({ _ in (Data(#"{"error":{"message":"bad key"}}"#.utf8), ResponseHead(status: 401)) }, into: rec)
        do { _ = try await denied.listModels(credential: .apiKey("sk-ant-test")); XCTFail("expected throw") }
        catch { XCTAssertEqual((error as? ClaudeError)?.kind, .invalidKey) }

        let garbled = client({ _ in (Data("<html>".utf8), ResponseHead(status: 200)) }, into: rec)
        do { _ = try await garbled.listModels(credential: .apiKey("sk-ant-test")); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? ClaudeError, .malformed) }
    }

    func testNothingIsListedWhileAIIsOff() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        let svc = SopService(client: client({ _ in (Self.page(Self.today), ResponseHead(status: 200)) }, into: rec),
                             keyStore: StubKeyStore())
        do { _ = try await svc.listModels(settings: SopSettings(enabled: false)); XCTFail("expected throw") }
        catch { XCTAssertEqual(error as? ClaudeError, .disabled) }
        XCTAssertEqual(rec.all.count, 0, "off means nothing goes over the network")
    }

    // MARK: Once a day

    func testTheCheckRunsOnceADayAndSoonerAfterAFailure() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var s = ModelDiscoveryState()
        XCTAssertTrue(s.isDue(at: t0), "never checked")

        s.recordSuccess(try Self.listed(Self.today), complete: true, at: t0)
        XCTAssertFalse(s.isDue(at: t0.addingTimeInterval(23 * 3600)))
        XCTAssertTrue(s.isDue(at: t0.addingTimeInterval(24 * 3600)))

        s.recordFailure(at: t0.addingTimeInterval(24 * 3600))
        XCTAssertEqual(s.listed.count, 5, "a failed check keeps what the last one found")
        XCTAssertFalse(s.isDue(at: t0.addingTimeInterval(29 * 3600)))
        XCTAssertTrue(s.isDue(at: t0.addingTimeInterval(30 * 3600)))
    }

    func testAClockThatMovedBackwardsDoesNotSilenceTheCheck() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var s = ModelDiscoveryState()
        s.recordSuccess([], complete: true, at: t0)
        XCTAssertTrue(s.isDue(at: t0.addingTimeInterval(-90 * 86400)))
    }

    func testAStoredStateThisBuildCannotReadStartsFresh() throws {
        let s = try JSONDecoder().decode(ModelDiscoveryState.self,
                                         from: Data(#"{"listed":"nope","complete":3,"dismissed":[1]}"#.utf8))
        XCTAssertEqual(s, ModelDiscoveryState())
        var full = ModelDiscoveryState()
        full.recordSuccess(try Self.listed(Self.today), complete: true, at: Date(timeIntervalSince1970: 1_800_000_000))
        full.dismissed = ["newer:claude-sonnet-6"]
        XCTAssertEqual(try JSONDecoder().decode(ModelDiscoveryState.self, from: JSONEncoder().encode(full)), full)
    }
}
