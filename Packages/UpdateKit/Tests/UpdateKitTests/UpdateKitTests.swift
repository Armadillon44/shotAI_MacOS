import Foundation
import Testing

@testable import UpdateKit

// MARK: - Helpers

/// Canned transport: replays a scripted (status, body, headers) response, or
/// throws. Records how many requests were actually made so a test can prove the
/// throttle prevented one.
final class FakeTransport: UpdateFeedTransport, @unchecked Sendable {
    enum Script: Sendable {
        case ok(String)
        case status(Int, headers: [String: String] = [:])
        case failure(UpdateFeedError)
    }

    private let lock = NSLock()
    private var script: Script
    private var _calls = 0
    private var _lastRequest: URLRequest?
    /// Held open so a test can act (e.g. skip a version) while a check is parked
    /// on the network await — the actor-reentrancy window.
    private var _delay: Duration = .zero
    var calls: Int { lock.withLock { _calls } }
    /// The request as it actually went out — headers included.
    var lastRequest: URLRequest? { lock.withLock { _lastRequest } }

    init(_ script: Script, delay: Duration = .zero) {
        self.script = script
        self._delay = delay
    }

    func set(_ s: Script) { lock.withLock { script = s } }

    func get(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (s, delay): (Script, Duration) = lock.withLock {
            _calls += 1
            _lastRequest = request
            return (script, _delay)
        }
        if delay > .zero { try? await Task.sleep(for: delay) }
        let url = request.url!
        switch s {
        case .ok(let body):
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
            return (Data(body.utf8), http)
        case .status(let code, let headers):
            let http = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!
            return (Data(), http)
        case .failure(let e):
            throw e
        }
    }
}

/// A realistic `/releases/latest` payload, trimmed to the keys we read plus a
/// few we ignore (so the parser is proven tolerant of extra fields).
func releaseJSON(
    tag: String = "v1.1.3",
    name: String? = "shotAI 1.1.3",
    body: String = "- Faster exports\n- Bug fixes",
    htmlURL: String = "https://github.com/Armadillon44/shotAI_MacOS/releases/tag/v1.1.3",
    asset: (name: String, size: Int)? = ("shotAI-1.1.3.dmg", 6_912_345),
    extraAssets: Bool = false
) -> String {
    var assets: [String] = []
    if extraAssets {
        assets.append(#"{"name":"source.zip","size":1234,"browser_download_url":"https://x/y"}"#)
    }
    if let asset {
        assets.append(#"{"name":"\#(asset.name)","size":\#(asset.size),"browser_download_url":"https://objects.githubusercontent.com/x"}"#)
    }
    let nameField = name.map { #""name":"\#($0)","# } ?? #""name":null,"#
    return """
    {
      "id": 1234567,
      "tag_name": "\(tag)",
      \(nameField)
      "draft": false,
      "prerelease": false,
      "published_at": "2026-08-01T12:00:00Z",
      "html_url": "\(htmlURL)",
      "body": "\(body.replacingOccurrences(of: "\n", with: "\\n"))",
      "assets": [\(assets.joined(separator: ","))]
    }
    """
}

func makeChecker(
    _ transport: FakeTransport,
    state: UpdateCheckState = UpdateCheckState(),
    managedDisabled: Bool = false
) -> (UpdateChecker, InMemoryUpdateState) {
    let store = InMemoryUpdateState(state, managedDisabled: managedDisabled)
    let checker = UpdateChecker(store: store, makeFeed: { v in
        UpdateFeed(transport: transport, appVersion: v)
    })
    return (checker, store)
}

let t0 = Date(timeIntervalSince1970: 1_780_000_000)  // fixed clock for every test

// MARK: - SemanticVersion: parsing

@Suite("SemanticVersion parsing")
struct VersionParsingTests {
    @Test("accepts the shapes we publish", arguments: [
        ("1.1.2", 1, 1, 2, String?.none),
        ("v1.1.2", 1, 1, 2, String?.none),
        ("V1.1.2", 1, 1, 2, String?.none),
        ("  1.1.2  ", 1, 1, 2, String?.none),
        ("1.0.0-rc1", 1, 0, 0, String?.some("rc1")),
        ("v1.0.0-rc4", 1, 0, 0, String?.some("rc4")),
        ("0.0.0", 0, 0, 0, String?.none),
        ("10.20.30", 10, 20, 30, String?.none),
        ("1.2.3-beta-2", 1, 2, 3, String?.some("beta-2")),
        ("1.2.3+build.7", 1, 2, 3, String?.none),          // metadata stripped
        ("1.2.3-rc1+build.7", 1, 2, 3, String?.some("rc1")),
    ])
    func parses(_ raw: String, _ major: Int, _ minor: Int, _ patch: Int, _ pre: String?) {
        let v = SemanticVersion(raw)
        #expect(v != nil, "\(raw) should parse")
        #expect(v?.major == major)
        #expect(v?.minor == minor)
        #expect(v?.patch == patch)
        #expect(v?.prerelease == pre)
    }

    @Test("rejects anything it can't be sure about (fail closed)", arguments: [
        "", "   ", "v", "1", "1.2", "1.2.3.4", "one.two.three", "1.2.x",
        "latest", "v-1.2.3", "1.-2.3", "1.2.-3", "1.2.3-", "-1.2.3",
        "1..3", "1.2.", ".2.3", "1.٢.3", "+1.2.3", "nightly-2026-08-01",
    ])
    func rejects(_ raw: String) {
        #expect(SemanticVersion(raw) == nil, "\(raw) must not parse")
    }

    @Test("round-trips through description")
    func description() {
        #expect(SemanticVersion("v1.1.2")?.description == "1.1.2")
        #expect(SemanticVersion("1.0.0-rc1")?.description == "1.0.0-rc1")
    }
}

// MARK: - SemanticVersion: ordering (issue #62's acceptance table)

@Suite("SemanticVersion ordering")
struct VersionOrderingTests {
    /// Each pair is (lower, higher).
    @Test("orders correctly", arguments: [
        ("1.9.0", "1.10.0"),        // lexicographic gets this wrong
        ("1.0.0-rc1", "1.0.0"),     // .compare(.numeric) gets this wrong
        ("1.0.0-rc2", "1.0.0-rc10"),// strict SemVer would say rc10 < rc2
        ("1.0.0-rc1", "1.0.0-rc2"),
        ("1.1.2", "1.2.0"),
        ("1.1.2", "2.0.0"),
        ("0.9.9", "1.0.0"),
        ("1.1.2", "1.1.10"),
        ("1.0.0-alpha", "1.0.0-beta"),
        ("1.0.0-rc", "1.0.0-rc.1"),      // shorter identifier run sorts lower
        ("1.0.0-1", "1.0.0-alpha"),      // numeric identifier < alphanumeric
        ("1.1.2", "1.1.3-rc1"),          // a prerelease of a HIGHER patch is newer
    ])
    func ordered(_ lowRaw: String, _ highRaw: String) throws {
        let low = try #require(SemanticVersion(lowRaw))
        let high = try #require(SemanticVersion(highRaw))
        #expect(low < high, "\(lowRaw) should be < \(highRaw)")
        #expect(high > low)
        #expect(low != high)
    }

    @Test("equal versions are equal regardless of the v prefix")
    func equality() throws {
        #expect(SemanticVersion("v1.1.2") == SemanticVersion("1.1.2"))
        #expect(try !(#require(SemanticVersion("1.1.2")) < #require(SemanticVersion("1.1.2"))))
        // Build metadata is ignored for precedence, per SemVer.
        #expect(SemanticVersion("1.1.2+a") == SemanticVersion("1.1.2+b"))
    }

    @Test("sorts a realistic tag list")
    func sorting() {
        let tags = ["v1.1.2", "v1.0.0-rc1", "v1.0.0", "v1.10.0", "v1.0.0-rc10", "v1.9.0", "v1.0.0-rc2"]
        let sorted = tags.compactMap(SemanticVersion.init).sorted().map(\.description)
        #expect(sorted == ["1.0.0-rc1", "1.0.0-rc2", "1.0.0-rc10", "1.0.0", "1.1.2", "1.9.0", "1.10.0"])
    }
}

// MARK: - Feed parsing

@Suite("UpdateFeed parsing")
struct FeedParsingTests {
    @Test("reads the fields the UI shows")
    func parsesRelease() throws {
        let info = try #require(UpdateFeed.parse(Data(releaseJSON().utf8)))
        #expect(info.tag == "v1.1.3")
        #expect(info.version == SemanticVersion("1.1.3"))
        #expect(info.name == "shotAI 1.1.3")
        #expect(info.notes == "- Faster exports\n- Bug fixes")
        #expect(info.releasePage.absoluteString.hasPrefix("https://github.com/Armadillon44/shotAI_MacOS/releases/"))
        #expect(info.assetName == "shotAI-1.1.3.dmg")
        #expect(info.assetSize == 6_912_345)
        #expect(info.assetSummary == "shotAI-1.1.3.dmg · 6.6 MB")
        #expect(info.publishedAt != nil)
    }

    @Test("picks the .dmg out of a multi-asset release")
    func picksDmg() throws {
        let info = try #require(UpdateFeed.parse(Data(releaseJSON(extraAssets: true).utf8)))
        #expect(info.assetName == "shotAI-1.1.3.dmg")
    }

    @Test("falls back to the tag when the release has no name")
    func nameFallback() throws {
        let info = try #require(UpdateFeed.parse(Data(releaseJSON(name: nil).utf8)))
        #expect(info.name == "v1.1.3")
    }

    @Test("survives a release with no assets and no notes")
    func noAssets() throws {
        let info = try #require(UpdateFeed.parse(Data(releaseJSON(body: "", asset: nil).utf8)))
        #expect(info.assetName == nil)
        #expect(info.assetSummary == nil)
        #expect(info.notes.isEmpty)
    }

    @Test("rejects a body it can't trust", arguments: [
        "",
        "not json",
        "{}",
        #"{"tag_name":"nightly","html_url":"https://github.com/a/b/releases/tag/x"}"#,   // unparseable tag
        #"{"tag_name":"v1.2.3"}"#,                                                       // no html_url
        #"{"tag_name":"v1.2.3","html_url":"https://evil.example.com/x"}"#,               // off-host page
        #"{"tag_name":"v1.2.3","html_url":"javascript:alert(1)"}"#,
        "[]",
    ])
    func rejectsMalformed(_ body: String) {
        #expect(UpdateFeed.parse(Data(body.utf8)) == nil)
    }

    /// Parse only — the feed must not consult the wall clock (the checker owns
    /// time and clamps a past reset into its own floor).
    @Test("parses x-ratelimit-reset without judging it against the clock")
    func rateLimitHeader() throws {
        let url = URL(string: "https://api.github.com/x")!
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: headers)!
        }
        let future = t0.addingTimeInterval(1800)
        let parsed = try #require(UpdateFeed.rateLimitReset(
            response(["x-ratelimit-reset": "\(Int(future.timeIntervalSince1970))"])))
        #expect(abs(parsed.timeIntervalSince(future)) < 1.5)

        // A reset in the past still parses; clamping is the checker's job.
        #expect(UpdateFeed.rateLimitReset(response(["x-ratelimit-reset": "1000"]))
            == Date(timeIntervalSince1970: 1000))

        #expect(UpdateFeed.rateLimitReset(response(["x-ratelimit-reset": "soon"])) == nil)
        #expect(UpdateFeed.rateLimitReset(response(["x-ratelimit-reset": "0"])) == nil)
        #expect(UpdateFeed.rateLimitReset(response([:])) == nil)
    }

    /// The checker, not the feed, decides a past reset is unusable.
    @Test("a reset already in the past is clamped up to the transient floor")
    func pastResetClamped() async {
        let past = t0.addingTimeInterval(-5000)
        let transport = FakeTransport(.status(403, headers: [
            "x-ratelimit-reset": "\(Int(past.timeIntervalSince1970))"
        ]))
        let (checker, store) = makeChecker(transport)
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(store.load().rateLimitedUntil == t0.addingTimeInterval(UpdateBackoff.transient))
    }

    @Test("the endpoint stays pinned to the GitHub API host")
    func pinnedEndpoint() {
        #expect(UpdateFeed.latestReleaseURL.host == "api.github.com")
        #expect(UpdateFeed.latestReleaseURL.scheme == "https")
        #expect(UpdateFeed.latestReleaseURL.path == "/repos/Armadillon44/shotAI_MacOS/releases/latest")
    }

    /// Asserts the request that actually went out, not a property the initializer
    /// just set — an earlier version of this test re-read `feed.userAgent` and
    /// would have passed even if the header were never attached.
    @Test("the outgoing request carries a User-Agent and no credentials")
    func requestShape() async throws {
        let transport = FakeTransport(.ok(releaseJSON()))
        let feed = UpdateFeed(transport: transport, appVersion: "1.1.2")
        _ = try await feed.fetchLatest()
        let sent = try #require(transport.lastRequest)

        #expect(sent.url == UpdateFeed.latestReleaseURL)
        #expect(sent.httpMethod == "GET")
        #expect(sent.httpBody == nil)
        let ua = try #require(sent.value(forHTTPHeaderField: "User-Agent"))
        #expect(ua.contains("shotAI/1.1.2"))
        #expect(sent.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(sent.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        // Nothing that could identify the user or authenticate the request.
        for header in ["Authorization", "Cookie", "X-API-Key", "x-api-key"] {
            #expect(sent.value(forHTTPHeaderField: header) == nil, "must not send \(header)")
        }
        #expect(sent.httpShouldHandleCookies == true || sent.httpShouldHandleCookies == false)
    }

    @Test("maps HTTP statuses to errors")
    func statusMapping() async {
        let reset = Int(Date().addingTimeInterval(900).timeIntervalSince1970)
        let cases: [(Int, [String: String], UpdateFeedError)] = [
            (403, ["x-ratelimit-reset": "\(reset)"], .rateLimited(resetAt: Date(timeIntervalSince1970: Double(reset)))),
            (429, [:], .rateLimited(resetAt: nil)),
            (404, [:], .http(status: 404)),
            (500, [:], .http(status: 500)),
        ]
        for (code, headers, expected) in cases {
            let feed = UpdateFeed(transport: FakeTransport(.status(code, headers: headers)), appVersion: "1.1.2")
            await #expect(throws: expected) { try await feed.fetchLatest() }
        }
    }

    @Test("a 200 with a bad body is malformed, not silently up-to-date")
    func malformedBody() async {
        let feed = UpdateFeed(transport: FakeTransport(.ok("<html>rate limited</html>")), appVersion: "1.1.2")
        await #expect(throws: UpdateFeedError.malformedResponse) { try await feed.fetchLatest() }
    }
}

// MARK: - Checker: comparison outcomes

@Suite("UpdateChecker outcomes")
struct CheckerOutcomeTests {
    @Test("offers a newer release")
    func offersNewer() async throws {
        let (checker, _) = makeChecker(FakeTransport(.ok(releaseJSON(tag: "v1.1.3"))))
        let out = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        let release = try #require(out.availableRelease)
        #expect(release.version == SemanticVersion("1.1.3"))
    }

    @Test("says nothing when versions match")
    func equalIsUpToDate() async {
        let (checker, _) = makeChecker(FakeTransport(.ok(releaseJSON(tag: "v1.1.2"))))
        let out = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(out == .upToDate)
    }

    @Test("never offers a downgrade — a local build ahead of the release")
    func localAheadOffersNothing() async {
        let (checker, _) = makeChecker(FakeTransport(.ok(releaseJSON(tag: "v1.1.1"))))
        let out = await checker.check(reason: .manual, enabled: true, currentVersion: "1.2.0-rc1", now: t0)
        #expect(out == .upToDate)
    }

    @Test("fails closed on an unparseable running version and makes no request")
    func unparseableRunningVersion() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v9.9.9")))
        let (checker, _) = makeChecker(transport)
        let out = await checker.check(reason: .manual, enabled: true, currentVersion: "?", now: t0)
        #expect(out == .upToDate)
        #expect(transport.calls == 0, "must not spend a request it can't interpret")
    }

    @Test("an unparseable release tag surfaces as malformed, not as an update")
    func unparseableTag() async {
        let (checker, _) = makeChecker(FakeTransport(.ok(releaseJSON(tag: "nightly"))))
        let out = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(out == .failed(.malformedResponse))
        #expect(out.availableRelease == nil)
    }
}

// MARK: - Checker: skip

@Suite("UpdateChecker skip")
struct CheckerSkipTests {
    @Test("a skipped version stops being offered, and survives a relaunch")
    func skipPersists() async throws {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, store) = makeChecker(transport)
        #expect(await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0).availableRelease != nil)

        await checker.skip(tag: "v1.1.3")
        let out = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        guard case .skipped(let r) = out else { Issue.record("expected .skipped, got \(out)"); return }
        #expect(r.version == SemanticVersion("1.1.3"))

        // "Relaunch": a brand-new checker over the same persisted state.
        let (fresh, _) = makeChecker(transport, state: store.load())
        let again = await fresh.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        if case .skipped = again {} else { Issue.record("skip did not persist: \(again)") }
    }

    @Test("a release newer than the skipped one is still offered")
    func skipDoesNotSuppressNewer() async throws {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport)
        await checker.skip(tag: "v1.1.3")

        transport.set(.ok(releaseJSON(tag: "v1.2.0")))
        let out = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(try #require(out.availableRelease).version == SemanticVersion("1.2.0"))
    }

    @Test("clearing the skip brings the version back")
    func clearSkip() async {
        let (checker, _) = makeChecker(FakeTransport(.ok(releaseJSON(tag: "v1.1.3"))))
        await checker.skip(tag: "v1.1.3")
        await checker.clearSkip()
        let out = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(out.availableRelease != nil)
    }
}

// MARK: - Checker: throttle

@Suite("UpdateChecker throttle")
struct CheckerThrottleTests {
    @Test("a successful check silences automatic checks for 24h")
    func dailyCadence() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport)
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(transport.calls == 1)

        // Same day: gated, no request.
        let soon = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2",
                                       now: t0.addingTimeInterval(23 * 3600))
        if case .throttled = soon {} else { Issue.record("expected .throttled, got \(soon)") }
        #expect(transport.calls == 1)

        // Next day: runs again.
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2",
                                now: t0.addingTimeInterval(24 * 3600 + 60))
        #expect(transport.calls == 2)
    }

    @Test("the cadence gate survives a relaunch")
    func cadencePersists() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, store) = makeChecker(transport)
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(transport.calls == 1)

        let (relaunched, _) = makeChecker(transport, state: store.load())
        _ = await relaunched.check(reason: .automatic, enabled: true, currentVersion: "1.1.2",
                                   now: t0.addingTimeInterval(60))
        #expect(transport.calls == 1, "a relaunch must not reset the daily cadence")
    }

    @Test("Check Now bypasses the daily cadence")
    func manualBypassesCadence() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport)
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        _ = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0.addingTimeInterval(60))
        #expect(transport.calls == 2)
    }

    @Test("offline backs off an hour and shows no error state beyond .failed")
    func offlineBackoff() async {
        let transport = FakeTransport(.failure(.connection))
        let (checker, store) = makeChecker(transport)
        let out = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(out == .failed(.connection))
        let next = store.load().nextAttemptNotBefore
        #expect(next == t0.addingTimeInterval(3600))
        #expect(store.load().lastSuccessfulCheck == nil)

        // Still gated 30 minutes later.
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2",
                                now: t0.addingTimeInterval(1800))
        #expect(transport.calls == 1)
    }

    @Test("403 honors x-ratelimit-reset and blocks even a manual check")
    func rateLimitBlocksManual() async {
        let reset = t0.addingTimeInterval(2700)   // 45 min
        let transport = FakeTransport(.status(403, headers: [
            "x-ratelimit-reset": "\(Int(reset.timeIntervalSince1970))"
        ]))
        let (checker, store) = makeChecker(transport)
        let out = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(out == .failed(.rateLimited(resetAt: reset)))
        #expect(store.load().rateLimitedUntil == reset)

        // Manual clicks do NOT get through a live rate limit.
        let manual = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2",
                                         now: t0.addingTimeInterval(600))
        #expect(manual == .throttled(until: reset))
        #expect(transport.calls == 1)

        // And a relaunch doesn't re-fire it either.
        let (relaunched, _) = makeChecker(transport, state: store.load())
        _ = await relaunched.check(reason: .automatic, enabled: true, currentVersion: "1.1.2",
                                   now: t0.addingTimeInterval(700))
        #expect(transport.calls == 1)

        // After the reset passes it runs again.
        transport.set(.ok(releaseJSON(tag: "v1.1.3")))
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2",
                                now: reset.addingTimeInterval(60))
        #expect(transport.calls == 2)
    }

    @Test("a rate-limit reset far in the future is clamped to 24h")
    func clampsAbsurdReset() async {
        let bogus = t0.addingTimeInterval(400 * 24 * 3600)
        let transport = FakeTransport(.status(429, headers: [
            "x-ratelimit-reset": "\(Int(bogus.timeIntervalSince1970))"
        ]))
        let (checker, store) = makeChecker(transport)
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        let until = store.load().rateLimitedUntil
        #expect(until == t0.addingTimeInterval(UpdateBackoff.ceiling))
    }

    @Test("a rate limit with no header still backs off at least an hour")
    func rateLimitNoHeader() async {
        let (checker, store) = makeChecker(FakeTransport(.status(429)))
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(store.load().rateLimitedUntil == t0.addingTimeInterval(UpdateBackoff.transient))
    }

    @Test("structural failures back off further than transient ones", arguments: [
        (404, UpdateBackoff.structural),
        (500, UpdateBackoff.transient),
        (503, UpdateBackoff.transient),
    ])
    func statusBackoff(_ status: Int, _ expected: TimeInterval) async {
        let (checker, store) = makeChecker(FakeTransport(.status(status)))
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(store.load().nextAttemptNotBefore == t0.addingTimeInterval(expected))
    }

    @Test("a corrupt far-future gate is dropped rather than wedging checks off")
    func sanitizesBogusGate() async {
        var state = UpdateCheckState()
        state.nextAttemptNotBefore = t0.addingTimeInterval(365 * 24 * 3600)
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport, state: state)
        let out = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(out.availableRelease != nil)
        #expect(transport.calls == 1)
    }

    @Test("records the time of the last successful check")
    func recordsLastChecked() async {
        let (checker, store) = makeChecker(FakeTransport(.ok(releaseJSON(tag: "v1.1.2"))))
        _ = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(store.load().lastSuccessfulCheck == t0)
        #expect(store.load().latest == nil, "nothing newer, so nothing to remember")
    }
}

// MARK: - Checker: opt-out

@Suite("UpdateChecker opt-out")
struct CheckerOptOutTests {
    @Test("the user preference stops the check before any network call")
    func userDisabled() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport)
        let out = await checker.check(reason: .automatic, enabled: false, currentVersion: "1.1.2", now: t0)
        #expect(out == .disabled(managed: false))
        #expect(transport.calls == 0)
    }

    @Test("a configuration profile overrides the user preference")
    func managedDisabled() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport, managedDisabled: true)
        let out = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(out == .disabled(managed: true))
        #expect(transport.calls == 0)
        #expect(checker.isManagedDisabled)
    }
}

// MARK: - State persistence

@Suite("UpdateCheckState")
struct StateTests {
    @Test("round-trips through JSON")
    func roundTrip() throws {
        var s = UpdateCheckState()
        s.lastSuccessfulCheck = t0
        s.nextAttemptNotBefore = t0.addingTimeInterval(86_400)
        s.rateLimitedUntil = nil
        s.skippedTag = "v1.1.3"
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(UpdateCheckState.self, from: data) == s)
    }

    @Test("a partial or unknown blob decodes to defaults instead of throwing")
    func tolerantDecode() throws {
        let partial = try #require(#"{"skippedTag":"v1.1.3","somethingNew":42}"#.data(using: .utf8))
        let s = try JSONDecoder().decode(UpdateCheckState.self, from: partial)
        #expect(s.skippedTag == "v1.1.3")
        #expect(s.nextAttemptNotBefore == nil)
    }

    @Test("a future lastSuccessfulCheck (clock jump) is pulled back to now")
    func clockJump() {
        var s = UpdateCheckState()
        s.lastSuccessfulCheck = t0.addingTimeInterval(10_000)
        s.sanitize(now: t0, maxBackoff: UpdateBackoff.ceiling)
        #expect(s.lastSuccessfulCheck == t0)
    }
}

// MARK: - Regressions
//
// Every test below pins a defect an adversarial review found in the first cut of
// this package. Each one failed before its fix.

@Suite("Regressions")
struct RegressionTests {
    /// `check()` used to snapshot the state before its network `await` and write
    /// that snapshot back afterwards. Actors are REENTRANT, so `skip()` ran to
    /// completion inside that window and was then silently erased — the user's
    /// "Skip This Version" came back on the very next launch.
    @Test("a skip made while a check is in flight is not clobbered by the write-back")
    func skipSurvivesConcurrentCheck() async throws {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")), delay: .milliseconds(300))
        let (checker, store) = makeChecker(transport)

        async let outcome = checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        try await Task.sleep(for: .milliseconds(80))   // the check is parked on the network
        await checker.skip(tag: "v1.1.3")
        let result = await outcome

        #expect(store.load().skippedTag == "v1.1.3", "the skip must survive the check's write-back")
        if case .skipped = result {} else {
            Issue.record("the in-flight check should honour the skip that landed mid-request, got \(result)")
        }
        // And it must still be suppressed on the next launch.
        let (fresh, _) = makeChecker(FakeTransport(.ok(releaseJSON(tag: "v1.1.3"))), state: store.load())
        let again = await fresh.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        if case .skipped = again {} else { Issue.record("skip lost across relaunch: \(again)") }
    }

    /// The actor's serialization claim was not true for the same reentrancy
    /// reason: two overlapping checks each spent a request against a 60/hour
    /// budget shared by every machine behind one NAT.
    @Test("two overlapping checks make exactly one request")
    func overlappingChecksCoalesce() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")), delay: .milliseconds(200))
        let (checker, _) = makeChecker(transport)

        async let a = checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        async let b = checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        let (ra, rb) = await (a, b)

        #expect(transport.calls == 1, "the second caller must join the in-flight check")
        #expect(ra.availableRelease?.tag == "v1.1.3")
        #expect(rb.availableRelease?.tag == "v1.1.3")
    }

    /// A newer release found on one launch has to still be known on the next —
    /// the 24 h cadence means no request runs, so a purely in-memory notice would
    /// show up on exactly one launch and then disappear for a day.
    @Test("the pending release is remembered across a relaunch")
    func releaseRemembered() async throws {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, store) = makeChecker(transport)
        #expect(await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
            .availableRelease != nil)

        // "Relaunch" inside the cadence window: no request, but the notice stands.
        let (fresh, _) = makeChecker(transport, state: store.load())
        let throttled = await fresh.check(reason: .automatic, enabled: true, currentVersion: "1.1.2",
                                          now: t0.addingTimeInterval(3600))
        if case .throttled = throttled {} else { Issue.record("expected .throttled, got \(throttled)") }
        #expect(transport.calls == 1)

        let remembered = try #require(await fresh.rememberedRelease())
        #expect(remembered.version == SemanticVersion("1.1.3"))
        #expect(remembered.name == "shotAI 1.1.3")
        #expect(remembered.assetName == "shotAI-1.1.3.dmg")
        #expect(remembered.releasePage.scheme == "https")
    }

    @Test("a remembered release is dropped once the user skips it")
    func rememberedRespectsSkip() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, store) = makeChecker(transport)
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(await checker.rememberedRelease() != nil)

        await checker.skip(tag: "v1.1.3")
        #expect(await checker.rememberedRelease() == nil)

        let (fresh, _) = makeChecker(transport, state: store.load())
        #expect(await fresh.rememberedRelease() == nil, "must stay suppressed after a relaunch")
    }

    @Test("an up-to-date check clears a previously remembered release")
    func rememberedClearedWhenCurrent() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport)
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(await checker.rememberedRelease() != nil)

        // The user installs 1.1.3; the next check finds nothing newer.
        _ = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.3", now: t0)
        #expect(await checker.rememberedRelease() == nil)
    }

    /// A stored blob is re-validated on read, so a hand-edited plist can't turn
    /// the Download button into a link to somewhere else.
    @Test("a tampered stored release is rejected on read", arguments: [
        "smb://github.com/share",
        "http://github.com/Armadillon44/shotAI_MacOS/releases/tag/v1.1.3",
        "https://evil.example.com/x",
        "not a url at all ///",
    ])
    func tamperedStoredReleaseRejected(_ page: String) async {
        var state = UpdateCheckState()
        var stored = StoredRelease(ReleaseInfo(
            tag: "v1.1.3", version: SemanticVersion("1.1.3")!, name: "x", notes: "",
            releasePage: URL(string: "https://github.com/a/b/releases/tag/v1.1.3")!))
        stored.page = page
        state.latest = stored
        let (checker, _) = makeChecker(FakeTransport(.ok(releaseJSON())), state: state)
        #expect(await checker.rememberedRelease() == nil, "\(page) must not survive validation")
    }

    /// `html_url` is remote data that ends up at `NSWorkspace.open`, i.e. "launch
    /// whatever app claims this scheme". A host-only check passed every one of
    /// these, because Foundation parses `scheme://github.com/…` with host
    /// `github.com`.
    @Test("a release page with a non-https scheme, credentials, or a port is refused", arguments: [
        "smb://github.com/share",
        "file://github.com/tmp/x",
        "vnc://github.com/x",
        "javascript://github.com/%0aalert(1)",
        "http://github.com/Armadillon44/shotAI_MacOS/releases/tag/v1.1.3",
        "https://evil.com@github.com/x",
        "https://github.com:8443/x",
    ])
    func rejectsHostileReleasePage(_ url: String) {
        #expect(UpdateFeed.parse(Data(releaseJSON(htmlURL: url).utf8)) == nil,
                "\(url) must not reach NSWorkspace.open")
    }

    @Test("the ordinary GitHub release page is still accepted")
    func acceptsRealReleasePage() throws {
        let ok = try #require(UpdateFeed.parse(Data(releaseJSON().utf8)))
        #expect(ok.releasePage.absoluteString
            == "https://github.com/Armadillon44/shotAI_MacOS/releases/tag/v1.1.3")
    }

    /// With ceiling == success == 24 h, `d > now + 24h` reduced to
    /// `checkTime > now`, so a one-second backward NTP correction discarded a
    /// perfectly good cadence gate and let the next launch re-check.
    @Test("a small backward clock correction does not discard the daily cadence")
    func smallClockDriftKeepsCadence() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport)
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(transport.calls == 1)

        // Clock steps back a second, then a minute, then five minutes.
        for drift in [1.0, 60.0, 300.0] {
            _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2",
                                    now: t0.addingTimeInterval(-drift))
            #expect(transport.calls == 1, "a \(Int(drift))s backward clock step must not re-fire the check")
        }
    }

    @Test("a genuinely absurd gate is still discarded")
    func absurdGateStillDropped() async {
        var state = UpdateCheckState()
        state.nextAttemptNotBefore = t0.addingTimeInterval(90 * 24 * 3600)
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport, state: state)
        _ = await checker.check(reason: .automatic, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(transport.calls == 1)
    }

    /// Remote text that gets rendered and persisted has to be bounded.
    @Test("oversized release notes and names are truncated")
    func remoteTextIsBounded() throws {
        let huge = String(repeating: "A", count: 60_000)
        let info = try #require(UpdateFeed.parse(Data(releaseJSON(name: huge, body: huge).utf8)))
        #expect(info.notes.count == UpdateFeed.maxNotesChars)
        #expect(info.name.count == UpdateFeed.maxNameChars)
    }

    /// The preference is "check *automatically*"; an explicit request should
    /// still get an answer. `UpdateModel.checkNow` passes enabled: true.
    @Test("an explicit manual check runs even though automatic checks are off")
    func manualRunsWithAutomaticOff() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport)

        // What the daily trigger does when the preference is off.
        #expect(await checker.check(reason: .automatic, enabled: false, currentVersion: "1.1.2", now: t0)
            == .disabled(managed: false))
        #expect(transport.calls == 0)

        // What "Check for Updates…" does.
        let manual = await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
        #expect(manual.availableRelease != nil)
        #expect(transport.calls == 1)
    }

    /// The MDM kill switch is absolute — it outranks an explicit manual check.
    @Test("a configuration profile blocks even an explicit manual check")
    func managedBlocksManual() async {
        let transport = FakeTransport(.ok(releaseJSON(tag: "v1.1.3")))
        let (checker, _) = makeChecker(transport, managedDisabled: true)
        #expect(await checker.check(reason: .manual, enabled: true, currentVersion: "1.1.2", now: t0)
            == .disabled(managed: true))
        #expect(transport.calls == 0)
    }

    @Test("StoredRelease round-trips and tolerates a partial blob")
    func storedReleaseCodable() throws {
        let info = try #require(UpdateFeed.parse(Data(releaseJSON().utf8)))
        let stored = StoredRelease(info)
        let back = try JSONDecoder().decode(StoredRelease.self, from: JSONEncoder().encode(stored))
        #expect(back == stored)
        let rebuilt = try #require(back.release())
        #expect(rebuilt.version == info.version)
        #expect(rebuilt.assetSummary == info.assetSummary)

        // Only tag + page are required; the rest degrade.
        let partial = #"{"tag":"v1.1.3","page":"https://github.com/a/b/releases/tag/v1.1.3"}"#
        let thin = try JSONDecoder().decode(StoredRelease.self, from: Data(partial.utf8))
        #expect(thin.name == "v1.1.3")
        #expect(thin.notes.isEmpty)
        #expect(thin.release() != nil)
    }
}
