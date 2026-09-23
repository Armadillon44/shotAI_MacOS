import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// Undo this generation, and a Revert that touches only what generation writes.
final class UndoRevertTests: XCTestCase {

    private func plan(_ captions: [String], title: String = "Gen") -> SopEditPlan {
        SopEditPlan(title: title, intro: nil, steps: captions.enumerated().map {
            SopStepEdit(stepNumber: $0.offset + 1, caption: $0.element, body: "body \($0.element)",
                        sectionHeading: nil, sectionBody: nil)
        })
    }
    private func apply(_ s: ProjectStore, _ p: String, _ pl: SopEditPlan) async throws -> SopRunUndo {
        try await applySopEditsUndoable(store: s, projectPath: p, plan: pl, model: .sonnet5, tone: .professional).undo
    }
    private func captions(_ s: ProjectStore, _ p: String) async throws -> [String] {
        try await s.openProject(at: p).manifest.steps.map(\.caption)
    }

    // MARK: Undo this generation

    /// The case Revert could not serve: a good first generation, a bad second
    /// one. Revert goes all the way back to the pre-AI original and loses the good
    /// run too; undo goes back one.
    func testUndoRestoresThePreviousGenerationNotThePreAIOriginal() async throws {
        let (store, path, _) = try await makeProject(shots: 2)
        let original = try await captions(store, path)
        _ = try await apply(store, path, plan(["Good A", "Good B"]))
        let undo = try await apply(store, path, plan(["Bad A", "Bad B"], title: "Bad"))

        try await undoSopRun(store: store, projectPath: path, undo: undo)
        let after = try await store.openProject(at: path).manifest
        XCTAssertEqual(after.steps.map(\.caption), ["Good A", "Good B"])
        XCTAssertEqual(after.title, "Gen")
        XCTAssertNotEqual(after.steps.map(\.caption), original, "not the pre-AI original")
        XCTAssertNotNil(after.sopBackup, "Revert to original must still be possible afterwards")
    }

    /// Any edit after the run makes undo unavailable instead of silently throwing
    /// that edit away.
    func testUndoRefusesOnceTheProjectHasChanged() async throws {
        let (store, path, _) = try await makeProject(shots: 2)
        let undo = try await apply(store, path, plan(["A", "B"]))
        let id = try await store.openProject(at: path).manifest.steps[0].id
        _ = try await store.editStepText(at: path, stepId: id, caption: "My own words")

        do {
            try await undoSopRun(store: store, projectPath: path, undo: undo)
            XCTFail("undo must refuse once the project changed")
        } catch {
            XCTAssertEqual(error as? SopApplyError, .changedSinceGeneration)
        }
        let now = try await captions(store, path).first
        XCTAssertEqual(now, "My own words", "and change nothing")
    }

    /// Paths that bypass the report — here a recording — are covered too, because
    /// the check is on the project's state, not on which UI made the change.
    func testUndoRefusesAfterAStepIsRecordedIntoTheProject() async throws {
        let (store, path, _) = try await makeProject(shots: 1)
        let undo = try await apply(store, path, plan(["A"]))
        try await store.insertStep(at: path, ProjectStep(id: "rec", order: 0, kind: .shot,
                                                         screenshot: "shots/r.png", trigger: .hotkey), atIndex: nil)
        do {
            try await undoSopRun(store: store, projectPath: path, undo: undo)
            XCTFail("undo must refuse after a recording")
        } catch {
            XCTAssertEqual(error as? SopApplyError, .changedSinceGeneration)
        }
    }

    // MARK: Revert touches only what generation writes

    /// Annotations, crop and zoom made after generation survive Revert. Restoring
    /// the whole step used to roll them back, and could leave the annotation list
    /// disagreeing with the render file that a later edit had re-baked.
    func testRevertRestoresTextButKeepsLaterAnnotationsCropAndZoom() async throws {
        let (store, path, _) = try await makeProject(shots: 1)
        let pre = try await store.openProject(at: path).manifest.steps[0]
        _ = try await apply(store, path, plan(["AI caption"]))
        _ = try await store.mutate(at: path) { m in
            m.steps[0].reportZoom = 2.0
            m.steps[0].crop = Rect(x: 1, y: 2, width: 30, height: 40)
            m.steps[0].renderRev = 7
        }

        try await revertSop(store: store, projectPath: path)
        let step = try await store.openProject(at: path).manifest.steps[0]
        XCTAssertEqual(step.caption, pre.caption, "the text Claude wrote is reverted")
        XCTAssertEqual(step.body, pre.body)
        XCTAssertEqual(step.reportZoom, 2.0, "a later zoom survives")
        XCTAssertEqual(step.crop, Rect(x: 1, y: 2, width: 30, height: 40), "a later crop survives")
        XCTAssertEqual(step.renderRev, 7, "the render revision is not rolled back under its file")
    }

    func testRevertRestoresTheAuthorEditedFlag() async throws {
        let (store, path, _) = try await makeProject(shots: 1)
        let id = try await store.openProject(at: path).manifest.steps[0].id
        _ = try await store.editStepText(at: path, stepId: id, caption: "Written by a person")
        _ = try await apply(store, path, plan(["AI caption"]))
        try await revertSop(store: store, projectPath: path)
        let step = try await store.openProject(at: path).manifest.steps[0]
        XCTAssertEqual(step.caption, "Written by a person")
        XCTAssertEqual(step.captionEditedByUser, true, "authorship comes back with the text")
    }
}
