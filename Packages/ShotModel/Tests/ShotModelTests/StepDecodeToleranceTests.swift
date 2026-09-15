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
