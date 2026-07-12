import Foundation
import XCTest
@testable import SOPKit
import ShotModel

final class AssemblerTests: XCTestCase {
    func testAssemblesImagesAndMetadata() async throws {
        let (store, path, dir) = try await makeProject(shots: 2)
        let m = try await store.openProject(at: path).manifest
        let req = try assembleRequest(dir: dir, manifest: m, settings: SopSettings())

        XCTAssertEqual(req.system.count, 1)
        XCTAssertEqual(req.system[0]["type"] as? String, "text")
        XCTAssertEqual(req.messages.count, 1)
        XCTAssertEqual(req.messages[0]["role"] as? String, "user")
        let content = req.messages[0]["content"] as! [[String: Any]]
        // The current title is surfaced as a replaceable placeholder (Claude is
        // asked to write a fresh descriptive `title`), so we assert the title
        // appears alongside that framing rather than a bare "Project:" label.
        let lead = content.first?["text"] as? String
        XCTAssertEqual(lead?.contains("Test SOP"), true)
        XCTAssertEqual(lead?.contains("Current project name"), true)
        XCTAssertEqual(lead?.contains("The 2 steps"), true)
        XCTAssertEqual(content.filter { $0["type"] as? String == "image" }.count, 2)
        XCTAssertNotNil((content.last?["cache_control"]))
    }

    func testExcludesPriorAIInsertsFromNumbering() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        // A prior run's inserted text step must not be shown to Claude.
        m.steps.append(ProjectStep(id: "ai1", order: 9, kind: .text, screenshot: "",
                                   trigger: .hotkey, heading: "AI intro", body: "x", aiInserted: true))
        let req = try assembleRequest(dir: dir, manifest: m, settings: SopSettings())
        let content = req.messages[0]["content"] as! [[String: Any]]
        XCTAssertEqual((content.first?["text"] as? String)?.contains("The 1 steps"), true)
        XCTAssertEqual(content.filter { $0["type"] as? String == "image" }.count, 1)
    }

    func testThrowsWhenNoScreenshots() async {
        let m = ProjectManifest(id: "x", title: "t", createdAt: "", updatedAt: "",
                                steps: [ProjectStep(id: "t", order: 0, kind: .text, screenshot: "",
                                                    trigger: .hotkey, heading: "h", body: "b")])
        XCTAssertThrowsError(try assembleRequest(dir: "/tmp", manifest: m, settings: SopSettings())) {
            XCTAssertEqual($0 as? ClaudeError, .noScreenshots)
        }
    }

    func testFailsClosedOnUnbakedCrop() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        let stepId = try await store.openProject(at: path).manifest.steps[0].id
        var patch = StepPatch()
        patch.crop = .set(Rect(x: 0, y: 0, width: 5, height: 5))  // crop, no flattened render
        _ = try await store.updateStep(at: path, stepId: stepId, patch: patch, flattenedPng: nil)
        let m = try await store.openProject(at: path).manifest
        XCTAssertThrowsError(try assembleRequest(dir: dir, manifest: m, settings: SopSettings())) {
            guard case .unbakedRedaction = ($0 as? ClaudeError) else { return XCTFail("wrong: \($0)") }
        }
    }
}

final class ApplyRevertTests: XCTestCase {
    private func plan() -> SopEditPlan {
        SopEditPlan(
            title: "Refined Title",
            intro: SopIntro(heading: "Overview", body: "Do the thing"),
            steps: [
                SopStepEdit(stepNumber: 1, caption: "Click Save", body: "Press the Save button",
                            note: "be careful", sectionHeading: nil, sectionBody: nil),
                SopStepEdit(stepNumber: 2, caption: "Confirm", body: "Click Confirm",
                            note: nil, sectionHeading: "Phase 2", sectionBody: "Now finalize"),
            ])
    }

    func testApplyRewritesAndSnapshots() async throws {
        let (store, path, _) = try await makeProject(shots: 2)
        let m = try await applySopEdits(store: store, projectPath: path, plan: plan(), model: .sonnet5, tone: .professional)

        XCTAssertEqual(m.title, "Refined Title")
        XCTAssertEqual(m.intro?.heading, "Overview")
        // 2 shots + 1 inserted section text step = 3, in order.
        XCTAssertEqual(m.steps.count, 3)
        XCTAssertNotEqual(m.steps[0].kind, .text)   // shot (kind absent = shot by convention)
        XCTAssertEqual(m.steps[0].caption, "Click Save")
        XCTAssertEqual(m.steps[0].body, "Press the Save button")
        XCTAssertEqual(m.steps[0].note, "be careful")
        XCTAssertEqual(m.steps[1].kind, .text)
        XCTAssertEqual(m.steps[1].heading, "Phase 2")
        XCTAssertEqual(m.steps[1].aiInserted, true)
        XCTAssertEqual(m.steps[2].caption, "Confirm")
        // Backup snapshot of the pristine 2-shot state.
        XCTAssertEqual(m.sopBackup?.steps.count, 2)
        XCTAssertEqual(m.sopBackup?.title, "Test SOP")
    }

    func testRegenerateKeepsFirstBackupAndDropsPriorInserts() async throws {
        let (store, path, _) = try await makeProject(shots: 2)
        _ = try await applySopEdits(store: store, projectPath: path, plan: plan(), model: .sonnet5, tone: .professional)
        // Second pass: the base rebuild drops the prior AI insert, so still 3 steps,
        // and the backup remains the ORIGINAL 2-shot snapshot.
        let m2 = try await applySopEdits(store: store, projectPath: path, plan: plan(), model: .sonnet5, tone: .professional)
        XCTAssertEqual(m2.steps.count, 3)
        XCTAssertEqual(m2.sopBackup?.steps.count, 2)
    }

    func testRevertRestoresAndClears() async throws {
        let (store, path, _) = try await makeProject(shots: 2)
        _ = try await applySopEdits(store: store, projectPath: path, plan: plan(), model: .sonnet5, tone: .professional)
        let reverted = try await revertSop(store: store, projectPath: path)
        XCTAssertEqual(reverted.steps.count, 2)                 // section insert gone
        XCTAssertEqual(reverted.title, "Test SOP")              // title restored
        XCTAssertNil(reverted.intro)                            // intro cleared
        XCTAssertNil(reverted.sopBackup)                        // backup cleared
        XCTAssertEqual(reverted.steps[0].caption, "")           // original blank caption

        // Nothing left to revert.
        do { _ = try await revertSop(store: store, projectPath: path); XCTFail() }
        catch { XCTAssertEqual(error as? SopApplyError, .nothingToRevert) }
    }
}
