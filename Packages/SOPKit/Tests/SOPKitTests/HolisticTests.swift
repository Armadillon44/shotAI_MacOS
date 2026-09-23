import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// The whole SOP is written: author blocks and callouts as well as screenshots
/// (Dylan, 2026-09-23). Driven through the real generate, assembler, apply and revert.
///
/// The drift and revert cases are the ones an adversarial review reproduced against a
/// first, flag-based version of this — each of which lost author text.
final class HolisticTests: XCTestCase {

    typealias Script = SopValidationTests.Script

    private func entry(_ n: Int, _ kind: String, _ caption: String, _ body: String) -> [String: Any] {
        ["stepNumber": n, "kind": kind, "caption": caption, "body": body, "sectionHeading": NSNull(), "sectionBody": NSNull()]
    }
    private func reply(_ steps: [[String: Any]]) -> ([String], ResponseHead) {
        let d = try! JSONSerialization.data(withJSONObject: ["title": "A Real Title", "intro": NSNull(), "steps": steps])
        return (sseLines(json: String(decoding: d, as: UTF8.self)), ResponseHead(status: 200))
    }

    /// [warning, shot, note (no heading), shot]
    private func project() async throws -> (store: ProjectStore, path: String, dir: String) {
        let (store, path, dir) = try await makeProject(shots: 2)
        _ = try await store.addTextStep(at: path, atIndex: 0, heading: "Stop first", body: "Power off the unit.", callout: .warning)
        _ = try await store.addTextStep(at: path, atIndex: 2, heading: "", body: "The menu may take a moment.", callout: .note)
        return (store, path, dir)
    }

    private func generate(_ store: ProjectStore, _ path: String, _ dir: String, _ script: Script) async throws -> SopEditPlan {
        let m = try await store.openProject(at: path).manifest
        var svc = SopService(client: ClaudeClient(transport: MockTransport(streamHandler: script.next)), keyStore: StubKeyStore())
        svc.sleep = { _ in }
        return try await svc.generate(dir: dir, manifest: m, settings: SopSettings(), onProgress: { _ in })
    }
    private func apply(_ store: ProjectStore, _ path: String, _ plan: SopEditPlan) async throws {
        try await applySopEdits(store: store, projectPath: path, plan: plan, model: .sonnet5, tone: .professional)
    }
    private func rewrite(_ store: ProjectStore, _ path: String, _ n: Int, _ heading: String, _ body: String) async throws {
        try await apply(store, path, SopEditPlan(title: "T", intro: nil, steps: [
            SopStepEdit(stepNumber: n, caption: heading, body: body, sectionHeading: nil, sectionBody: nil, kind: "warning")]))
    }
    private func sent(_ store: ProjectStore, _ path: String, _ dir: String) async throws -> String {
        let m = try await store.openProject(at: path).manifest
        let content = try assembleRequest(dir: dir, manifest: m, settings: SopSettings())
            .messages.first?["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    private func step(_ store: ProjectStore, _ path: String, _ id: String) async throws -> ProjectStep? {
        try await store.openProject(at: path).manifest.steps.first { $0.id == id }
    }

    // MARK: Author blocks are rewritten, never retyped or added to

    func testAuthorBlocksAreRewrittenAndKeepTheirKind() async throws {
        let (store, path, dir) = try await project()
        let plan = try await generate(store, path, dir, Script([reply([
            entry(1, "warning", "Switch it off first", "Power the unit off before you start."),
            entry(2, "screenshot", "Open Settings", "Click the gear."),
            entry(3, "note", "", "The menu can take a few seconds to appear."),
            entry(4, "screenshot", "Save", "Press Save."),
        ])]))
        try await apply(store, path, plan)
        let steps = try await store.openProject(at: path).manifest.steps.filter { $0.aiInserted != true }
        XCTAssertEqual(steps[0].heading, "Switch it off first")
        XCTAssertEqual(steps[0].body, "Power the unit off before you start.")
        XCTAssertEqual(steps[0].callout, .warning, "the kind of block is the author's, never Claude's")
        XCTAssertEqual(steps[2].body, "The menu can take a few seconds to appear.")
        XCTAssertEqual(steps[2].callout, .note)
    }

    /// Reword, never add: a field the author left empty stays empty, even when the
    /// model writes something for it.
    func testAFieldTheAuthorLeftEmptyIsNeverFilledIn() async throws {
        let (store, path, dir) = try await project()
        let plan = try await generate(store, path, dir, Script([reply([
            entry(1, "warning", "Switch it off first", "Power the unit off."),
            entry(2, "screenshot", "Open Settings", "Click the gear."),
            entry(3, "note", "An invented heading", "The menu can take a few seconds."),
            entry(4, "screenshot", "Save", "Press Save."),
        ])]))
        try await apply(store, path, plan)
        let note = try await store.openProject(at: path).manifest.steps.filter { $0.aiInserted != true }[2]
        XCTAssertEqual(note.heading ?? "", "", "the author's note had no heading, so it gets none")
    }

    func testFillerInAnAuthorBlockKeepsTheAuthorsTextWithoutARepairOrNotice() async throws {
        let (store, path, dir) = try await project()
        let script = Script([reply([
            entry(1, "warning", "Placeholder", "TBD"),
            entry(2, "screenshot", "Open Settings", "Click the gear."),
            entry(3, "note", "", "The menu can take a few seconds to appear."),
            entry(4, "screenshot", "Save", "Press Save."),
        ])])
        let plan = try await generate(store, path, dir, script)
        XCTAssertEqual(script.count, 1, "no repair for an author block")
        XCTAssertTrue(plan.incompleteStepIds.isEmpty)
        try await apply(store, path, plan)
        let warning = try await store.openProject(at: path).manifest.steps[0]
        XCTAssertEqual(warning.heading, "Stop first")
        XCTAssertEqual(warning.body, "Power off the unit.")
    }

    /// A section heading Claude attaches to an author block's entry is inserted before
    /// that block, as it is before a screenshot. It used to be dropped silently. Not
    /// before an author SECTION heading, which already marks that boundary.
    func testASectionHeadingOnAnAuthorBlockEntryIsInsertedBeforeIt() async throws {
        let (store, path, dir) = try await project()
        var e = entry(3, "note", "", "The menu can take a few seconds to appear.")
        e["sectionHeading"] = "Configure"
        let plan = try await generate(store, path, dir, Script([reply([
            entry(1, "warning", "Stop first", "Power off the unit."), entry(2, "screenshot", "Open", "Click."),
            e, entry(4, "screenshot", "Save", "Press Save.")])]))
        try await apply(store, path, plan)
        let steps = try await store.openProject(at: path).manifest.steps
        let at = try XCTUnwrap(steps.firstIndex { $0.aiInserted == true })
        XCTAssertEqual(steps[at].heading, "Configure")
        XCTAssertEqual(steps[at + 1].callout, .note, "inserted directly before the note")
    }

    // MARK: Numbering

    func testAScreenshotEntryAimedAtAnAuthorBlockIsMisnumbering() async throws {
        let (store, path, dir) = try await project()
        let script = Script([
            reply([entry(1, "screenshot", "Open Settings", "Click the gear."), entry(2, "screenshot", "Save", "Press Save.")]),
            reply([entry(2, "screenshot", "Open Settings", "Click the gear."), entry(4, "screenshot", "Save", "Press Save.")]),
        ])
        let plan = try await generate(store, path, dir, script)
        XCTAssertEqual(script.count, 2, "the whole request ran again")
        try await apply(store, path, plan)
        let first = try await store.openProject(at: path).manifest.steps[0]
        XCTAssertEqual(first.heading, "Stop first")
    }

    /// Screenshot-versus-text alone could not see a shift BETWEEN author blocks: the
    /// warning's text written at the section heading's number. The declared kind names
    /// the block's actual type, so it can.
    func testAWarningsTextAimedAtASectionHeadingIsMisnumbering() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        _ = try await store.addTextStep(at: path, atIndex: 0, heading: "Stop first", body: "Power off.", callout: .warning)
        _ = try await store.addTextStep(at: path, atIndex: 1, heading: "Setup", body: "", callout: .section)
        let script = Script([
            reply([entry(2, "warning", "Stop first", "Power off."), entry(3, "screenshot", "Open", "Click.")]),
            reply([entry(1, "warning", "Stop first", "Power off."), entry(3, "screenshot", "Open", "Click.")]),
        ])
        _ = try await generate(store, path, dir, script)
        XCTAssertEqual(script.count, 2, "caught as misnumbering and rerun")
    }

    func testTheSchemaAllowsExactlyTheNumbersOfTheBlocksShown() async throws {
        let (store, path, dir) = try await project()
        let script = Script([reply([entry(2, "screenshot", "Open Settings", "Click the gear.")])])
        _ = try await generate(store, path, dir, script)
        XCTAssertTrue(try XCTUnwrap(script.bodies.first).contains(#""stepNumber":{"type":"integer","enum":[1,2,3,4]}"#))
    }

    // MARK: No drift: the next run is fed the author's words, not Claude's

    func testTheNextRunIsSentTheAuthorsWordsNotTheRewrite() async throws {
        let (store, path, dir) = try await project()
        try await rewrite(store, path, 1, "AI heading", "AI body")
        let text = try await sent(store, path, dir)
        XCTAssertTrue(text.contains("Body: Power off the unit."))
        XCTAssertFalse(text.contains("AI body"))
    }

    /// The review's reproduction: an edit made WITHOUT any flag — as Windows and every
    /// earlier macOS build save it — used to be replaced by the stale pre-generation
    /// text, and the warning's added requirement was lost. A change from what Claude
    /// wrote is recognised as the author's however it was saved.
    func testAnUnflaggedEditFromAnotherBuildIsKeptAndSent() async throws {
        let (store, path, dir) = try await project()
        try await rewrite(store, path, 1, "AI heading", "AI body")
        _ = try await store.mutate(at: path) { $0.steps[0].body = "Power off the unit AND lock out the breaker." }
        let text = try await sent(store, path, dir)
        XCTAssertTrue(text.contains("Body: Power off the unit AND lock out the breaker."),
                      "the requirement the author added reaches Claude")
    }

    /// The review's second reproduction: a block added AFTER the first generation is
    /// in no backup. Rewritten by the second, it used to be unrecoverable, and the
    /// third run was fed Claude's text as the author's.
    func testABlockAddedAfterTheFirstGenerationKeepsItsAuthorsWords() async throws {
        let (store, path, dir) = try await makeProject(shots: 2)
        try await apply(store, path, SopEditPlan(title: "T", intro: nil, steps: [
            SopStepEdit(stepNumber: 1, caption: "A", body: "a.", sectionHeading: nil, sectionBody: nil, kind: "screenshot")]))
        _ = try await store.addTextStep(at: path, atIndex: 0, heading: "Hot", body: "Wear gloves; the housing is 300 C.", callout: .warning)
        let id = try await store.openProject(at: path).manifest.steps[0].id
        try await rewrite(store, path, 1, "Careful", "Be careful.")

        let third = try await sent(store, path, dir)
        XCTAssertTrue(third.contains("Body: Wear gloves; the housing is 300 C."), "the next run gets the author's words")
        try await revertSop(store: store, projectPath: path)
        let back = try await step(store, path, id)
        XCTAssertEqual(back?.body, "Wear gloves; the housing is 300 C.", "and Revert gives them back")
    }

    /// The review's third reproduction: an author's correction used to survive exactly
    /// one regeneration, then fall back to the pre-generation text.
    func testAnAuthorsCorrectionSurvivesRepeatedRegenerations() async throws {
        let (store, path, dir) = try await project()
        try await rewrite(store, path, 1, "AI heading", "AI body")
        _ = try await store.editStepText(at: path, stepId: try await store.openProject(at: path).manifest.steps[0].id,
                                         body: "Power off and lock out the breaker.")
        try await rewrite(store, path, 1, "AI heading 2", "AI body 2")   // second regeneration
        try await rewrite(store, path, 1, "AI heading 3", "AI body 3")   // third
        let text = try await sent(store, path, dir)
        XCTAssertTrue(text.contains("Body: Power off and lock out the breaker."),
                      "still the author's correction, three runs later")
    }

    /// Per field: rewriting only the heading must not make the author's untouched body
    /// look like Claude's, nor Claude's untouched body look like the author's.
    func testAPartialRewriteKeepsEachFieldsSourceSeparately() async throws {
        let (store, path, dir) = try await project()
        try await rewrite(store, path, 1, "AI heading", "AI body")
        try await rewrite(store, path, 1, "AI heading 2", "")          // heading only
        let text = try await sent(store, path, dir)
        XCTAssertTrue(text.contains("Heading: Stop first"))
        XCTAssertTrue(text.contains("Body: Power off the unit."), "the body's source survived a run that did not touch it")
    }

    // MARK: Revert gives every author block its author's words

    func testRevertGivesAnAuthorBlockBackItsAuthorsWords() async throws {
        let (store, path, _) = try await project()
        let id = try await store.openProject(at: path).manifest.steps[0].id
        try await rewrite(store, path, 1, "AI heading", "AI body")
        try await revertSop(store: store, projectPath: path)
        let back = try await step(store, path, id)
        XCTAssertEqual(back?.heading, "Stop first")
        XCTAssertEqual(back?.body, "Power off the unit.")
        XCTAssertEqual(back?.callout, .warning)
        XCTAssertNil(back?.sopRewrite)
    }

    /// An edit the author made after the generation is THEIR words, so Revert keeps it
    /// rather than rolling it back to a snapshot from before the first generation.
    func testRevertNeverDiscardsAnAuthorsOwnLaterEdit() async throws {
        let (store, path, _) = try await project()
        let id = try await store.openProject(at: path).manifest.steps[0].id
        try await rewrite(store, path, 1, "AI heading", "AI body")
        _ = try await store.editStepText(at: path, stepId: id, body: "Unplug it first.")
        try await revertSop(store: store, projectPath: path)
        let back = try await step(store, path, id)
        XCTAssertEqual(back?.body, "Unplug it first.")
        XCTAssertEqual(back?.heading, "Stop first", "the heading Claude wrote goes back to the author's")
    }

    // MARK: The record itself

    func testTheRecordRoundTripsAndIsOmittedWhenAbsent() throws {
        var s = ProjectStep(id: "t", order: 1, kind: .text, screenshot: "", trigger: .hotkey, heading: "H", body: "B")
        let bare = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(bare.contains("sopRewrite"), "a block generation never touched is unchanged on disk")
        s.sopRewrite = SopTextRewrite(heading: "H2", body: nil, sourceHeading: "H", sourceBody: nil)
        let back = try JSONDecoder().decode(ProjectStep.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.sopRewrite, s.sopRewrite)
        XCTAssertTrue(back.extra.isEmpty, "a known key, not an unknown one")
    }
}
