import ShotModel
import SwiftUI

/// Per-project document scale (#83) — how wide this guide renders, in the report
/// and in every export.
///
/// Three ways in, matching the Windows control:
///
/// | Action | Behaviour |
/// |---|---|
/// | slider drag | previews live, persists on RELEASE |
/// | arrow key / stepper | applies IMMEDIATELY |
/// | partial typing (`1`, `10`, `83`) | buffered |
/// | typed value already a legal detent (`100`, `85`) | applies immediately |
/// | Return / blur | commits and snaps (`83`→`85`, `200`→`125`) |
/// | Escape | abandons |
/// | cleared then blurred | reverts; does NOT snap to the minimum |
///
/// The slider's value is an INDEX into `DocScale.detents`, never a raw scale, so
/// an off-detent value the model would have to quietly correct is
/// unrepresentable. The slider is the one input that does not persist per
/// change: one drag crosses up to 13 detents, and each would be a serialized
/// disk write.
///
/// What the control displays is DERIVED from `model.docScale`, never mirrored
/// into local state. A local copy is how the control ends up disagreeing with
/// the document: it survives a failed write, so the field goes on showing a
/// percentage the manifest never got, and it lags a commit, so releasing the
/// slider flashes the pre-drag value while the write is in flight.
struct DocScaleControl: View {
    @Environment(AppModel.self) private var model

    /// Buffered keystrokes. nil when not mid-edit, so the live value shows.
    @State private var draft: String?
    @State private var editing = false
    /// The project this edit belongs to, captured while it is still open.
    ///
    /// A blur fires as the toolbar item is torn down — clicking Back is the
    /// ordinary case — and by then `opened` is already nil, so a commit that
    /// resolved the path at write time would silently drop the typed value.
    @State private var editTarget: String?

    /// Live scale, including an uncommitted preview, snapped to a detent index.
    private var index: Int { DocScale.detentIndex(of: model.docScale) }
    private var shownPercent: Int { Int((DocScale.detent(at: index) * 100).rounded()) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)

            Slider(
                value: Binding(get: { Double(index) },
                               set: { model.previewDocScale(DocScale.detent(at: Int($0.rounded()))) }),
                in: 0...Double(DocScale.detents.count - 1),
                step: 1
            ) { isEditing in
                if !isEditing { apply(DocScale.detent(at: index)) }
            }
            .frame(width: 92)
            .controlSize(.small)
            // The slider's value is a detent INDEX, so without these VoiceOver
            // announces "7" or "58%" — neither of which is a document size.
            .accessibilityLabel("Document size")
            .accessibilityValue("\(shownPercent) percent")

            percentField

            Stepper("", onIncrement: { step(+1) }, onDecrement: { step(-1) })
                .labelsHidden()
                .controlSize(.small)
                // Hold the window resize while the pointer is parked here, or a
                // second click lands where the button USED to be — the window
                // grows center-preserving, so the right-aligned toolbar walks
                // right by half the delta on every step. Released on exit, which
                // is the honest "done clicking" signal. See
                // AppModel.docScaleStepperHot.
                .onHover { model.docScaleStepperHot = $0 }
                .onDisappear { model.docScaleStepperHot = false }
                .accessibilityLabel("Step document size")
                .accessibilityValue("\(shownPercent) percent")
        }
        .help("Document size — how wide this guide renders in the report and every export (\(Int(DocScale.min * 100))–\(Int(DocScale.max * 100))%). Type a value, or use ↑ ↓.")
    }

    private var percentField: some View {
        HStack(spacing: 1) {
            PercentField(text: draft ?? String(shownPercent),
                         editing: $editing,
                         onType: typed, onStep: step,
                         onCommit: commitDraft, onAbandon: abandon)
                .frame(width: 26, height: 16)
            Text("%")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.ink3)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Palette.field))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(editing ? Palette.accent : Palette.controlBd,
                    lineWidth: editing ? 1.5 : 1))
        .accessibilityLabel("Document size percent")
        .accessibilityValue("\(shownPercent) percent")
    }

    // MARK: Actions

    /// One detent, applied immediately — from ↑/↓ or the stepper. A stepper that
    /// only previewed would read as the control ignoring the click.
    ///
    /// Steps from whatever is ON SCREEN, so a buffered "83" plus ↑ moves up from
    /// 85 rather than throwing the typed value away and stepping off the
    /// committed one.
    private func step(_ delta: Int) {
        let base = draft.flatMap(Int.init).map { DocScale.detentIndex(of: Double($0) / 100) } ?? index
        let next = min(max(base + delta, 0), DocScale.detents.count - 1)
        draft = nil
        editTarget = nil
        guard next != index || next != base else { return }
        apply(DocScale.detent(at: next))
    }

    /// Typing is BUFFERED, except when what has been typed is already a legal
    /// detent — "85" then applies without needing Return, while "8" and "1" wait.
    ///
    /// Note this asks only "is this value legal", and takes no signal from the
    /// event itself. The Windows port tried to tell a step from a keystroke by
    /// inspecting the input event; the probe that appeared to prove they were
    /// distinguishable was dispatching its own synthetic event and measuring
    /// itself.
    ///
    /// The draft must never be SHORTER than what the user typed — see the note
    /// in `PercentField.updateNSView`. Out-of-range digits are left alone here
    /// and clamped on commit; only non-digits, and a 5th character, are refused.
    private func typed(_ raw: String) {
        editTarget = editTarget ?? model.selectedPath ?? model.opened?.dir
        let digits = String(raw.filter(\.isNumber).prefix(4))
        draft = digits
        guard let pct = Int(digits),
              let i = DocScale.detents.firstIndex(of: Double(pct) / 100)
        else { return }
        // Exact membership, NOT `detentIndex(of:)` — that snaps, so it would
        // report "83" as legal and jump to 85% while the user was still typing.
        apply(DocScale.detent(at: i))
    }

    /// Return or blur: snap and commit. An EMPTY field reverts to the committed
    /// value rather than snapping to the minimum — clearing a field is not a
    /// request for 65%.
    private func commitDraft() {
        guard let d = draft else { return }
        draft = nil
        defer { editTarget = nil }
        guard let pct = Int(d) else { return }
        apply(DocScale.detent(at: DocScale.detentIndex(of: Double(pct) / 100)))
    }

    /// Escape: throw the edit away.
    ///
    /// Clears the preview rather than setting it to the committed value. Setting
    /// it leaves `AppModel.docScalePreview` non-nil with nothing queued to clear
    /// it — only a commit does that — so the abandoned project's scale shadowed
    /// every project opened afterwards for the rest of the session.
    private func abandon() {
        draft = nil
        editTarget = nil
        model.clearDocScalePreview()
    }

    private func apply(_ scale: Double) {
        let target = editTarget ?? model.selectedPath ?? model.opened?.dir
        model.previewDocScale(scale)
        Task { await model.commitDocScale(scale, at: target) }
    }
}
