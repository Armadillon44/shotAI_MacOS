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
        // The name is QUOTED and stands alone, so no adjacent word can be
        // mistaken for it. Claude once returned "placeholder" as the title
        // because that word sat beside the value.
        XCTAssertEqual(lead?.contains("\"Test SOP\""), true)
        // "Test SOP" is human-written, so Claude is told to keep it.
        XCTAssertEqual(lead?.contains("written by a person"), true)
        XCTAssertEqual(lead?.contains("MUST be replaced"), false)
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
                            sectionHeading: nil, sectionBody: nil),
                SopStepEdit(stepNumber: 2, caption: "Confirm", body: "Click Confirm",
                            sectionHeading: "Phase 2", sectionBody: "Now finalize"),
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
        XCTAssertEqual(m.steps[0].note, "")  // note is never AI-written; original (empty) preserved
        XCTAssertEqual(m.steps[1].kind, .text)
        XCTAssertEqual(m.steps[1].heading, "Phase 2")
        XCTAssertEqual(m.steps[1].body, "Now finalize")
        XCTAssertEqual(m.steps[1].aiInserted, true)
        // The AI section insert is a NON-COUNTED phase divider (callout .section),
        // not a numbered text step — so the two shots stay 1 and 2.
        XCTAssertEqual(m.steps[1].callout, .section)
        XCTAssertTrue(ReportPresentation.isCalloutStep(m.steps[1]))
        let nums = ReportPresentation.displayNumbers(for: m.steps)
        XCTAssertEqual(nums[m.steps[0].id], 1)
        XCTAssertEqual(nums[m.steps[2].id], 2)
        XCTAssertNil(nums[m.steps[1].id])  // section is not numbered
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

    func testRevertPreservesManualAdditionsAfterGeneration() async throws {
        let (store, path, _) = try await makeProject(shots: 2)
        _ = try await applySopEdits(store: store, projectPath: path, plan: plan(), model: .sonnet5, tone: .professional)
        // The user adds a callout AFTER generation (a manual, non-AI step).
        let added = try await store.addTextStep(at: path, atIndex: nil,
                                                heading: "Heads up", body: "keep me", callout: .warning)
        let manualId = added.steps.last!.id

        let reverted = try await revertSop(store: store, projectPath: path)
        // AI edits are gone: section insert dropped, title + intro restored.
        XCTAssertNil(reverted.intro)
        XCTAssertEqual(reverted.title, "Test SOP")
        XCTAssertNil(reverted.sopBackup)
        XCTAssertEqual(reverted.steps.filter { $0.aiInserted == true }.count, 0)
        XCTAssertEqual(reverted.steps[0].caption, "")            // shot reverted to original
        // The manual callout SURVIVES the revert (this is the bug fix).
        XCTAssertTrue(reverted.steps.contains { $0.id == manualId && $0.callout == .warning })
        // 2 original shots + the manual callout = 3.
        XCTAssertEqual(reverted.steps.count, 3)
    }
}

/// #73 — author-written context that Claude previously never saw.
final class AuthorContextTests: XCTestCase {
    private func text(_ req: AssembledRequest) -> String {
        (req.messages[0]["content"] as! [[String: Any]])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// `intro` is in the OUTPUT schema, so Claude writes one every time. It was
    /// never sent as INPUT, so an author who described the goal of their
    /// procedure had it silently replaced by a version written without ever
    /// seeing it.
    func testAuthorOverviewIsSentAsInput() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        m.intro = SopIntro(heading: "Before you begin",
                           body: "This runs on the warehouse terminal, not your laptop.")
        let t = text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
        XCTAssertTrue(t.contains("Before you begin"))
        XCTAssertTrue(t.contains("warehouse terminal"))
        XCTAssertTrue(t.contains("author already wrote this overview"))
        // The instruction matters as much as the text — but it must INFORM, not
        // freeze the author's prose. Claude should still write the best overview
        // it can; what it must not do is contradict or quietly drop what the
        // author knows and it cannot see.
        XCTAssertTrue(t.contains("AUTHORITATIVE CONTEXT"))
        XCTAssertTrue(t.contains("rewrite it freely"), "Claude keeps authorship of the prose")
        XCTAssertTrue(t.contains("SILENTLY DROP"), "but not of the author's facts")
    }

    /// An absent or blank overview must add nothing — no empty scaffolding that
    /// invites Claude to 'preserve' something that does not exist.
    func testNoOverviewSectionWhenThereIsNoOverview() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        XCTAssertFalse(text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
            .contains("author already wrote this overview"))

        m.intro = SopIntro(heading: "   ", body: "\n ")
        XCTAssertFalse(text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
            .contains("author already wrote this overview"),
            "whitespace-only counts as absent")
    }

    /// note/caution/warning/section are all `text` steps distinguished by
    /// `callout`. Sending them identically meant a red warning, a phase divider
    /// and an ordinary paragraph arrived as the same thing.
    func testCalloutKindIsDistinguishable() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        m.steps.append(ProjectStep(id: "w", order: 5, kind: .text, screenshot: "", trigger: .hotkey,
                                   heading: "Do not skip", body: "Data loss follows.", callout: .warning))
        m.steps.append(ProjectStep(id: "s", order: 6, kind: .text, screenshot: "", trigger: .hotkey,
                                   heading: "Phase 2", body: "", callout: .section))
        m.steps.append(ProjectStep(id: "p", order: 7, kind: .text, screenshot: "", trigger: .hotkey,
                                   heading: "Aside", body: "Plain paragraph."))
        let t = text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))

        XCTAssertTrue(t.contains("Warning callout"))
        XCTAssertTrue(t.contains("Section heading"))
        XCTAssertTrue(t.contains("Text step"))
        // Labelling alone is not enough — Claude also needs to know what to DO.
        XCTAssertTrue(t.contains("never contradict it"), "warnings carry handling guidance")
        XCTAssertTrue(t.contains("use that structure rather"),
                      "the author's phase structure informs Claude's, not just blocks it")
    }

    /// A plain text step gets no callout guidance — nothing to respect or avoid.
    func testPlainTextStepGetsNoExtraGuidance() {
        XCTAssertNil(AssembledRequest.authorBlockGuidance(nil))
        XCTAssertEqual(AssembledRequest.authorBlockLabel(nil), "Text step")
        XCTAssertEqual(AssembledRequest.authorBlockLabel(.caution), "Caution callout")
    }
}

/// #73 gap 3 — telling "Claude wrote this" from "the author fixed what Claude
/// wrote". Without the flag both merely differ from the pre-AI backup, so a
/// regeneration discarded the human's correction.
final class AuthorCaptionEditTests: XCTestCase {
    private func text(_ req: AssembledRequest) -> String {
        (req.messages[0]["content"] as! [[String: Any]])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// Baseline that must not regress: with a backup present and no author edit,
    /// the PRE-AI caption is sent. This is what stops successive regenerations
    /// compounding Claude's own rewrites.
    func testUnflaggedCaptionStillSendsThePreAIOriginal() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        var original = m.steps[0]
        original.caption = "Captured: clicked Save"
        m.sopBackup = SopBackup(steps: [original], title: "t", intro: nil,
                                model: "claude-sonnet-5", tone: .professional, at: "2026-01-01")
        m.steps[0].caption = "Claude's rewrite"       // AI output, not author-edited
        let t = text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
        XCTAssertTrue(t.contains("Captured: clicked Save"))
        XCTAssertFalse(t.contains("Claude's rewrite"), "must not feed Claude its own text back")
    }

    /// The fix: an author-edited caption IS sent, because it is a deliberate
    /// human correction and the thing worth rewriting from.
    func testAuthorEditedCaptionIsSentInstead() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        var original = m.steps[0]
        original.caption = "Captured: clicked Save"
        m.sopBackup = SopBackup(steps: [original], title: "t", intro: nil,
                                model: "claude-sonnet-5", tone: .professional, at: "2026-01-01")
        m.steps[0].caption = "Click Save on the Invoices tab"
        m.steps[0].captionEditedByUser = true
        let t = text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
        XCTAssertTrue(t.contains("Click Save on the Invoices tab"))
        XCTAssertFalse(t.contains("Captured: clicked Save"))
    }

    /// Applying a generation clears the flag — the AI just overwrote the edit, so
    /// leaving it set would send Claude its own text back as if a human wrote it.
    func testApplyingAGenerationClearsTheFlag() async throws {
        let (store, path, _) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        let id = m.steps[0].id
        _ = try await store.editStepText(at: path, stepId: id, caption: "author wording")
        let edited = try await store.openProject(at: path).manifest
        XCTAssertEqual(edited.steps[0].captionEditedByUser, true, "manual edit sets it")

        let plan = SopEditPlan(title: "T", intro: nil,
                               steps: [SopStepEdit(stepNumber: 1, caption: "AI wording",
                                                   body: "b", sectionHeading: nil, sectionBody: nil)])
        _ = try await SOPKit.applySopEdits(store: store, projectPath: path, plan: plan,
                                           model: .sonnet5, tone: .professional)
        let after = try await store.openProject(at: path).manifest
        XCTAssertEqual(after.steps[0].caption, "AI wording")
        XCTAssertNil(after.steps[0].captionEditedByUser, "AI overwrote it — flag must clear")
    }

    /// Absent must stay the safe default. A client that does not yet set this
    /// field produces exactly this, so a mixed-version fleet degrades to today's
    /// behaviour rather than to feeding Claude its own output.
    func testAbsentFlagIsTreatedAsMachineWritten() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        var original = m.steps[0]
        original.caption = "Captured text"
        m.sopBackup = SopBackup(steps: [original], title: "t", intro: nil,
                                model: "claude-sonnet-5", tone: .professional, at: "2026-01-01")
        m.steps[0].caption = "something else"
        m.steps[0].captionEditedByUser = nil
        XCTAssertTrue(text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
            .contains("Captured text"))
    }
}

/// The title instruction is chosen by the APP, not judged by Claude. Two real
/// failures motivated this: it once returned the literal word "placeholder"
/// (which used to sit beside the value in the prompt), and once kept
/// "Project 2026/08/19 12:41:16" verbatim.
final class TitleInstructionTests: XCTestCase {
    private func lead(_ title: String) async throws -> String {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        m.title = title
        let req = try assembleRequest(dir: dir, manifest: m, settings: SopSettings())
        return (req.messages[0]["content"] as! [[String: Any]])[0]["text"] as! String
    }

    func testAutoGeneratedTitleIsOrderedReplaced() async throws {
        let t = try await lead("Project 2026/08/19 12:41:16")
        XCTAssertTrue(t.contains("MUST be replaced"))
        XCTAssertTrue(t.contains("never return the current name"))
        XCTAssertFalse(t.contains("written by a person"))
    }

    /// A human title must NOT be steamrolled — the opposite failure.
    func testHumanTitleIsPreserved() async throws {
        let t = try await lead("Onboarding a new warehouse scanner")
        XCTAssertTrue(t.contains("written by a person"))
        XCTAssertTrue(t.contains("unchanged"))
        XCTAssertFalse(t.contains("MUST be replaced"))
    }

    func testDetectorMatchesTheGeneratorFormat() {
        XCTAssertTrue(ProjectStore.isAutoGeneratedTitle("Project 2026/08/19 12:41:16"))
        XCTAssertTrue(ProjectStore.isAutoGeneratedTitle("   "), "blank counts as unnamed")
        XCTAssertFalse(ProjectStore.isAutoGeneratedTitle("Project Falcon rollout"),
                       "a real title that merely starts with 'Project' is NOT auto-generated")
        XCTAssertFalse(ProjectStore.isAutoGeneratedTitle("Onboarding a new scanner"))
    }
}

/// #80 — the Overview needs the same authorship marker captions got in #73.
/// Without it, Claude's own overview comes back next run labelled as the
/// author's, under the strongest "do not contradict or drop this" instruction in
/// the prompt.
final class IntroAuthorshipTests: XCTestCase {
    private func text(_ req: AssembledRequest) -> String {
        (req.messages[0]["content"] as! [[String: Any]])
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    private func backup(intro: SopIntro?, steps: [ProjectStep]) -> SopBackup {
        SopBackup(steps: steps, title: "t", intro: intro,
                  model: "claude-sonnet-5", tone: .professional, at: "2026-01-01")
    }

    /// THE BUG. A generation has run, the author never wrote an overview, so the
    /// current intro is Claude's. It must not be sent back as author intent.
    func testAIWrittenIntroIsNotFedBack() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        m.sopBackup = backup(intro: nil, steps: m.steps)   // author wrote none
        m.intro = SopIntro(heading: "Overview", body: "Claude's guess about the process.")
        m.introEditedByUser = nil
        let t = text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
        XCTAssertFalse(t.contains("Claude's guess"))
        XCTAssertFalse(t.contains("author already wrote this overview"),
                       "no author overview exists, so no overview section at all")
    }

    /// An overview the author edited AFTER a generation is theirs, and is sent.
    func testAuthorEditedIntroIsSent() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        m.sopBackup = backup(intro: nil, steps: m.steps)
        m.intro = SopIntro(heading: "Before you begin", body: "Warehouse terminal only.")
        m.introEditedByUser = true
        let t = text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
        XCTAssertTrue(t.contains("Warehouse terminal only"))
        XCTAssertTrue(t.contains("author already wrote this overview"))
    }

    /// An overview written BEFORE the first generation survives it: the backup
    /// holds the author's text, so it keeps being sent even unflagged.
    func testPreGenerationIntroSurvivesFromTheBackup() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        m.sopBackup = backup(intro: SopIntro(heading: "Goal", body: "Reset a scanner."),
                             steps: m.steps)
        m.intro = SopIntro(heading: "Overview", body: "Claude's rewrite of it.")
        m.introEditedByUser = nil
        let t = text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
        XCTAssertTrue(t.contains("Reset a scanner"))
        XCTAssertFalse(t.contains("Claude's rewrite"))
    }

    /// Before any generation there is no backup, so the author's overview is sent
    /// whether or not the flag was set. Guards the common first-run path.
    func testNoBackupSendsTheCurrentIntro() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        m.intro = SopIntro(heading: "Goal", body: "Reset a scanner.")
        XCTAssertTrue(text(try assembleRequest(dir: dir, manifest: m, settings: SopSettings()))
            .contains("Reset a scanner"))
    }

    /// Applying a generation PINS the author's heading and KEEPS the flag.
    ///
    /// Deliberately asymmetric with captions, and the asymmetry is the point:
    /// `captionEditedByUser` is DROPPED on apply because the model's caption
    /// replaces the human text outright, so the flag must not outlive what it
    /// describes. Here the author's heading is still in the manifest verbatim
    /// afterwards, so the flag has to persist or the next run stops protecting
    /// it. Matches Armadillon44/shotAI#64 — the two platforms must agree.
    func testApplyingAGenerationPinsTheHeadingAndKeepsTheFlag() async throws {
        let (store, path, _) = try await makeProject(shots: 1)
        _ = try await store.setIntro(at: path, heading: "Before you begin", body: "Author text.")

        let plan = SopEditPlan(title: "T",
                               intro: SopIntro(heading: "Overview", body: "Model reword."),
                               steps: [SopStepEdit(stepNumber: 1, caption: "c", body: "b",
                                                   sectionHeading: nil, sectionBody: nil)])
        _ = try await SOPKit.applySopEdits(store: store, projectPath: path, plan: plan,
                                           model: .sonnet5, tone: .professional)
        let after = try await store.openProject(at: path).manifest
        XCTAssertEqual(after.intro?.heading, "Before you begin", "author's heading pinned in code")
        XCTAssertEqual(after.intro?.body, "Model reword.", "body accepted as a reword")
        XCTAssertEqual(after.introEditedByUser, true, "flag persists — the heading is still theirs")
    }

    /// An UNAUTHORED overview is replaced wholesale, as before.
    func testUnauthoredIntroIsReplacedOutright() async throws {
        let (store, path, _) = try await makeProject(shots: 1)
        let plan = SopEditPlan(title: "T",
                               intro: SopIntro(heading: "Overview", body: "Model text."),
                               steps: [SopStepEdit(stepNumber: 1, caption: "c", body: "b",
                                                   sectionHeading: nil, sectionBody: nil)])
        _ = try await SOPKit.applySopEdits(store: store, projectPath: path, plan: plan,
                                           model: .sonnet5, tone: .professional)
        let after = try await store.openProject(at: path).manifest
        XCTAssertEqual(after.intro?.heading, "Overview")
        XCTAssertNil(after.introEditedByUser)
    }

    /// Revert restores AUTHORSHIP, not just text. Without this a reverted author
    /// overview comes back unflagged and the next generate rewrites it again.
    func testRevertRestoresTheFlag() async throws {
        let (store, path, _) = try await makeProject(shots: 1)
        _ = try await store.setIntro(at: path, heading: "Mine", body: "Author text.")
        let plan = SopEditPlan(title: "T", intro: SopIntro(heading: "AI", body: "AI text."),
                               steps: [SopStepEdit(stepNumber: 1, caption: "c", body: "b",
                                                   sectionHeading: nil, sectionBody: nil)])
        _ = try await SOPKit.applySopEdits(store: store, projectPath: path, plan: plan,
                                           model: .sonnet5, tone: .professional)
        _ = try await SOPKit.revertSop(store: store, projectPath: path)
        let after = try await store.openProject(at: path).manifest
        XCTAssertEqual(after.intro?.body, "Author text.")
        XCTAssertEqual(after.introEditedByUser, true, "authorship restored, not just the text")
    }

    /// A blank overview in the plan leaves the existing one alone, so an author
    /// edit must survive with it. The asymmetry called out in #80.
    func testEmptyPlanIntroLeavesTheAuthorFlagIntact() async throws {
        let (store, path, _) = try await makeProject(shots: 1)
        _ = try await store.setIntro(at: path, heading: "Mine", body: "Author text.")
        let plan = SopEditPlan(title: "T", intro: SopIntro(heading: "", body: ""),
                               steps: [SopStepEdit(stepNumber: 1, caption: "c", body: "b",
                                                   sectionHeading: nil, sectionBody: nil)])
        _ = try await SOPKit.applySopEdits(store: store, projectPath: path, plan: plan,
                                           model: .sonnet5, tone: .professional)
        let after = try await store.openProject(at: path).manifest
        XCTAssertEqual(after.intro?.body, "Author text.", "blank plan intro must not wipe it")
        XCTAssertEqual(after.introEditedByUser, true, "so the flag must survive too")
    }
}

/// The two intro prompt modes must be MUTUALLY EXCLUSIVE, not layered.
///
/// The failure this guards against (seen live on Windows) was the model
/// following the permissive half of a mixed message and rewriting an overview
/// the user had just written, heading and all. Outweighing the permissive
/// sentences is not enough — they have to be absent.
final class IntroPromptModeTests: XCTestCase {
    private func header(authored: Bool) async throws -> String {
        let (store, path, dir) = try await makeProject(shots: 1)
        var m = try await store.openProject(at: path).manifest
        m.intro = SopIntro(heading: "Before you begin", body: "Warehouse terminal only.")
        m.introEditedByUser = authored ? true : nil
        let req = try assembleRequest(dir: dir, manifest: m, settings: SopSettings())
        return (req.messages[0]["content"] as! [[String: Any]])[0]["text"] as! String
    }

    func testProtectiveModeRemovesThePermissiveSentences() async throws {
        let t = try await header(authored: true)
        XCTAssertTrue(t.contains("shotAI restores it after your reply"))
        XCTAssertTrue(t.contains("reword only for clarity"))
        // The whole point: these must be GONE, not merely counterbalanced.
        XCTAssertFalse(t.contains("rewrite it freely"))
        XCTAssertFalse(t.contains("not as text to protect"))
    }

    func testPermissiveModeIsUnchangedForAnUnauthoredOverview() async throws {
        let t = try await header(authored: false)
        XCTAssertTrue(t.contains("rewrite it freely"))
        XCTAssertTrue(t.contains("AUTHORITATIVE CONTEXT"))
        XCTAssertFalse(t.contains("shotAI restores it after your reply"))
    }
}
