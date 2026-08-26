import Foundation
import ShotModel

// Apply / revert Claude's inline SOP edit plan against a project's steps. Ported
// from sop-apply.ts. Runs through ProjectStore.mutate (actor-serialized atomic
// manifest write), so this stays storage-agnostic while reusing the same
// `!aiInserted` base-rebuild rule the request assembler depends on.

public enum SopApplyError: Error, LocalizedError, Equatable {
    case nothingToRevert
    public var errorDescription: String? {
        switch self {
        case .nothingToRevert: "Nothing to revert — no AI edits are recorded for this project."
        }
    }
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
    try await store.mutate(at: projectPath) { manifest in
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

        // Rebuild from the non-AI base (drop a prior run's inserts), matching the
        // numbering the assembler showed Claude.
        let base = manifest.steps.filter { $0.aiInserted != true }
        var editByNum: [Int: SopStepEdit] = [:]
        for e in plan.steps { editByNum[e.stepNumber] = e }

        var next: [ProjectStep] = []
        for (i, step) in base.enumerated() {
            if step.kind == .text { next.append(step); continue }  // author text passes through
            guard let e = editByNum[i + 1] else { next.append(step); continue }
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
                next.append(original)                               // revert AI edits to a pre-existing step
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
