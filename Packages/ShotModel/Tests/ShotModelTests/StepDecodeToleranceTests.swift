import Foundation
import Testing
@testable import ShotModel

/// Decoding a step array must degrade, never die and never take the good data
/// with it. Both bugs here shipped, and both were invisible: one killed the
/// process, the other emptied a project in silence.
@Suite struct StepDecodeTolerance {
    private let good = #"{"id":"s1","order":0,"kind":"shot","screenshot":"shots/a.png","trigger":"click"}"#

    private func manifest(steps: String) -> ProjectManifest? {
        let json = #"{"id":"p","title":"T","createdWith":"shotAI","createdAt":"a","updatedAt":"b","steps":\#(steps)}"#
        return try? ProjectJSON.decoder().decode(ProjectManifest.self, from: Data(json.utf8))
    }

    // MARK: #107 — the trap

    /// `Int(Double)` traps on overflow, and a trap is a fatalError rather than a
    /// throw: no `try?` catches it and the process dies. Home scans every project
    /// on launch, so one hand-edited or foreign-written file took the whole app
    /// down with nothing naming the culprit.
    @Test func anAbsurdOrderDoesNotCrashTheProcess() {
        let step = #"{"id":"s1","order":1e21,"kind":"shot","screenshot":"a.png","trigger":"click"}"#
        let m = manifest(steps: "[\(step)]")
        #expect(m?.steps.count == 1, "the step must survive, not just the process")
        #expect(m?.steps.first?.order == Int.max, "clamped, so it still sorts where it asked to")
    }

    @Test func aNegativeAbsurdOrderIsAlsoSafe() {
        let step = #"{"id":"s1","order":-1e21,"kind":"shot","screenshot":"a.png","trigger":"click"}"#
        #expect(manifest(steps: "[\(step)]")?.steps.first?.order == 0)
    }

    /// Windows passes `order` through untouched, so a manifest carrying 1e21
    /// round-trips there and used to crash here. That asymmetry is the whole
    /// reason the value has to be survivable rather than merely legal.
    @Test func aRealisticOrderIsUnaffected() {
        let step = #"{"id":"s1","order":7,"kind":"shot","screenshot":"a.png","trigger":"click"}"#
        #expect(manifest(steps: "[\(step)]")?.steps.first?.order == 7)
    }

    // MARK: #108 — one bad element must not cost the array

    /// `try? decode([ProjectStep].self)` fails as a UNIT. One junk entry
    /// discarded every good step, and the next save wrote `"steps": []` over real
    /// work with nothing shown to the user.
    @Test(arguments: ["42", "null", #""x""#, "[]", "true"])
    func oneJunkEntryCostsOnlyThatEntry(_ junk: String) {
        let m = manifest(steps: "[\(good), \(junk)]")
        #expect(m?.steps.count == 1, "junk \(junk) took the valid step with it")
        #expect(m?.steps.first?.id == "s1")
    }

    @Test func junkInTheMiddleKeepsBothNeighbours() {
        let b = #"{"id":"s2","order":1,"kind":"shot","screenshot":"shots/b.png","trigger":"click"}"#
        let m = manifest(steps: "[\(good), 42, \(b)]")
        #expect(m?.steps.map(\.id) == ["s1", "s2"])
    }

    /// An empty object is a VALID step, not junk: every field has a default, so it
    /// decodes to a skeletal step. Dropping it would be a different bug, and it is
    /// what Windows does too.
    @Test func anEmptyObjectIsAStepAndIsKept() {
        #expect(manifest(steps: "[\(good), {}]")?.steps.count == 2)
    }

    /// The surviving step must come back WHOLE, not merely present.
    @Test func theSurvivingStepRoundTripsIntact() throws {
        let m = try #require(manifest(steps: "[\(good), 42]"))
        let obj = try JSONSerialization.jsonObject(
            with: try ProjectJSON.encoder().encode(m)) as? [String: Any]
        let step = (obj?["steps"] as? [[String: Any]])?.first
        #expect(step?["id"] as? String == "s1")
        #expect(step?["kind"] as? String == "shot")
        #expect(step?["screenshot"] as? String == "shots/a.png")
    }

    /// A `steps` that is not an array at all still yields an empty list rather
    /// than throwing — unchanged behaviour, pinned so the new element-wise path
    /// does not quietly alter it.
    @Test(arguments: ["{}", "\"nope\"", "5", "null"])
    func aNonArrayStepsValueIsStillAnEmptyList(_ notAnArray: String) {
        #expect(manifest(steps: notAnArray)?.steps.isEmpty == true)
    }
}

/// #112 — the same array-as-a-unit defect as #108, one level down, where what it
/// cost was the user's one-click revert rather than their steps.
///
/// The comment there claimed dropping the whole backup mirrored Windows'
/// `coerceSopBackup`. Measured against the shipping Windows build, it did not:
/// that calls `normalizeSteps`, which drops the bad element and keeps the rest.
@Suite struct SopBackupTolerance {
    private func manifest(backupSteps: String) -> ProjectManifest? {
        let json = #"""
        {"id":"p","title":"T","createdWith":"shotAI","createdAt":"a","updatedAt":"b","steps":[],
         "sopBackup":{"steps":\#(backupSteps),"title":"Backed up","model":"m","tone":"professional","at":"x"}}
        """#
        return try? ProjectJSON.decoder().decode(ProjectManifest.self, from: Data(json.utf8))
    }
    private let good = #"{"id":"s1","order":0,"kind":"shot","screenshot":"shots/a.png","trigger":"click"}"#

    @Test(arguments: ["42", "null", #""x""#, "[]", "true"])
    func oneBadElementDoesNotDiscardTheWholeBackup(_ junk: String) throws {
        let m = try #require(manifest(backupSteps: "[\(good), \(junk)]"))
        let b = try #require(m.sopBackup, "junk \(junk) destroyed the revert history")
        #expect(b.steps.count == 1)
        #expect(b.steps.first?.id == "s1")
        #expect(b.title == "Backed up", "the rest of the backup must survive too")
    }

    /// PARITY, deliberately kept: a `steps` that is not an array at all, or a
    /// non-string title, still drops the whole backup. Windows does the same.
    @Test(arguments: [#""not an array""#, "42", "{}", "null"])
    func aNonArrayStepsStillDropsTheBackup(_ notAnArray: String) {
        #expect(manifest(backupSteps: notAnArray)?.sopBackup == nil)
    }

    /// The control: a clean backup is untouched.
    @Test func acleanBackupSurvivesIntact() throws {
        let m = try #require(manifest(backupSteps: "[\(good)]"))
        #expect(m.sopBackup?.steps.count == 1)
        #expect(m.sopBackup?.title == "Backed up")
    }
}
