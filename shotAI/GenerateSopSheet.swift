import AppKit
import SOPKit
import ShotModel
import SwiftUI

/// The Generate sheet: what will be sent and roughly what it costs, the wording for
/// this run, and instructions for this SOP only. Both choices are remembered with
/// the project and filled in next time. Replaces the old confirmation dialog, which
/// could not hold a picker or a text field.
struct GenerateSopSheet: View {
    @Environment(AppModel.self) private var model
    let estimate: SopEstimate
    @State private var wording: SopWording
    @State private var instructions: String

    init(estimate: SopEstimate, draft: SopRun) {
        self.estimate = estimate
        _wording = State(initialValue: draft.wording)
        _instructions = State(initialValue: draft.instructions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Generate this SOP with Claude?").font(.headline)
            Text(summary)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Picker("Wording", selection: $wording) {
                    ForEach(SOP_WORDINGS, id: \.id) { Text($0.label).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if let b = SOP_WORDINGS.first(where: { $0.id == wording })?.blurb {
                    Text(b).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Instructions for this SOP (optional)").font(.callout)
                TextEditor(text: $instructions)
                    .font(.callout)
                    .frame(minHeight: 70, maxHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .onChange(of: instructions) { old, new in
                        // Over the cap, keep what was there and as much of the new
                        // text as fits, never the other way round.
                        let capped = capTextEdit(old: old, new: new, limit: SOP_RUN_INSTRUCTIONS_MAX)
                        if capped != new { instructions = capped; NSSound.beep() }
                    }
                HStack(alignment: .firstTextBaseline) {
                    Text("Saved with this project and filled in next time. Standing instructions for every SOP are in Settings ▸ AI.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text("\(instructions.count)/\(SOP_RUN_INSTRUCTIONS_MAX)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if model.hasSavedSopInstructions {
                    // Cancel discards edits and Generate sends a paid request, so
                    // without this the saved notes could not be removed at all.
                    Button("Forget saved instructions") {
                        instructions = ""
                        Task { await model.forgetSopInstructions() }
                    }
                    .buttonStyle(.link).font(.caption)
                    .help("Remove this project's saved instructions now, without generating.")
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.dismissSopEstimate() }
                    .keyboardShortcut(.cancelAction)
                Button("Generate") {
                    model.confirmGenerateSop(run: SopRun(wording: wording, instructions: instructions))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// What is sent and what it costs. The count was taken with the choices this
    /// sheet opened with; changing them moves it by the length of the text, which
    /// is small beside the screenshots, hence "about".
    private var summary: String {
        let cost = estimate.estCostUsd.map { String(format: "Estimated cost ≈ $%.2f.", $0) }
            ?? "No cost estimate: shotAI has no price for \(model.modelName(estimate.model))."
        return "Sends your redaction-baked screenshots + text (about \(estimate.inputTokens) input tokens) to Anthropic. "
            + "\(cost) This rewrites every step's caption and instructions — you can revert."
    }
}
