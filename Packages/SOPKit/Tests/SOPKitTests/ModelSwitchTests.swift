import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// Where shotAI sends the user when a model fails, which models the picker keeps,
/// and how the cached list is kept honest across credentials, builds and relaunches.
final class ModelSwitchTests: XCTestCase {

    private typealias D = ModelDiscoveryTests
    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // 2027-01-15
    private let sonnet6 = SopModelId(rawValue: "claude-sonnet-6")
    private let sonnet5 = SopModelId(rawValue: "claude-sonnet-5")

    private func target(failed: SopModelId, _ entries: [[String: Any]], complete: Bool = true,
                        excluding: Set<String> = []) throws -> ModelChoice? {
        errorSwitchTarget(failed: failed, listed: try D.listed(entries), complete: complete,
                          excluding: excluding, now: now)
    }

    /// `today` without Sonnet 5.5: the account cannot use the built-in default.
    private var withoutDefault: [[String: Any]] {
        D.today.filter { $0["id"] as? String != "claude-sonnet-5-5" } + [D.sonnet6]
    }

    // MARK: The failure alert's target

    func testAFailedModelFromTheListGoesBackToTheDefault() throws {
        XCTAssertEqual(try target(failed: sonnet6, D.today + [D.sonnet6]), .builtIn(.sonnet55))
        XCTAssertEqual(try target(failed: sonnet6, []), .builtIn(.sonnet55), "no listing: nothing says it is gone")
    }

    /// The finding: on an account without Sonnet 5.5, a failing Sonnet 6 sent the
    /// user to 5.5, whose banner sent them back to Sonnet 6. Go to a model the
    /// listing says works instead.
    func testTheDefaultIsNotOfferedWhenTheListingSaysItIsGone() throws {
        XCTAssertEqual(try target(failed: sonnet6, withoutDefault)?.id, sonnet5)
        XCTAssertEqual(try target(failed: sonnet6, withoutDefault, complete: false), .builtIn(.sonnet55),
                       "an incomplete listing is no proof the default is gone")
        let retired = D.today.map { e -> [String: Any] in
            guard e["id"] as? String == "claude-sonnet-5-5" else { return e }
            return D.entry("claude-sonnet-5-5", lifecycle: "deprecated", retires: "2027-01-01T00:00:00Z")
        } + [D.sonnet6]
        XCTAssertEqual(try target(failed: sonnet6, retired)?.id, sonnet5, "past its retirement date")
        let retiring = D.today.map { e -> [String: Any] in
            guard e["id"] as? String == "claude-sonnet-5-5" else { return e }
            return D.entry("claude-sonnet-5-5", lifecycle: "deprecated", retires: "2027-06-01T00:00:00Z")
        } + [D.sonnet6]
        XCTAssertEqual(try target(failed: sonnet6, retiring), .builtIn(.sonnet55), "retiring later still works now")
    }

    /// Two models that both fail must not be offered in turn forever.
    func testAModelThatFailedThisSessionIsNeverOfferedAgain() throws {
        XCTAssertEqual(try target(failed: sonnet6, D.today + [D.sonnet6], excluding: ["claude-sonnet-5-5"])?.id,
                       sonnet5)
        XCTAssertNil(try target(failed: sonnet6, withoutDefault, excluding: ["claude-sonnet-5"]),
                     "nothing left that has not failed: the alert offers only OK")
        XCTAssertNil(try target(failed: .sonnet55, D.today + [D.sonnet6], excluding: ["claude-sonnet-6"]))
    }

    func testAFailedBuiltInModelGoesOnToTheReplacementDiscoveryFound() throws {
        XCTAssertEqual(try target(failed: .sonnet55, D.today + [D.sonnet6])?.id, sonnet6)
        XCTAssertNil(try target(failed: .sonnet55, D.today), "nothing newer to go to")
        XCTAssertEqual(try target(failed: .sonnet55, withoutDefault)?.id, sonnet6, "missing: the newest that works")
    }

    func testTheTargetIsNeverTheModelThatFailed() throws {
        for failed in [SopModelId.sonnet55, sonnet6, sonnet5] {
            for entries in [D.today, D.today + [D.sonnet6], withoutDefault, []] {
                XCTAssertNotEqual(try target(failed: failed, entries)?.id, failed)
            }
        }
    }

    func testTheOfferNeverNamesAModelThatFailedThisSession() throws {
        let l = try D.listed(D.today + [D.sonnet6])
        XCTAssertEqual(modelOffer(listed: l, complete: true, current: .sonnet55)?.candidate?.id, "claude-sonnet-6")
        XCTAssertNil(modelOffer(listed: l, complete: true, current: .sonnet55, excluding: ["claude-sonnet-6"]))
        let gone = try D.listed(withoutDefault)
        let o = try XCTUnwrap(modelOffer(listed: gone, complete: true, current: .sonnet55, excluding: ["claude-sonnet-6"]))
        XCTAssertEqual(o.reason, .unavailable, "the warning stays; only its button changes")
        XCTAssertEqual(o.candidate?.id, "claude-sonnet-5")
    }

    // MARK: The picker

    private func profile(_ id: String) throws -> SopModelProfile {
        try XCTUnwrap(try D.listed(D.today + [D.sonnet6, sonnet65]).first { $0.id == id }?.profile)
    }

    private var sonnet65: [String: Any] {
        D.entry("claude-sonnet-6-5", created: "2027-09-01T00:00:00Z", displayName: "Claude Sonnet 6.5")
    }

    /// The finding: switching from Sonnet 6 to 6.5 made 6 impossible to choose
    /// again, although the help text said "you can switch back".
    func testAModelSwitchedAwayFromStaysChoosableWhileItIsListed() throws {
        let l = try D.listed(D.today + [D.sonnet6, sonnet65])
        let ids = modelPickerChoices(inUse: try profile("claude-sonnet-6-5"), offered: nil,
                                     chosen: ["claude-sonnet-6", "claude-sonnet-6-5"], listed: l).map(\.id.rawValue)
        XCTAssertEqual(ids, ["claude-sonnet-5-5", "claude-sonnet-6-5", "claude-sonnet-6"])
        XCTAssertFalse(ids.contains("claude-sonnet-5"), "a model never chosen is not added because the list has it")

        let deprecated = try D.listed(D.today + [sonnet65,
            D.entry("claude-sonnet-6", created: "2027-03-01T00:00:00Z", lifecycle: "deprecated")])
        XCTAssertFalse(modelPickerChoices(inUse: nil, offered: nil, chosen: ["claude-sonnet-6"], listed: deprecated)
            .map(\.id.rawValue).contains("claude-sonnet-6"), "once it is on its way out, it is not offered back")
    }

    func testThePickerHasEachModelOnceBuiltInsFirst() throws {
        let l = try D.listed(D.today + [D.sonnet6])
        let six = try profile("claude-sonnet-6")
        let choices = modelPickerChoices(inUse: six, offered: six, chosen: ["claude-sonnet-6", "claude-sonnet-5-5"],
                                         listed: l)
        XCTAssertEqual(choices, [.builtIn(.sonnet55), .discovered(six)])
    }

    // MARK: The cached list

    func testChosenModelsAreRememberedOnceEachNewestLast() {
        var s = ModelDiscoveryState()
        for id in ["a", "b", "a"] { s.noteChosen(id) }
        XCTAssertEqual(s.chosen, ["b", "a"], "choosing again moves it to the end, once")
        for id in ["c", "d", "e", "f", "g"] { s.noteChosen(id) }
        XCTAssertEqual(s.chosen, ["c", "d", "e", "f", "g"], "at most the five most recent")
    }

    /// A new key, a sign-in or a sign-out can mean another account with other
    /// models: the list is read again, and nothing the user decided is lost.
    func testForgettingTheListingKeepsWhatTheUserDecided() throws {
        var s = ModelDiscoveryState()
        s.recordSuccess(try D.listed(D.today + [D.sonnet6]), complete: true, at: now)
        let o = try XCTUnwrap(modelOffer(listed: s.listed, complete: s.complete, current: .sonnet55))
        s.dismiss(o)
        s.noteChosen("claude-sonnet-6")
        s.forgetListing()
        XCTAssertTrue(s.listed.isEmpty)
        XCTAssertFalse(s.complete)
        XCTAssertTrue(s.isDue(at: now), "read again at once, not in a day")
        XCTAssertTrue(s.isDismissed(o))
        XCTAssertEqual(s.chosen, ["claude-sonnet-6"])
    }

    /// The finding: a list cached before this build's default existed called that
    /// default missing, with a warning that cannot be dismissed, for up to a day.
    func testAListingFromABuildWithOtherBuiltInsIsNotUsed() throws {
        var s = ModelDiscoveryState()
        s.recordSuccess(try D.listed(D.today), complete: true, at: now)
        s.dismissed = ["newer:x"]
        s.chosen = ["claude-sonnet-6"]
        XCTAssertEqual(s.listedFor, ModelDiscoveryState.builtInSignature)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])

        json["listedFor"] = "claude-sonnet-5"
        let other = try JSONDecoder().decode(ModelDiscoveryState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(other.listed.isEmpty)
        XCTAssertTrue(other.isDue(at: now))
        XCTAssertEqual(other.dismissed, ["newer:x"])
        XCTAssertEqual(other.chosen, ["claude-sonnet-6"])

        json.removeValue(forKey: "listedFor")
        XCTAssertTrue(try JSONDecoder().decode(ModelDiscoveryState.self,
                                               from: JSONSerialization.data(withJSONObject: json)).listed.isEmpty,
                      "no signature: not known to be this build's")
    }

    /// The finding: an unreadable listing came back empty but kept its schedule,
    /// so offers and warnings vanished for up to a day instead of a fresh check.
    func testAnUnreadableListingIsCheckedAgainAtOnce() throws {
        var s = ModelDiscoveryState()
        s.recordSuccess(try D.listed(D.today), complete: true, at: now)
        s.dismissed = ["newer:x"]
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        var entries = try XCTUnwrap(json["listed"] as? [[String: Any]])
        entries[0].removeValue(forKey: "id")  // as if a later build had renamed a field
        json["listed"] = entries
        let read = try JSONDecoder().decode(ModelDiscoveryState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(read.listed.isEmpty)
        XCTAssertNil(read.nextCheckAt)
        XCTAssertTrue(read.isDue(at: now.addingTimeInterval(60)))
        XCTAssertEqual(read.dismissed, ["newer:x"])
    }

    func testNotNowSurvivesTheNextDailyCheck() throws {
        var s = ModelDiscoveryState()
        let listing = try D.listed(D.today + [D.sonnet6])
        s.recordSuccess(listing, complete: true, at: now)
        let o = try XCTUnwrap(modelOffer(listed: s.listed, complete: s.complete, current: .sonnet55))
        s.dismiss(o)
        s.recordSuccess(listing, complete: true, at: now.addingTimeInterval(24 * 3600))
        XCTAssertTrue(s.isDismissed(try XCTUnwrap(modelOffer(listed: s.listed, complete: s.complete, current: .sonnet55))))
        s.recordFailure(at: now.addingTimeInterval(48 * 3600))
        XCTAssertTrue(s.isDismissed(o))
    }

    // MARK: Offer rules the suite did not pin

    func testDismissingARetiringNoticeDoesNotHideALaterReplacement() throws {
        let alone = [D.entry("claude-sonnet-5-5", lifecycle: "deprecated")]
        let first = try XCTUnwrap(modelOffer(listed: try D.listed(alone), complete: true, current: .sonnet55))
        guard case .retiring = first.reason else { return XCTFail("\(first.reason)") }
        XCTAssertNil(first.candidate)
        XCTAssertNotNil(first.dismissKey, "a retiring notice can be put away")
        var s = ModelDiscoveryState()
        s.dismiss(first)
        let next = try XCTUnwrap(modelOffer(listed: try D.listed(alone + [D.sonnet6]), complete: true, current: .sonnet55))
        XCTAssertEqual(next.candidate?.id, "claude-sonnet-6")
        XCTAssertFalse(s.isDismissed(next), "a replacement appearing later is news")
    }

    func testANewerSonnetWithNoLifecycleIsOffered() throws {
        let unlabeled = D.entry("claude-sonnet-6", created: "2027-03-01T00:00:00Z", lifecycle: nil)
        XCTAssertTrue(try XCTUnwrap(try D.listed([unlabeled]).first).isActive)
        XCTAssertEqual(modelOffer(listed: try D.listed(D.today + [unlabeled]), complete: true,
                                  current: .sonnet55)?.candidate?.id, "claude-sonnet-6",
                       "a list that stops sending lifecycle must not silence discovery")
    }

    func testANewerSonnetWithAnUnknownLifecycleIsNotOffered() throws {
        let preview = D.entry("claude-sonnet-6", created: "2027-03-01T00:00:00Z", lifecycle: "preview")
        XCTAssertNil(modelOffer(listed: try D.listed(D.today + [preview]), complete: true, current: .sonnet55))
    }

    func testAnUndatedSonnetNeverHidesADatedOne() throws {
        let undated = D.entry("claude-sonnet-5-7", created: "not a date")
        XCTAssertEqual(modelOffer(listed: try D.listed(D.today + [undated, D.sonnet6]), complete: true,
                                  current: .sonnet55)?.candidate?.id, "claude-sonnet-6")
        let o = try XCTUnwrap(modelOffer(listed: try D.listed(D.today + [undated]), complete: true,
                                         current: SopModelId(rawValue: "claude-sonnet-4-5-20250929")))
        XCTAssertEqual(o.candidate?.id, "claude-sonnet-5-5", "the replacement is a dated model, not the undated one")
    }

    // MARK: Turning AI off stops the check

    /// Resolving an SSO credential can take two round trips; a check cancelled in
    /// that window (AI turned off, the credential changed) sends nothing more.
    func testACancelledCheckSendsNothing() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        let svc = SopService(
            client: ClaudeClient(transport: MockTransport(dataHandler: { req in
                rec.add(req); return (D.page(D.today), ResponseHead(status: 200))
            })),
            keyStore: StubKeyStore())
        let task = Task { () async throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await svc.listModels(settings: SopSettings()).models.count
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(rec.all.count, 0)
    }

    func testAListingCancelledBetweenPagesStopsThere() async throws {
        let rec = SonnetFiveFiveTests.Recorder()
        let gate = CancelAfterFirst()
        let client = ClaudeClient(transport: MockTransport(dataHandler: { req in
            rec.add(req)
            gate.cancelOwner()
            return (D.page([D.today[0]], hasMore: true, lastId: "p\(rec.all.count)"), ResponseHead(status: 200))
        }))
        let task = Task { () async throws -> Int in
            gate.owner = withUnsafeCurrentTask { $0 }.map(UnsafeTaskHandle.init)
            return try await client.listModels(credential: .apiKey("sk-ant-test")).models.count
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(rec.all.count, 1, "no further page after the cancel")
    }
}

/// Lets a transport handler cancel the task that is listing, between pages.
private struct UnsafeTaskHandle: @unchecked Sendable {
    let task: UnsafeCurrentTask
    init(_ t: UnsafeCurrentTask) { task = t }
}

private final class CancelAfterFirst: @unchecked Sendable {
    private let lock = NSLock()
    private var _owner: UnsafeTaskHandle?
    var owner: UnsafeTaskHandle? {
        get { lock.withLock { _owner } }
        set { lock.withLock { _owner = newValue } }
    }
    func cancelOwner() { owner?.task.cancel() }
}
