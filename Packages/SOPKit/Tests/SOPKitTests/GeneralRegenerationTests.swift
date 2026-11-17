import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// General wording on a project that has been generated before, and the parts of a
/// General request that are the author's: their overview, their blocks, their name.
final class GeneralRegenerationTests: XCTestCase {

    private let stamp = "Project 2026/11/17 09:00:00"
    private let claudeTitle = "Resetting MFA in the Okta Admin Console"

    private func userText(_ m: ProjectManifest, _ dir: String, settings: SopSettings = SopSettings(),
                          run: SopRun) throws -> String {
        try assembleRequest(dir: dir, manifest: m, settings: settings, run: run).messages
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }

    private func systemText(_ m: ProjectManifest, _ dir: String, run: SopRun) throws -> String {
        try assembleRequest(dir: dir, manifest: m, settings: SopSettings(), run: run).system
            .compactMap { $0["text"] as? String }.joined()
    }

    /// A project named by the app, generated once in Specific wording.
    private func generatedOnce() async throws -> (ProjectStore, String, String) {
        let (store, path, dir) = try await makeProject(shots: 1)
        _ = try await store.renameProject(at: path, title: stamp)
        _ = try await applySopEdits(store: store, projectPath: path, plan: SopEditPlan(
            title: claudeTitle, intro: nil,
            steps: [SopStepEdit(stepNumber: 1, caption: "Open Okta", body: "Click Okta.", sectionHeading: nil, sectionBody: nil)]),
            model: .sonnet55, tone: .professional)
        return (store, path, dir)
    }

    // MARK: Claude's own title

    /// The finding: after a Specific run, Claude's product-specific title went back
    /// as "written by a person", so a General regeneration kept it.
    func testRegeneratingInGeneralReplacesTheTitleTheLastRunWrote() async throws {
        let (store, path, dir) = try await generatedOnce()
        let m = try await store.openProject(at: path).manifest
        XCTAssertEqual(m.title, claudeTitle)
        XCTAssertEqual(m.sopTitleRewrite, claudeTitle, "the apply records what it wrote")
        let general = try userText(m, dir, run: SopRun(wording: .general))
        XCTAssertTrue(general.contains("written by shotAI's previous generation"))
        XCTAssertTrue(general.contains("in general terms"))
        XCTAssertFalse(general.contains("written by a person"))
        XCTAssertTrue(general.contains("never return the current name") == false
                      && general.contains("Keep the current name only if it already reads that way"),
                      "a title that is already general may stay")
    }

    /// Specific keeps treating the last run's title as it always has, so its
    /// request is unchanged (see SpecificRequestGoldenTests).
    func testSpecificStillTreatsTheLastRunsTitleAsBefore() async throws {
        let (store, path, dir) = try await generatedOnce()
        let m = try await store.openProject(at: path).manifest
        let specific = try userText(m, dir, run: SopRun(wording: .specific))
        XCTAssertTrue(specific.contains("written by a person"))
        XCTAssertFalse(specific.contains("previous generation"))
    }

    /// A rename on any build breaks the match: the name is then the person's.
    func testARenameMakesTheTitleThePersonsAgain() async throws {
        let (store, path, dir) = try await generatedOnce()
        _ = try await store.renameProject(at: path, title: "MFA reset for the front desk")
        let m = try await store.openProject(at: path).manifest
        let general = try userText(m, dir, run: SopRun(wording: .general))
        XCTAssertTrue(general.contains("written by a person"))
        XCTAssertFalse(general.contains("previous generation"))
    }

    private func applyTitle(_ store: ProjectStore, _ path: String, _ t: String) async throws {
        _ = try await applySopEdits(store: store, projectPath: path, plan: SopEditPlan(
            title: t, intro: nil,
            steps: [SopStepEdit(stepNumber: 1, caption: "Open Okta", body: "Click Okta.", sectionHeading: nil, sectionBody: nil)]),
            model: .sonnet55, tone: .professional)
    }

    /// The verification finding: a person's name that the next run returned
    /// unchanged (as it was told to) was recorded as Claude's, and the run after
    /// that, in General, replaced it.
    func testAPersonsNameKeptByARegenerationStaysThePersons() async throws {
        let (store, path, dir) = try await generatedOnce()
        _ = try await store.renameProject(at: path, title: "Okta MFA reset for Finance")
        try await applyTitle(store, path, "Okta MFA reset for Finance")
        let m = try await store.openProject(at: path).manifest
        XCTAssertNil(m.sopTitleRewrite)
        let general = try userText(m, dir, run: SopRun(wording: .general))
        XCTAssertTrue(general.contains("written by a person"))
        XCTAssertFalse(general.contains("previous generation"))
    }

    /// Claude's title replacing Claude's own title stays Claude's, run after run.
    func testClaudesTitleStaysClaudesAcrossRuns() async throws {
        let (store, path, dir) = try await generatedOnce()
        try await applyTitle(store, path, "Resetting MFA for a Finance user in Okta")
        let m = try await store.openProject(at: path).manifest
        XCTAssertEqual(m.sopTitleRewrite, "Resetting MFA for a Finance user in Okta")
        XCTAssertTrue(try userText(m, dir, run: SopRun(wording: .general)).contains("previous generation"))
    }

    /// Only a name the app wrote was Claude's to replace in the first place. A
    /// person's name that Claude improved keeps being treated as the person's.
    func testATitleThatImprovedAPersonsNameIsStillThePersons() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        _ = try await store.renameProject(at: path, title: "mfa reset")
        _ = try await applySopEdits(store: store, projectPath: path, plan: SopEditPlan(
            title: "Resetting MFA in Okta", intro: nil,
            steps: [SopStepEdit(stepNumber: 1, caption: "Open Okta", body: "Click Okta.", sectionHeading: nil, sectionBody: nil)]),
            model: .sonnet55, tone: .professional)
        let m = try await store.openProject(at: path).manifest
        XCTAssertTrue(try userText(m, dir, run: SopRun(wording: .general)).contains("written by a person"))
    }

    func testUndoAndRevertPutTheRecordBackWithTheTitle() async throws {
        let (store, path, _) = try await makeProject(shots: 1)
        _ = try await store.renameProject(at: path, title: stamp)
        func plan(_ t: String) -> SopEditPlan {
            SopEditPlan(title: t, intro: nil, steps: [SopStepEdit(stepNumber: 1, caption: "C", body: "B.", sectionHeading: nil, sectionBody: nil)])
        }
        _ = try await applySopEdits(store: store, projectPath: path, plan: plan("First"), model: .sonnet55, tone: .professional)
        let second = try await applySopEditsUndoable(store: store, projectPath: path, plan: plan("Second"),
                                                     model: .sonnet55, tone: .professional)
        XCTAssertEqual(second.manifest.sopTitleRewrite, "Second")
        let undone = try await undoSopRun(store: store, projectPath: path, undo: second.undo)
        XCTAssertEqual(undone.title, "First")
        XCTAssertEqual(undone.sopTitleRewrite, "First", "the first run's title is still the first run's")
        let reverted = try await revertSop(store: store, projectPath: path)
        XCTAssertEqual(reverted.title, stamp)
        XCTAssertNil(reverted.sopTitleRewrite)
    }

    // MARK: The author's overview

    /// The finding: General told the model to write "the `intro`" in general terms
    /// even when the overview was the author's, and the generalized body was then
    /// sent back as the author's on every later run.
    func testAnAuthorsOverviewIsNotTheModelsToGeneralize() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        _ = try await store.setIntro(at: path, heading: "Overview", body: "Finance help desk: add a new hire in Okta.")
        let m = try await store.openProject(at: path).manifest
        XCTAssertEqual(m.introEditedByUser, true)
        let system = try systemText(m, dir, run: SopRun(wording: .general))
        XCTAssertTrue(system.contains(PromptParagraph.generalScope(authorOverview: true)))
        XCTAssertTrue(system.contains("anything you add to the `intro` beyond the overview the author wrote"))
        XCTAssertTrue(try userText(m, dir, run: SopRun(wording: .general))
            .contains("this overview is the author's: keep every name, value and link it states"))

        var none = m
        none.intro = nil
        none.introEditedByUser = nil
        XCTAssertTrue(try systemText(none, dir, run: SopRun(wording: .general))
            .contains(PromptParagraph.generalScope(authorOverview: false)), "no overview: the intro is the model's")
    }

    // MARK: The author's blocks

    func testEveryAuthorBlockIsMarkedAsTheAuthorsInGeneral() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        for (i, kind) in [CalloutKind?.none, .note, .caution, .warning, .section].enumerated() {
            _ = try await store.addTextStep(at: path, atIndex: i, heading: "H\(i)", body: "Okta \(i)", callout: kind)
        }
        let m = try await store.openProject(at: path).manifest
        let general = try userText(m, dir, run: SopRun(wording: .general))
        XCTAssertEqual(general.components(separatedBy: PromptParagraph.authorBlockGeneral).count - 1, 5,
                       "one under each of the five author blocks")
        XCTAssertFalse(try userText(m, dir, run: SopRun(wording: .specific)).contains(PromptParagraph.authorBlockGeneral))
    }

    // MARK: Settings and the run

    func testGeneralKeepsTheToneAndTheStandingInstructions() {
        for tone in [SopTone.professional, .friendly, .concise, .detailed] {
            let p = buildSystemPrompt(settings: SopSettings(tone: tone, customInstructions: "Refer to customers as members."),
                                      run: SopRun(wording: .general, instructions: "Call it the portal."))
            XCTAssertTrue(p.contains(TONE_PROMPT[tone]!), "\(tone)")
            let standing = p.range(of: "Additional instructions from the user:\nRefer to customers as members.")
            let once = p.range(of: "Instructions from the author for this SOP:\nCall it the portal.")
            XCTAssertNotNil(standing)
            XCTAssertNotNil(once)
            if let standing, let once { XCTAssertLessThan(standing.lowerBound, once.lowerBound) }
            XCTAssertTrue(p.hasSuffix("Call it the portal."))
        }
    }

    /// A project's Specific choice wins over a General default in Settings.
    func testTheRunsSpecificBeatsAGeneralSetting() async throws {
        let (store, path, dir) = try await makeProject(shots: 1)
        let m = try await store.openProject(at: path).manifest
        let r = try assembleRequest(dir: dir, manifest: m, settings: SopSettings(wording: .general),
                                    run: SopRun(wording: .specific))
        XCTAssertEqual(r.system.compactMap { $0["text"] as? String }.joined(),
                       buildSystemPrompt(settings: SopSettings(), run: SopRun(wording: .specific)))
    }
}
