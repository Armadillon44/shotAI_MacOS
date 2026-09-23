import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// Review, retry, repair, and apply-what-passed, driven through the REAL
/// `SopService.generate` with a transport that answers each request in turn.
final class SopValidationTests: XCTestCase {

    /// Answers request k with `replies[k]`, and records every request body.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [([String], ResponseHead)]
        private(set) var bodies: [String] = []
        init(_ replies: [([String], ResponseHead)]) { self.replies = replies }
        func next(_ req: URLRequest) -> ([String], ResponseHead) {
            lock.lock(); defer { lock.unlock() }
            bodies.append(String(decoding: req.httpBody ?? Data(), as: UTF8.self))
            return replies.isEmpty ? ([], ResponseHead(status: 500)) : replies.removeFirst()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return bodies.count }
    }

    private func ok(_ steps: [(Int, String, String)], title: String = "A Real Title",
                    intro: (String, String)? = nil) -> ([String], ResponseHead) {
        // Every entry declares itself a screenshot, as a model writing screenshot
        // text would. That is what makes the renumbering fixtures below meaningful:
        // their numbers are all valid now, and only the kind gives them away.
        let s: [[String: Any]] = steps.map {
            ["stepNumber": $0.0, "kind": "screenshot", "caption": $0.1, "body": $0.2,
             "sectionHeading": NSNull(), "sectionBody": NSNull()]
        }
        let i: Any = intro.map { ["heading": $0.0, "body": $0.1] } ?? NSNull()
        let d = try! JSONSerialization.data(withJSONObject: ["title": title, "intro": i, "steps": s])
        return (sseLines(json: String(decoding: d, as: UTF8.self)), ResponseHead(status: 200))
    }
    private let overloaded: ([String], ResponseHead) = ([], ResponseHead(status: 529))

    private func run(_ shots: Int, textFirst: Bool = false, _ script: Script)
        async throws -> (store: ProjectStore, path: String, before: ProjectManifest, plan: SopEditPlan)
    {
        let (store, path, dir) = try await makeProject(shots: shots)
        if textFirst { _ = try await store.addTextStep(at: path, atIndex: 0, heading: "Before you start") }
        let manifest = try await store.openProject(at: path).manifest
        var svc = SopService(client: ClaudeClient(transport: MockTransport(streamHandler: script.next)),
                             keyStore: StubKeyStore())
        svc.sleep = { _ in }
        let plan = try await svc.generate(dir: dir, manifest: manifest, settings: SopSettings(), onProgress: { _ in })
        return (store, path, manifest, plan)
    }

    private func applied(_ r: (store: ProjectStore, path: String, before: ProjectManifest, plan: SopEditPlan))
        async throws -> [ProjectStep]
    {
        try await applySopEdits(store: r.store, projectPath: r.path, plan: r.plan, model: .sonnet5, tone: .professional)
        return try await r.store.openProject(at: r.path).manifest.steps.filter { $0.kind != .text }
    }

    // MARK: Repair

    func testAFillerCaptionIsRepairedAndOnlyThatStepIsAskedFor() async throws {
        let script = Script([
            ok([(1, "Open Settings", "Click the gear."), (2, "Placeholder", "TBD"), (3, "Save", "Press Save.")]),
            ok([(2, "Choose Privacy", "Select the Privacy tab.")]),
        ])
        let r = try await run(3, script)
        let steps = try await applied(r)
        XCTAssertEqual(steps.map(\.caption), ["Open Settings", "Choose Privacy", "Save"])
        XCTAssertTrue(r.plan.incompleteStepIds.isEmpty)
        XCTAssertEqual(script.count, 2, "one repair turn, no full retry")

        // The body repeats the whole original request (images and all), so the
        // assertions are about the instruction the repair ADDS, not the body.
        let repair = try XCTUnwrap(script.bodies.dropFirst().first, "no repair request was made")
        XCTAssertTrue(repair.contains(#""role":"assistant""#), "it shows the model its own previous answer")
        let at = try XCTUnwrap(repair.range(of: "These screenshot steps still need their text: "))
        let ask = String(repair[at.upperBound...].prefix { $0 != "." })
        XCTAssertEqual(ask, "Screenshot step 2", "the repair names exactly the step it wants")
        // The prompt we add never names a filler value. (The model's own previous
        // answer, echoed back as the assistant turn, of course still contains it.)
        XCTAssertFalse(repair[at.lowerBound...].lowercased().contains("placeholder"))
    }

    func testAMissingStepIsRepaired() async throws {
        let script = Script([
            ok([(1, "Open Settings", "Click the gear."), (3, "Save", "Press Save.")]),
            ok([(2, "Choose Privacy", "Select the Privacy tab.")]),
        ])
        let steps = try await applied(run(3, script))
        XCTAssertEqual(steps.map(\.caption), ["Open Settings", "Choose Privacy", "Save"])
    }

    /// The reviewer's reproduction: steps 2 and 5 come back as filler, and the
    /// repair answers with its own numbering, [1, 2]. Trusting it put step 5's text
    /// on step 2 and reported step 2 complete. A repair whose numbers stray outside
    /// what it was asked for is discarded whole.
    func testARepairThatRenumbersIsDiscardedNotMerged() async throws {
        let script = Script([
            ok([(1, "Open A", "a."), (2, "Placeholder", "TBD"), (3, "Open C", "c."),
                (4, "Open D", "d."), (5, "Placeholder", "TBD")]),
            ok([(1, "Text written for step 2", "x."), (2, "Text written for step 5", "y.")]),
        ])
        let r = try await run(5, script)
        let before = r.before.steps.map(\.caption)
        let steps = try await applied(r)
        XCTAssertEqual(steps[1].caption, before[1], "step 2 must not receive step 5's text")
        XCTAssertEqual(steps[4].caption, before[4])
        XCTAssertEqual(Set(r.plan.incompleteStepIds), [r.before.steps[1].id, r.before.steps[4].id],
                       "both steps are reported incomplete, not one of them as done")
    }

    /// Every repair target is a screenshot, so a repair entry declaring any other kind
    /// misread which block it was writing for, and is discarded with the rest of the
    /// repair — author-block text must not land on a screenshot.
    func testARepairEntryDeclaringAnAuthorKindIsDiscarded() async throws {
        let bad: [[String: Any]] = [["stepNumber": 2, "kind": "note", "caption": "Heads up", "body": "Watch out.",
                                     "sectionHeading": NSNull(), "sectionBody": NSNull()]]
        let d = try JSONSerialization.data(withJSONObject: ["title": "A Real Title", "intro": NSNull(), "steps": bad])
        let script = Script([
            ok([(1, "Open Settings", "Click the gear."), (2, "Placeholder", "TBD")]),
            (sseLines(json: String(decoding: d, as: UTF8.self)), ResponseHead(status: 200)),
        ])
        let r = try await run(2, script)
        let steps = try await applied(r)
        XCTAssertNotEqual(steps[1].caption, "Heads up")
        XCTAssertEqual(r.plan.incompleteStepIds, [r.before.steps[1].id])
    }

    // MARK: Apply what passed

    func testAStepThatStaysBadAfterRepairKeepsItsTextAndTheRestLands() async throws {
        let script = Script([
            ok([(1, "Open Settings", "Click the gear."), (2, "[caption]", "…"), (3, "Save", "Press Save.")]),
            ok([(2, "", "")]),
        ])
        let r = try await run(3, script)
        let before = r.before.steps.map(\.caption)
        let steps = try await applied(r)
        XCTAssertEqual(steps[0].caption, "Open Settings")
        XCTAssertEqual(steps[1].caption, before[1], "the unrepaired step keeps its previous caption")
        XCTAssertFalse(steps[1].caption.contains("["), "filler never lands")
        XCTAssertEqual(steps[2].caption, "Save")
        XCTAssertEqual(r.plan.incompleteStepIds, [r.before.steps[1].id])
    }

    /// A repair that fails outright must not cost the steps that came back good.
    func testAFailedRepairStillAppliesWhatPassed() async throws {
        let script = Script([
            ok([(1, "Open Settings", "Click the gear."), (2, "Placeholder", "TBD")]),
            overloaded,
        ])
        let r = try await run(2, script)
        let steps = try await applied(r)
        XCTAssertEqual(steps[0].caption, "Open Settings")
        XCTAssertEqual(r.plan.incompleteStepIds, [r.before.steps[1].id])
    }

    /// One usable field is kept even when the other is not.
    func testAGoodCaptionLandsWhenOnlyTheBodyIsFiller() async throws {
        let script = Script([
            ok([(1, "Open Settings", "N/A")]),
            ok([(1, "Open Settings", "")]),
        ])
        let r = try await run(1, script)
        let before = r.before.steps[0].body
        let steps = try await applied(r)
        XCTAssertEqual(steps[0].caption, "Open Settings")
        XCTAssertEqual(steps[0].body, before ?? "", "the filler body is withheld")
        XCTAssertEqual(r.plan.incompleteStepIds.count, 1, "and the step is reported as incomplete")
    }

    // MARK: Numbering

    /// The renumbering shape: a text block first, so the screenshots are 2, 3, 4,
    /// and the model numbers them 1, 2, 3. Applying any of it would shift every
    /// caption one step late, so the whole request runs again.
    func testARenumberedPlanIsRetriedWholeNotAppliedPartly() async throws {
        let script = Script([
            ok([(1, "A", "a."), (2, "B", "b."), (3, "C", "c.")]),
            ok([(2, "A", "a."), (3, "B", "b."), (4, "C", "c.")]),
        ])
        let steps = try await applied(run(3, textFirst: true, script))
        XCTAssertEqual(steps.map(\.caption), ["A", "B", "C"])
        XCTAssertEqual(script.count, 2)
    }

    func testRenumberedTwiceAppliesNothing() async throws {
        let script = Script([
            ok([(1, "A", "a."), (2, "B", "b."), (3, "C", "c.")]),
            ok([(1, "A", "a."), (2, "B", "b."), (3, "C", "c.")]),
        ])
        do {
            _ = try await run(3, textFirst: true, script)
            XCTFail("a plan whose numbering cannot be trusted must not be applied")
        } catch let e as ClaudeError {
            XCTAssertEqual(e, .incomplete(wroteNothing: false))
        }
    }

    /// Retry for numbering, then repair for content: three requests, never more.
    func testNeverMoreThanThreeRequests() async throws {
        let script = Script([
            ok([(1, "A", "a."), (2, "B", "b."), (3, "C", "c.")]),
            ok([(2, "A", "a."), (3, "Placeholder", "b."), (4, "C", "c.")]),
            ok([(3, "", "")]),
            ok([(3, "B", "b.")]),
        ])
        let r = try await run(3, textFirst: true, script)
        XCTAssertEqual(script.count, 3)
        XCTAssertEqual(r.plan.incompleteStepIds.count, 1)
    }

    func testAFillerSectionBodyIsWithheld() async throws {
        let raw: [[String: Any]] = [["stepNumber": 1, "caption": "Open Settings", "body": "Click the gear.",
                                     "sectionHeading": "Configure the account", "sectionBody": "Placeholder"]]
        let d = try JSONSerialization.data(withJSONObject: ["title": "A Real Title", "intro": NSNull(), "steps": raw])
        let script = Script([(sseLines(json: String(decoding: d, as: UTF8.self)), ResponseHead(status: 200))])
        let r = try await run(1, script)
        try await applySopEdits(store: r.store, projectPath: r.path, plan: r.plan, model: .sonnet5, tone: .professional)
        let section = try await r.store.openProject(at: r.path).manifest.steps.first { $0.aiInserted == true }
        XCTAssertEqual(section?.heading, "Configure the account", "a good heading still lands")
        XCTAssertEqual(section?.body ?? "", "", "its filler body does not")
    }

    // MARK: Title and overview

    func testAFillerTitleKeepsTheCurrentName() async throws {
        let script = Script([ok([(1, "Open Settings", "Click the gear.")], title: "Untitled")])
        let r = try await run(1, script)
        try await applySopEdits(store: r.store, projectPath: r.path, plan: r.plan, model: .sonnet5, tone: .professional)
        let title = try await r.store.openProject(at: r.path).manifest.title
        XCTAssertEqual(title, r.before.title)
    }

    /// An overview whose body is filler is dropped rather than landing as a heading
    /// over nothing, and an overview the AUTHOR wrote survives it untouched.
    func testAFillerOverviewNeverReplacesTheAuthorsOwn() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        _ = try await store.setIntro(at: path, heading: "Scope", body: "Only for the Finance team.")
        let manifest = try await store.openProject(at: path).manifest
        let script = Script([ok([(1, "Open Settings", "Click the gear.")], intro: ("Overview", "Placeholder"))])
        var svc = SopService(client: ClaudeClient(transport: MockTransport(streamHandler: script.next)),
                             keyStore: StubKeyStore())
        svc.sleep = { _ in }
        let plan = try await svc.generate(dir: dir, manifest: manifest, settings: SopSettings(), onProgress: { _ in })
        XCTAssertNil(plan.intro)
        try await applySopEdits(store: store, projectPath: path, plan: plan, model: .sonnet5, tone: .professional)
        let intro = try await store.openProject(at: path).manifest.intro
        XCTAssertEqual(intro?.body, "Only for the Finance team.")
    }

    // MARK: The notice names steps as the report numbers them

    /// A note callout is numbered by the model (text blocks count) but not by the
    /// report. The screenshot the model called 3 is the report's step 2.
    func testTheNoticeUsesTheReportsNumbersNotTheModels() {
        func shot(_ id: String) -> ProjectStep {
            ProjectStep(id: id, order: 0, kind: .shot, screenshot: "shots/\(id).png", trigger: .hotkey)
        }
        let note = ProjectStep(id: "n", order: 0, kind: .text, screenshot: "", trigger: .hotkey,
                               heading: "Heads up", callout: .note)
        let steps = [shot("a"), note, shot("b"), shot("c")]
        XCTAssertEqual(numberedBase(ProjectManifest(id: "p", title: "T", createdAt: "a", updatedAt: "b",
                                                    steps: steps)).first { $0.step.id == "b" }?.number, 3,
                       "fixture: the model sees b as step 3")
        let text = incompleteNotice(["b"], in: steps)
        XCTAssertEqual(text?.hasPrefix("Wrote 2 of 3 screenshot steps. Step 2 is incomplete"), true, text ?? "nil")
        XCTAssertEqual(incompleteNotice(["a", "c"], in: steps)?.contains("Steps 1 and 3 are incomplete"), true)
        XCTAssertNil(incompleteNotice([], in: steps))
    }

    // MARK: What counts as filler

    func testFillerIsCaughtAndRealTextIsNot() {
        for s in ["", "   ", "Placeholder", "placeholder.", "TBD", "N/A", "[caption]", "<body>", "{text}",
                  "…", "—", "Lorem ipsum dolor", "Step 3", "Screenshot step 4", "Untitled", "  none  "] {
            XCTAssertTrue(isFiller(s), "should be filler: \(s.debugDescription)")
        }
        for s in ["Open Settings", "Click Save", "Enter the title", "Select None from the list",
                  "Step into the Billing tab", "Type N/A in the Notes field", "Review the description",
                  "OK", "Go", "[Optional] Enter the PO number [if required]", "<Ctrl> + <S>",
                  "{Vendor} and {Site}", "Press <Enter>"] {
            XCTAssertFalse(isFiller(s), "real instruction flagged as filler: \(s.debugDescription)")
        }
    }
}
