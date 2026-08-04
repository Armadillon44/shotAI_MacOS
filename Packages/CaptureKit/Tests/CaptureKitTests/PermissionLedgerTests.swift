import Foundation
import Testing

@testable import CaptureKit

/// The update-orphaned-TCC detector (#62). Every case here is a launch sequence:
/// what was granted, under which build identity, and what the app should conclude.
@Suite("PermissionLedger")
struct PermissionLedgerTests {
    typealias Snapshot = PermissionLedger.Snapshot

    private func snapshot(
        _ identity: String, label: String = "1.1.2 (8)", granted: [CapturePermission]
    ) -> Snapshot {
        Snapshot(identity: identity, versionLabel: label, granted: granted.map(\.rawValue))
    }

    /// A `Store` on an isolated defaults domain, so tests never touch the app's.
    private func isolatedStore(_ name: String = UUID().uuidString) -> PermissionLedger.Store {
        PermissionLedger.Store(defaults: UserDefaults(suiteName: name)!, key: "test.ledger")
    }

    // MARK: - The decision

    @Test("first launch is not an update")
    func firstLaunch() {
        let v = PermissionLedger.evaluate(previous: nil, identity: "cdhash:aaa", granted: [])
        #expect(v.isFirstLaunch)
        #expect(!v.shouldPrompt)
        #expect(v.lost.isEmpty)
        #expect(!v.didChangeIdentity)
    }

    @Test("same build, same grants — nothing to say")
    func steadyState() {
        let prev = snapshot("cdhash:aaa", granted: [.screenRecording, .accessibility])
        let v = PermissionLedger.evaluate(
            previous: prev, identity: "cdhash:aaa", granted: [.screenRecording, .accessibility])
        #expect(!v.shouldPrompt)
        #expect(!v.didChangeIdentity)
    }

    @Test("an update that keeps the grants says nothing")
    func updateWithGrantsIntact() {
        let prev = snapshot("cdhash:aaa", granted: [.screenRecording, .accessibility])
        let v = PermissionLedger.evaluate(
            previous: prev, identity: "cdhash:bbb", granted: [.screenRecording, .accessibility])
        #expect(v.didChangeIdentity)
        #expect(!v.shouldPrompt, "Developer ID builds keep their grants — no prompt")
    }

    @Test("an update that orphans every grant reports all three")
    func updateOrphansEverything() {
        let prev = snapshot("cdhash:aaa", granted: CapturePermission.allCases)
        let v = PermissionLedger.evaluate(previous: prev, identity: "cdhash:bbb", granted: [])
        #expect(v.shouldPrompt)
        #expect(v.lost == [.screenRecording, .accessibility, .inputMonitoring])
        #expect(v.previousVersionLabel == "1.1.2 (8)")
    }

    @Test("only the permissions that were actually granted are reported")
    func reportsOnlyWhatWasHeld() {
        // The user never granted Input Monitoring (the UI calls it "usually not
        // needed"), so losing it is impossible and it must not be listed.
        let prev = snapshot("cdhash:aaa", granted: [.screenRecording, .accessibility])
        let v = PermissionLedger.evaluate(previous: prev, identity: "cdhash:bbb", granted: [])
        #expect(v.lost == [.screenRecording, .accessibility])
    }

    @Test("a partial loss reports only the missing one")
    func partialLoss() {
        let prev = snapshot("cdhash:aaa", granted: [.screenRecording, .accessibility])
        let v = PermissionLedger.evaluate(
            previous: prev, identity: "cdhash:bbb", granted: [.accessibility])
        #expect(v.lost == [.screenRecording])
    }

    /// The condition that keeps this from becoming a nag. Revoking a permission
    /// yourself, with no update in between, is a deliberate act.
    @Test("revoking a permission WITHOUT an update is not reported")
    func deliberateRevocationIsSilent() {
        let prev = snapshot("cdhash:aaa", granted: [.screenRecording, .accessibility])
        let v = PermissionLedger.evaluate(
            previous: prev, identity: "cdhash:aaa", granted: [.accessibility])
        #expect(!v.shouldPrompt)
        #expect(v.lost.isEmpty)
    }

    @Test("gaining a permission across an update is not a loss")
    func gainingIsNotLosing() {
        let prev = snapshot("cdhash:aaa", granted: [.screenRecording])
        let v = PermissionLedger.evaluate(
            previous: prev, identity: "cdhash:bbb",
            granted: [.screenRecording, .accessibility, .inputMonitoring])
        #expect(!v.shouldPrompt)
    }

    @Test("the lost list reads as a sentence", arguments: [
        ([CapturePermission.screenRecording], "Screen Recording"),
        ([.screenRecording, .accessibility], "Screen Recording and Accessibility"),
        ([.screenRecording, .accessibility, .inputMonitoring],
         "Screen Recording, Accessibility, and Input Monitoring"),
    ])
    func lostListGrammar(_ lost: [CapturePermission], _ expected: String) {
        let v = PermissionLedger.Verdict(
            lost: lost, isFirstLaunch: false, didChangeIdentity: true, previousVersionLabel: nil)
        #expect(v.lostList == expected)
    }

    // MARK: - Persistence and the commit rule

    @Test("a clean launch commits the new baseline")
    func commitsWhenClean() {
        let store = isolatedStore()
        _ = store.record(identity: "cdhash:aaa", versionLabel: "1.1.2 (8)",
                         granted: [.screenRecording, .accessibility])
        let saved = store.load()
        #expect(saved?.identity == "cdhash:aaa")
        #expect(saved?.granted == ["accessibility", "screenRecording"])
    }

    /// The commit rule: while a loss is outstanding the OLD snapshot stays, so
    /// every launch keeps explaining it. Capture is still broken and the reason
    /// is still the update.
    @Test("an outstanding loss keeps being reported on every launch")
    func lossPersistsUntilResolved() {
        let store = isolatedStore()
        _ = store.record(identity: "cdhash:aaa", versionLabel: "1.1.2 (8)",
                         granted: Set(CapturePermission.allCases))

        for launch in 1...3 {
            let v = store.record(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)", granted: [])
            #expect(v.shouldPrompt, "launch \(launch) after the update should still explain itself")
            #expect(v.lost.count == 3)
            #expect(store.load()?.identity == "cdhash:aaa", "must not commit while unresolved")
        }
    }

    @Test("re-granting everything resolves it, permanently")
    func resolvingCommits() {
        let store = isolatedStore()
        _ = store.record(identity: "cdhash:aaa", versionLabel: "1.1.2 (8)",
                         granted: [.screenRecording, .accessibility])
        #expect(store.record(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)", granted: []).shouldPrompt)

        // User re-grants both.
        let fixed = store.record(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)",
                                 granted: [.screenRecording, .accessibility])
        #expect(!fixed.shouldPrompt)
        #expect(store.load()?.identity == "cdhash:bbb")

        // And it stays quiet.
        #expect(!store.record(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)",
                              granted: [.screenRecording, .accessibility]).shouldPrompt)
    }

    @Test("a partial re-grant still reports what is still missing")
    func partialRegrantStillReports() {
        let store = isolatedStore()
        _ = store.record(identity: "cdhash:aaa", versionLabel: "1.1.2 (8)",
                         granted: [.screenRecording, .accessibility])
        _ = store.record(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)", granted: [])

        let v = store.record(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)",
                             granted: [.screenRecording])
        #expect(v.lost == [.accessibility])
        #expect(store.load()?.identity == "cdhash:aaa", "still unresolved, still not committed")
    }

    /// The escape hatch: someone who decided they no longer want a permission
    /// must not be asked on every launch forever.
    @Test("acknowledging stops the prompt without re-granting")
    func acknowledgeSilences() {
        let store = isolatedStore()
        _ = store.record(identity: "cdhash:aaa", versionLabel: "1.1.2 (8)",
                         granted: [.screenRecording, .inputMonitoring])
        #expect(store.record(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)",
                             granted: [.screenRecording]).shouldPrompt)

        store.acknowledge(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)",
                          granted: [.screenRecording])

        let after = store.record(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)",
                                 granted: [.screenRecording])
        #expect(!after.shouldPrompt)
        #expect(store.load()?.granted == ["screenRecording"])
    }

    @Test("a second update after an acknowledged one is judged against the new baseline")
    func baselineMovesAfterAcknowledge() {
        let store = isolatedStore()
        _ = store.record(identity: "cdhash:aaa", versionLabel: "1.1.2 (8)",
                         granted: [.screenRecording, .inputMonitoring])
        _ = store.record(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)", granted: [.screenRecording])
        store.acknowledge(identity: "cdhash:bbb", versionLabel: "1.1.3 (9)", granted: [.screenRecording])

        // Next update orphans the one grant they kept.
        let v = store.record(identity: "cdhash:ccc", versionLabel: "1.1.4 (10)", granted: [])
        #expect(v.lost == [.screenRecording], "Input Monitoring was acknowledged away and must not return")
    }

    @Test("nothing is stored before the first record")
    func emptyStore() {
        let store = isolatedStore()
        #expect(store.load() == nil)
        #expect(store.record(identity: "cdhash:aaa", versionLabel: "1.1.2 (8)", granted: []).isFirstLaunch)
    }

    @Test("a snapshot round-trips and tolerates a partial blob")
    func codable() throws {
        let s = snapshot("cdhash:aaa", granted: [.screenRecording])
        #expect(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(s)) == s)

        let partial = try #require(#"{"identity":"cdhash:zzz"}"#.data(using: .utf8))
        let thin = try JSONDecoder().decode(Snapshot.self, from: partial)
        #expect(thin.identity == "cdhash:zzz")
        #expect(thin.granted.isEmpty)
        #expect(thin.versionLabel.isEmpty)
    }

    @Test("an unknown permission name in a stored blob is ignored, not crashed on")
    func unknownStoredPermission() {
        let prev = Snapshot(identity: "cdhash:aaa", versionLabel: "x",
                            granted: ["screenRecording", "somethingFromTheFuture"])
        let v = PermissionLedger.evaluate(previous: prev, identity: "cdhash:bbb", granted: [])
        #expect(v.lost == [.screenRecording])
    }

    // MARK: - Identity

    @Test("the running code has a readable identity")
    func identityIsReadable() {
        let id = PermissionLedger.currentIdentity()
        #expect(!id.isEmpty)
        #expect(id.hasPrefix("cdhash:") || id.hasPrefix("version:"))
        // Stable across calls — an unstable identity would fire the prompt forever.
        #expect(PermissionLedger.currentIdentity() == id)
    }

    @Test("a cdhash, when readable, is hex")
    func cdhashShape() throws {
        guard let hash = PermissionLedger.codeDirectoryHash() else { return }  // unsigned test host
        #expect(hash.count >= 40)
        #expect(hash.allSatisfy { $0.isHexDigit })
    }
}
