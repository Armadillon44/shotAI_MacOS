import Foundation
import ShotModel

// Apply / revert Claude's inline SOP edit plan against a project's steps. Ported
// from sop-apply.ts. Runs through ProjectStore.mutate (actor-serialized atomic
// manifest write), so this stays storage-agnostic while reusing the same
// `!aiInserted` base-rebuild rule the request assembler depends on.

public enum SopApplyError: Error, LocalizedError, Equatable {
    case nothingToRevert
    case changedSinceGeneration
    public var errorDescription: String? {
        switch self {
        case .nothingToRevert: "Nothing to revert — no AI edits are recorded for this project."
        case .changedSinceGeneration:
            "The project changed after this generation, so it can't be undone on its own. "
                + "Use Revert to original to restore the text from before AI generation."
        }
    }
}

/// What one generation changed, so it alone can be undone.
///
/// Revert restores the PRE-AI original, which after a second generation throws
/// away a good first one along with a bad second one. This undoes just the last
/// run. It is exact because it refuses unless the project is still precisely what
/// that run produced: any later edit, from any path (the report, a recording, the
/// annotation editor), makes it unavailable rather than silently discarding the edit.
public struct SopRunUndo: Sendable, Equatable {
    struct State: Sendable, Equatable {
        let steps: [ProjectStep]
        let title: String
        let intro: SopIntro?
        let introEditedByUser: Bool?
        let sopBackup: SopBackup?
        init(_ m: ProjectManifest) {
            steps = m.steps; title = m.title; intro = m.intro
            introEditedByUser = m.introEditedByUser; sopBackup = m.sopBackup
        }
        func restore(into m: inout ProjectManifest) {
            m.steps = steps; m.title = title; m.intro = intro
            m.introEditedByUser = introEditedByUser; m.sopBackup = sopBackup
        }
    }
    let before: State
    let after: State
}

/// A fresh AI-inserted section divider — a text step tagged `callout: .section`
/// so the report/exports render it as a non-counted phase heading (not a numbered
/// step). `aiInserted` marks it so the next generation's base-rebuild drops it
/// (no compounding).
private func makeAISectionStep(heading: String, body: String) -> ProjectStep {
    ProjectStep(
        id: UUID().uuidString.lowercased(), order: 0, kind: .text, screenshot: "",
        trigger: .hotkey, heading: heading, body: body, callout: .section, aiInserted: true)
}

/// Apply the plan IN-LINE: snapshot the pristine pre-AI state for revert, set the
/// intro preamble, rewrite each referenced SHOT step's caption/body/note, insert
/// optional section headings, refine the title, and renumber. Author text steps
/// pass through; edits mis-keyed to a non-shot number are ignored. Returns the
/// updated manifest.
@discardableResult
public func applySopEdits(
    store: ProjectStore, projectPath: String, plan: SopEditPlan, model: SopModelId, tone: SopTone
) async throws -> ProjectManifest {
    try await applySopEditsUndoable(store: store, projectPath: projectPath, plan: plan, model: model, tone: tone).manifest
}

/// `applySopEdits`, also returning what is needed to undo exactly this run.
public func applySopEditsUndoable(
    store: ProjectStore, projectPath: String, plan: SopEditPlan, model: SopModelId, tone: SopTone
) async throws -> (manifest: ProjectManifest, undo: SopRunUndo) {
    // Captured inside the same atomic mutate that applies, so the "before" is
    // exactly the state the plan was applied to.
    final class Before: @unchecked Sendable { var state: SopRunUndo.State? }
    let before = Before()
    let after = try await store.mutate(at: projectPath) { manifest in
        before.state = SopRunUndo.State(manifest)
        try applyPlan(plan, to: &manifest, model: model, tone: tone)
    }
    return (after, SopRunUndo(before: before.state!, after: SopRunUndo.State(after)))
}

/// Undo the generation `undo` describes, if the project is still exactly what it
/// produced. Otherwise throws `changedSinceGeneration` and changes nothing.
@discardableResult
public func undoSopRun(store: ProjectStore, projectPath: String, undo: SopRunUndo) async throws -> ProjectManifest {
    try await store.mutate(at: projectPath) { manifest in
        guard SopRunUndo.State(manifest) == undo.after else { throw SopApplyError.changedSinceGeneration }
        undo.before.restore(into: &manifest)
    }
}

private func applyPlan(_ plan: SopEditPlan, to manifest: inout ProjectManifest, model: SopModelId, tone: SopTone) throws {
    // Preserve the FIRST snapshot (pristine pre-AI state) across regenerations
    // so revert always restores the true original, never a prior AI pass.
    let backup = manifest.sopBackup ?? SopBackup(
        steps: manifest.steps, title: manifest.title, intro: manifest.intro,
        introEditedByUser: manifest.introEditedByUser,
        model: model.rawValue, tone: tone, at: ProjectJSON.isoNow())

    // Overview is a PREAMBLE on the manifest, not a step.
    let authoredIntro = manifest.introEditedByUser == true ? manifest.intro : nil
    if let intro = plan.intro, !(intro.heading.isEmpty && intro.body.isEmpty) {
        if let authored = authoredIntro {
            // PIN THE AUTHOR'S HEADING IN CODE, and keep the flag.
            //
            // The body is accepted as a reword; the heading is restored
            // verbatim. Asking the model to leave the heading alone is not a
            // guarantee — an instruction it can quietly ignore is not a
            // guarantee — and the heading is exactly what a user watched get
            // overwritten (Armadillon44/shotAI#64).
            //
            // Note the DELIBERATE asymmetry with captions: applying an edit
            // DROPS `captionEditedByUser`, because there the model's caption
            // replaces the human text outright, so the flag must not outlive
            // what it describes. Here the author's heading is still in the
            // manifest verbatim afterwards, so the flag has to persist or the
            // next run stops protecting it. Do not "fix" one to match the
            // other.
            manifest.intro = SopIntro(
                heading: authored.heading.isEmpty ? intro.heading : authored.heading,
                body: intro.body)
        } else {
            manifest.intro = SopIntro(heading: intro.heading, body: intro.body)
            manifest.introEditedByUser = nil
        }
    } else if manifest.introEditedByUser == true {
        // The model returned no overview and the AUTHOR wrote this one. Keep
        // it, flag and all.
        //
        // This branch used to be an unconditional `manifest.intro = nil`,
        // which was right while the overview was purely Claude's: a
        // regenerate that produced none should clear the previous one. #73
        // made the overview author-writable and turned that same line into
        // silent DATA LOSS — write an overview, generate, get no intro back,
        // and your text is gone with no undo short of Revert AI edits.
        //
        // Deliberately does nothing: leave manifest.intro and the flag alone.
    } else {
        manifest.intro = nil
    }

    // Rebuild from the non-AI base (drop a prior run's inserts).
    let base = manifest.steps.filter { $0.aiInserted != true }
    let editByNum = effectiveEdits(plan)

    // Look edits up by the step each number meant WHEN THE REQUEST WAS BUILT,
    // not by where that step sits now. See `SopEditPlan.boundStepIds`.
    let editFor: (Int, ProjectStep) -> SopStepEdit?
    if let bound = plan.boundStepIds {
        var byId: [String: SopStepEdit] = [:]
        for (num, e) in editByNum { if let id = bound[num] { byId[id] = e } }
        editFor = { _, step in byId[step.id] }
        let then = bound.sorted { $0.key < $1.key }.map(\.value)
        if then != base.map(\.id) {
            // Not an error: binding by id is exactly what makes this safe.
            // Recorded because it is the case that used to misplace text.
            Log.sop.notice("apply: steps changed while generating; edits matched by step id")
        }
    } else {
        editFor = { i, _ in editByNum[i + 1] }
    }

    var next: [ProjectStep] = []
    for (i, step) in base.enumerated() {
        if step.kind == .text { next.append(step); continue }  // author text passes through
        guard let e = editFor(i, step) else { next.append(step); continue }
        if let sh = e.sectionHeading, !sh.isEmpty {
            next.append(makeAISectionStep(heading: sh, body: e.sectionBody ?? ""))
        }
        var edited = step
        let cap = e.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cap.isEmpty {
            edited.caption = cap
            // The AI just overwrote whatever was here, so any previous
            // author edit is gone — clear the flag or the next regeneration
            // would send Claude its own text back as if a human wrote it.
            edited.captionEditedByUser = nil
        }
        let bod = e.body.trimmingCharacters(in: .whitespacesAndNewlines)
        edited.body = bod.isEmpty ? (step.body ?? "") : bod
        // The generator no longer writes `note`; keep whatever was there
        // (a manual/legacy note round-trips untouched).
        edited.note = step.note
        next.append(edited)
    }

    manifest.steps = next
    ProjectStore.renumber(&manifest.steps)
    if let t = plan.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        manifest.title = t
    }
    manifest.sopBackup = backup
}

/// Revert Claude's inline edits while PRESERVING anything the user added after
/// generation. Rather than wholesale-restoring the snapshot (which would also
/// wipe manually-added steps like a callout inserted post-generation), walk the
/// CURRENT steps: drop the AI's inserted section/intro steps, restore each step
/// that existed at snapshot time to its pre-AI text, and keep every step whose id
/// is not in the snapshot (a manual addition) exactly where the user put it.
/// Title + intro are restored to the snapshot. Throws if there's nothing to revert.
@discardableResult
public func revertSop(store: ProjectStore, projectPath: String) async throws -> ProjectManifest {
    try await store.mutate(at: projectPath) { manifest in
        guard let backup = manifest.sopBackup else { throw SopApplyError.nothingToRevert }
        var originalById: [String: ProjectStep] = [:]
        for s in backup.steps { originalById[s.id] = s }

        var next: [ProjectStep] = []
        for step in manifest.steps {
            if step.aiInserted == true { continue }                 // drop AI-inserted intro/sections
            if let original = originalById[step.id] {
                // Restore only what generation writes. It used to restore the
                // WHOLE step, so Revert also rolled back annotations, crop, zoom
                // and the render revision made since — and could leave a step's
                // annotation list disagreeing with its render file, dropping a
                // redaction from the editor that is still baked into the image.
                var restored = step
                restored.caption = original.caption
                restored.captionEditedByUser = original.captionEditedByUser
                restored.body = original.body
                next.append(restored)
            } else {
                next.append(step)                                  // keep a manual post-generation addition
            }
        }

        manifest.steps = next
        ProjectStore.renumber(&manifest.steps)
        manifest.title = backup.title
        manifest.intro = backup.intro
        // Authorship, not just the text: a reverted author overview that comes
        // back unflagged is free to be rewritten by the very next generate (#80).
        manifest.introEditedByUser = backup.introEditedByUser
        manifest.sopBackup = nil
    }
}

/// The plan reduced to what will actually be APPLIED: one entry per step
/// number, LAST WINS on a duplicate.
///
/// Shared with the guard in `SopService` on purpose. That guard scanned the raw
/// plan, so a plan carrying two entries for one step — a good one followed by an
/// empty one — passed it, and then the empty entry won here and nothing landed.
/// The user got a success with no change: exactly the failure #114 fixed, through
/// a different door.
///
/// Two pieces of logic deciding "what lands" is how that happens, so there is now
/// one. A guard that re-implements this would drift from it again the moment
/// either changed. Found by the Windows port, which hit the same shape
/// implementing its equivalent (Armadillon44/shotAI#108).
func effectiveEdits(_ plan: SopEditPlan) -> [Int: SopStepEdit] {
    var out: [Int: SopStepEdit] = [:]
    for e in plan.steps { out[e.stepNumber] = e }
    return out
}

/// The steps the request assembler shows Claude, with the number each is shown
/// under: a prior run's AI inserts dropped, and author text blocks COUNTED, so the
/// only screenshot in a [text, shot] project is number 2.
///
/// The guard, the binding and position-matched apply all number through this so
/// they cannot disagree with one another. `RequestAssembler` numbers the same way
/// inline; `testTheBindingMatchesTheNumbersTheAssemblerShows` pins the two together.
func numberedBase(_ manifest: ProjectManifest) -> [(number: Int, step: ProjectStep)] {
    manifest.steps.filter { $0.aiInserted != true }.enumerated().map { ($0.offset + 1, $0.element) }
}

/// `stepNumber` → step id for the manifest a request is being built from, or nil
/// when the ids are not unique and so cannot each name one step. A hand-edited or
/// foreign `project.json` can carry duplicates; matching by id there would write
/// one edit onto several steps, so it falls back to position, the old behaviour.
func stepNumberBinding(_ manifest: ProjectManifest) -> [Int: String]? {
    let numbered = numberedBase(manifest)
    let ids = numbered.map(\.step.id)
    guard Set(ids).count == ids.count else {
        Log.sop.error("binding: duplicate step ids in manifest; edits will be matched by position")
        return nil
    }
    return Dictionary(uniqueKeysWithValues: numbered.map { ($0.number, $0.step.id) })
}
