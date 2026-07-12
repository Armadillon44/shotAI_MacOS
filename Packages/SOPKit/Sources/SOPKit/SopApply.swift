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

/// A fresh AI-inserted text step (intro/section). `aiInserted` marks it so the
/// next generation's base-rebuild drops it (no compounding).
private func makeAITextStep(heading: String, body: String) -> ProjectStep {
    ProjectStep(
        id: UUID().uuidString.lowercased(), order: 0, kind: .text, screenshot: "",
        trigger: .hotkey, heading: heading, body: body, aiInserted: true)
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
            model: model.rawValue, tone: tone, at: ProjectJSON.isoNow())

        // Overview is a PREAMBLE on the manifest, not a step. A fresh generate
        // replaces it (or clears it when the model returned none).
        if let intro = plan.intro, !(intro.heading.isEmpty && intro.body.isEmpty) {
            manifest.intro = SopIntro(heading: intro.heading, body: intro.body)
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
                next.append(makeAITextStep(heading: sh, body: e.sectionBody ?? ""))
            }
            var edited = step
            let cap = e.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.caption = cap.isEmpty ? step.caption : cap
            let bod = e.body.trimmingCharacters(in: .whitespacesAndNewlines)
            edited.body = bod.isEmpty ? (step.body ?? "") : bod
            edited.note = e.note ?? step.note  // nil leaves the existing note
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

/// Revert Claude's inline edits: restore the pre-generation snapshot (steps +
/// title + intro) and clear it. Throws if there's nothing to revert.
@discardableResult
public func revertSop(store: ProjectStore, projectPath: String) async throws -> ProjectManifest {
    try await store.mutate(at: projectPath) { manifest in
        guard let backup = manifest.sopBackup else { throw SopApplyError.nothingToRevert }
        manifest.steps = backup.steps
        ProjectStore.renumber(&manifest.steps)
        manifest.title = backup.title
        manifest.intro = backup.intro
        manifest.sopBackup = nil
    }
}
