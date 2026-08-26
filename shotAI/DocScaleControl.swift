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
struct DocScaleControl: View {
    @Environment(AppModel.self) private var model

    /// Live index while dragging or stepping; nil when the committed value shows.
    @State private var dragIndex: Double?
    /// Buffered keystrokes. nil when not mid-edit, so the committed value shows.
    @State private var draft: String?
    @State private var editing = false

    private var committedIndex: Double {
        Double(DocScale.detentIndex(of: model.docScaleCommitted))
    }
    private var index: Double { dragIndex ?? committedIndex }
    private var shownScale: Double { DocScale.detent(at: Int(index.rounded())) }
    private var shownPercent: Int { Int((shownScale * 100).rounded()) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)

            Slider(
                value: Binding(get: { index }, set: { new in
                    dragIndex = new
                    model.previewDocScale(DocScale.detent(at: Int(new.rounded())))
                }),
                in: 0...Double(DocScale.detents.count - 1),
                step: 1
            ) { isEditing in
                if !isEditing {
                    let target = shownScale
                    dragIndex = nil
                    Task { await model.commitDocScale(target) }
                }
            }
            .frame(width: 92)
            .controlSize(.small)

            percentField

            Stepper("", onIncrement: { step(+1) }, onDecrement: { step(-1) })
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Step document size")
        }
        .help("Document size — how wide this guide renders in the report and every export (\(Int(DocScale.min * 100))–\(Int(DocScale.max * 100))%). Type a value, or use ↑ ↓.")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Document size")
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
    private func step(_ delta: Int) {
        let current = Int(index.rounded())
        let next = min(max(current + delta, 0), DocScale.detents.count - 1)
        guard next != current else { return }
        draft = nil
        dragIndex = Double(next)
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
    private func typed(_ raw: String) {
        let digits = String(raw.filter(\.isNumber).prefix(3))
        draft = digits
        // Exact membership, NOT `detentIndex(of:)` — that snaps, so it would
        // report `83` as legal and apply 85% while the user was still typing.
        guard let pct = Int(digits),
              let i = DocScale.detents.firstIndex(of: Double(pct) / 100)
        else { return }
        dragIndex = Double(i)
        apply(DocScale.detent(at: i))
    }

    /// Return or blur: snap and commit. An EMPTY field reverts to the committed
    /// value rather than snapping to the minimum — clearing a field is not a
    /// request for 65%.
    private func commitDraft() {
        guard let d = draft else { return }
        draft = nil
        guard let pct = Int(d) else { dragIndex = nil; return }
        let i = DocScale.detentIndex(of: Double(pct) / 100)
        dragIndex = Double(i)
        apply(DocScale.detent(at: i))
    }

    /// Escape: throw the edit away and put the committed value back on screen.
    private func abandon() {
        draft = nil
        dragIndex = nil
        model.previewDocScale(model.docScaleCommitted)
    }

    private func apply(_ scale: Double) {
        model.previewDocScale(scale)
        Task { await model.commitDocScale(scale) }
    }
}
