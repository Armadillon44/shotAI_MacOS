import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// The whole SOP is written: author blocks and callouts as well as screenshots
/// (Dylan, 2026-09-23). Driven through the real generate, assembler and apply.
final class HolisticTests: XCTestCase {

    typealias Script = SopValidationTests.Script

    private func entry(_ n: Int, _ kind: String, _ caption: String, _ body: String) -> [String: Any] {
        ["stepNumber": n, "kind": kind, "caption": caption, "body": body, "sectionHeading": NSNull(), "sectionBody": NSNull()]
    }
    private func reply(_ steps: [[String: Any]]) -> ([String], ResponseHead) {
        let d = try! JSONSerialization.data(withJSONObject: ["title": "A Real Title", "intro": NSNull(), "steps": steps])
        return (sseLines(json: String(decoding: d, as: UTF8.self)), ResponseHead(status: 200))
    }

    /// [warning, shot, note, shot]
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

    func testAuthorBlocksAreRewrittenAndKeepTheirKind() async throws {
        let (store, path, dir) = try await project()
        let script = Script([reply([
            entry(1, "text", "Switch it off first", "Power the unit off before you start."),
            entry(2, "screenshot", "Open Settings", "Click the gear."),
            entry(3, "text", "", "The menu can take a few seconds to appear."),
            entry(4, "screenshot", "Save", "Press Save."),
        ])])
        let plan = try await generate(store, path, dir, script)
        try await applySopEdits(store: store, projectPath: path, plan: plan, model: .sonnet5, tone: .professional)
        let steps = try await store.openProject(at: path).manifest.steps.filter { $0.aiInserted != true }

        XCTAssertEqual(steps[0].heading, "Switch it off first")
        XCTAssertEqual(steps[0].body, "Power the unit off before you start.")
        XCTAssertEqual(steps[0].callout, .warning, "the kind of block is the author's, never Claude's")
        XCTAssertEqual(steps[2].heading ?? "", "", "an empty heading means leave it as written — this note had none")
        XCTAssertEqual(steps[2].body, "The menu can take a few seconds to appear.")
        XCTAssertEqual(steps[2].callout, .note)
        XCTAssertEqual(steps[1].caption, "Open Settings")
    }

    /// Filler in an author block is withheld, so the author's own words stand. That
    /// is a good outcome, not a failure: no repair turn, and no "incomplete" notice.
    func testFillerInAnAuthorBlockKeepsTheAuthorsTextWithoutARepairOrNotice() async throws {
        let (store, path, dir) = try await project()
        let script = Script([reply([
            entry(1, "text", "Placeholder", "TBD"),
            entry(2, "screenshot", "Open Settings", "Click the gear."),
            entry(3, "text", "", "The menu can take a few seconds to appear."),
            entry(4, "screenshot", "Save", "Press Save."),
        ])])
        let plan = try await generate(store, path, dir, script)
        XCTAssertEqual(script.count, 1, "no repair for an author block")
        XCTAssertTrue(plan.incompleteStepIds.isEmpty, "and nothing reported incomplete")
        try await applySopEdits(store: store, projectPath: path, plan: plan, model: .sonnet5, tone: .professional)
        let warning = try await store.openProject(at: path).manifest.steps[0]
        XCTAssertEqual(warning.heading, "Stop first")
        XCTAssertEqual(warning.body, "Power off the unit.")
    }

    /// Every number is writable now, so the number cannot give renumbering away. The
    /// declared kind can: a screenshot entry at an author block's number is a
    /// misnumbered plan, rerun rather than applied.
    func testAScreenshotEntryAimedAtAnAuthorBlockIsMisnumbering() async throws {
        let (store, path, dir) = try await project()
        let script = Script([
            reply([entry(1, "screenshot", "Open Settings", "Click the gear."),     // renumbered 1, 2
                   entry(2, "screenshot", "Save", "Press Save.")]),
            reply([entry(2, "screenshot", "Open Settings", "Click the gear."),
                   entry(4, "screenshot", "Save", "Press Save.")]),
        ])
        let plan = try await generate(store, path, dir, script)
        XCTAssertEqual(script.count, 2, "the whole request ran again")
        try await applySopEdits(store: store, projectPath: path, plan: plan, model: .sonnet5, tone: .professional)
        let steps = try await store.openProject(at: path).manifest.steps
        XCTAssertEqual(steps[0].heading, "Stop first", "the warning never received screenshot text")
        XCTAssertEqual(steps.filter { $0.kind != .text }.map(\.caption), ["Open Settings", "Save"])
    }

    /// The schema's number limit is sized to the blocks the request actually shows.
    func testTheSchemaAllowsExactlyTheNumbersOfTheBlocksShown() async throws {
        let (store, path, dir) = try await project()
        let script = Script([reply([entry(2, "screenshot", "Open Settings", "Click the gear.")])])
        _ = try await generate(store, path, dir, script)
        let sent = try XCTUnwrap(script.bodies.first)
        XCTAssertTrue(sent.contains(#""stepNumber":{"type":"integer","enum":[1,2,3,4]}"#), "four blocks, four numbers")
    }

    // MARK: Feeding author blocks back to the next run

    /// After a generation rewrote an author block, the next run is sent the AUTHOR's
    /// original, not Claude's rewrite, or each run would drift further from what the
    /// author said.
    func testTheNextRunIsSentTheAuthorsOriginalNotTheRewrite() async throws {
        let (store, path, dir) = try await project()
        let first = SopEditPlan(title: "T", intro: nil, steps: [
            SopStepEdit(stepNumber: 1, caption: "AI heading", body: "AI body", sectionHeading: nil, sectionBody: nil, kind: "text"),
        ])
        try await applySopEdits(store: store, projectPath: path, plan: first, model: .sonnet5, tone: .professional)
        let m = try await store.openProject(at: path).manifest
        XCTAssertEqual(m.steps[0].body, "AI body", "fixture: the rewrite landed")

        let text = try assembledText(dir, m)
        XCTAssertTrue(text.contains("Body: Power off the unit."), "the author's words are what Claude rewrites from")
        XCTAssertFalse(text.contains("Body: AI body"), "not its own previous rewrite")
    }

    /// The exception, as for captions: an edit the author made AFTER the generation is
    /// a deliberate correction, and is what the next run rewrites from.
    func testAnAuthorEditAfterAGenerationIsWhatTheNextRunIsSent() async throws {
        let (store, path, dir) = try await project()
        let first = SopEditPlan(title: "T", intro: nil, steps: [
            SopStepEdit(stepNumber: 1, caption: "AI heading", body: "AI body", sectionHeading: nil, sectionBody: nil, kind: "text"),
        ])
        try await applySopEdits(store: store, projectPath: path, plan: first, model: .sonnet5, tone: .professional)
        let id = try await store.openProject(at: path).manifest.steps[0].id
        _ = try await store.editStepText(at: path, stepId: id, body: "Unplug it, then power it off.")
        let m = try await store.openProject(at: path).manifest
        XCTAssertEqual(m.steps[0].captionEditedByUser, true, "editing a text block's words flags it")

        let text = try assembledText(dir, m)
        XCTAssertTrue(text.contains("Body: Unplug it, then power it off."))
    }

    /// And once Claude rewrites that block again, the flag clears: it no longer
    /// describes what is there.
    func testRewritingAnAuthorEditedBlockClearsTheFlag() async throws {
        let (store, path, _) = try await project()
        let id = try await store.openProject(at: path).manifest.steps[0].id
        _ = try await store.editStepText(at: path, stepId: id, body: "Mine.")
        let plan = SopEditPlan(title: "T", intro: nil, steps: [
            SopStepEdit(stepNumber: 1, caption: "", body: "Rewritten.", sectionHeading: nil, sectionBody: nil, kind: "text"),
        ])
        try await applySopEdits(store: store, projectPath: path, plan: plan, model: .sonnet5, tone: .professional)
        let after = try await store.openProject(at: path).manifest.steps[0]
        XCTAssertEqual(after.body, "Rewritten.")
        XCTAssertNil(after.captionEditedByUser)
    }

    private func assembledText(_ dir: String, _ m: ProjectManifest) throws -> String {
        let content = try assembleRequest(dir: dir, manifest: m, settings: SopSettings())
            .messages.first?["content"] as? [[String: Any]] ?? []
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}
