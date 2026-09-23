import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// Step text landing on the WRONG step.
///
/// `generate` numbers steps against the in-memory manifest the request is built
/// from; `applySopEdits` re-reads the manifest from disk inside `mutate`. Apply used
/// to match edits by position, so any structural edit made while the request was
/// in flight moved every later step's text onto its neighbour, and nothing raised.
/// Reproduced independently by two investigations before this fix.
///
/// Each case runs the REAL `SopService.generate` (a mock transport standing in for a
/// model that numbers perfectly), makes the edit on the store, then applies. A
/// perfect model is the point: the text was misplaced by our code, not by Claude.
final class EditBindingTests: XCTestCase {

    /// A project of four screenshots, its snapshot, and a plan that captions each
    /// screenshot "for-<its own id>", numbered exactly as the assembler shows them.
    private func generated() async throws
        -> (store: ProjectStore, path: String, ids: [String], plan: SopEditPlan)
    {
        let (store, path, dir) = try await makeProject(shots: 4)
        let manifest = try await store.openProject(at: path).manifest
        let ids = manifest.steps.map(\.id)
        let steps: [[String: Any]] = ids.enumerated().map { i, id in
            ["stepNumber": i + 1, "caption": "for-\(id)", "body": "body-\(id)",
             "sectionHeading": NSNull(), "sectionBody": NSNull()]
        }
        let obj: [String: Any] = ["title": "T", "intro": NSNull(), "steps": steps]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
        let svc = SopService(
            client: ClaudeClient(transport: MockTransport(streamHandler: { _ in
                (sseLines(json: json), ResponseHead(status: 200))
            })),
            keyStore: StubKeyStore())
        let plan = try await svc.generate(dir: dir, manifest: manifest, settings: SopSettings(), onProgress: { _ in })
        return (store, path, ids, plan)
    }

    /// Every original screenshot still present must carry the text written for IT.
    private func assertEachCaptionOnItsOwnStep(
        _ store: ProjectStore, _ path: String, _ ids: [String], file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let after = try await store.openProject(at: path).manifest.steps
        for step in after where step.kind != .text && ids.contains(step.id) {
            XCTAssertEqual(step.caption, "for-\(step.id)",
                           "a step received another step's text", file: file, line: line)
        }
    }

    private func apply(_ store: ProjectStore, _ path: String, _ plan: SopEditPlan) async throws {
        try await applySopEdits(store: store, projectPath: path, plan: plan, model: .sonnet5, tone: .professional)
    }

    func testDraggingAStepWhileGeneratingKeepsEveryCaptionOnItsStep() async throws {
        let (store, path, ids, plan) = try await generated()
        _ = try await store.reorderSteps(at: path, orderedIds: [ids[3], ids[0], ids[1], ids[2]])
        try await apply(store, path, plan)
        try await assertEachCaptionOnItsOwnStep(store, path, ids)
    }

    func testInsertingANoteWhileGeneratingKeepsEveryCaptionOnItsStep() async throws {
        let (store, path, ids, plan) = try await generated()
        _ = try await store.addTextStep(at: path, atIndex: 0, heading: "Late note")
        try await apply(store, path, plan)
        try await assertEachCaptionOnItsOwnStep(store, path, ids)
    }

    func testDeletingAStepWhileGeneratingKeepsEveryCaptionOnItsStep() async throws {
        let (store, path, ids, plan) = try await generated()
        _ = try await store.deleteSteps(at: path, ids: [ids[1]])
        try await apply(store, path, plan)
        try await assertEachCaptionOnItsOwnStep(store, path, ids)
        let after = try await store.openProject(at: path).manifest.steps.map(\.id)
        XCTAssertFalse(after.contains(ids[1]), "a deleted step must stay deleted, not be resurrected by its edit")
    }

    /// The recording path: `CaptureEngine` inserts a shot mid-project. The new step
    /// was never shown to Claude, so it must receive nothing — and above all must
    /// not take the text meant for the step it pushed down.
    func testRecordingAStepIntoTheMiddleWhileGeneratingGivesItNothing() async throws {
        let (store, path, ids, plan) = try await generated()
        let recorded = ProjectStep(id: "recorded-mid", order: 0, kind: .shot,
                                   screenshot: "shots/x.png", trigger: .hotkey, caption: "captured")
        try await store.insertStep(at: path, recorded, atIndex: 1)
        try await apply(store, path, plan)
        try await assertEachCaptionOnItsOwnStep(store, path, ids)
        let new = try await store.openProject(at: path).manifest.steps.first { $0.id == "recorded-mid" }
        XCTAssertEqual(new?.caption, "captured", "a step Claude never saw must keep its own caption")
    }

    /// The control: nothing changes in between, and every caption lands.
    func testWithNoEditInBetweenEveryStepIsWritten() async throws {
        let (store, path, ids, plan) = try await generated()
        try await apply(store, path, plan)
        try await assertEachCaptionOnItsOwnStep(store, path, ids)
        let written = try await store.openProject(at: path).manifest.steps.filter { $0.caption.hasPrefix("for-") }
        XCTAssertEqual(written.count, 4)
    }

    /// The binding is only correct if it numbers steps the way the assembler shows
    /// them to Claude, text blocks counted. Parse the headers the model actually
    /// receives and compare, so the two cannot drift apart unnoticed.
    func testTheBindingMatchesTheNumbersTheAssemblerShows() async throws {
        let (store, path, dir) = try await makeProject(shots: 3)
        _ = try await store.addTextStep(at: path, atIndex: 0, heading: "Before you start")
        _ = try await store.addTextStep(at: path, atIndex: 2, heading: "Between")
        let manifest = try await store.openProject(at: path).manifest

        let assembled = try assembleRequest(dir: dir, manifest: manifest, settings: SopSettings())
        let text = (assembled.messages.first?["content"] as? [[String: Any]] ?? [])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
        let shown = text.matches(of: /--- Screenshot step (\d+) ---/).compactMap { Int($0.output.1) }

        let binding = try XCTUnwrap(stepNumberBinding(manifest))
        let shotIds = manifest.steps.filter { $0.kind != .text }.map(\.id)
        XCTAssertEqual(shown.count, shotIds.count, "expected one header per screenshot")
        XCTAssertEqual(shown.map { binding[$0] }, shotIds.map { Optional($0) },
                       "the binding must name the step each header actually labels")
    }

    /// A hand-edited or foreign project.json can repeat a step id. Matching by id
    /// there would write one edit onto several steps, so there is no binding and
    /// apply falls back to position.
    func testDuplicateStepIdsFallBackToPosition() {
        var m = ProjectManifest(id: "p", title: "T", createdAt: "a", updatedAt: "b")
        m.steps = [
            ProjectStep(id: "dup", order: 1, kind: .shot, screenshot: "shots/1.png", trigger: .hotkey),
            ProjectStep(id: "dup", order: 2, kind: .shot, screenshot: "shots/2.png", trigger: .hotkey),
        ]
        XCTAssertNil(stepNumberBinding(m))
    }
}
