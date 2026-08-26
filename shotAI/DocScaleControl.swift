import ShotModel
import SwiftUI

/// Per-project document scale (#83) — how wide this guide renders, in the report
/// and in every export.
///
/// The slider's value is an INDEX into `DocScale.detents`, never a raw scale.
/// That is deliberate: a continuous slider can emit a value between detents that
/// the model then has to quietly correct, and "the UI shows 83% but the file says
/// 85%" is a bug that only surfaces after a round trip. Indexing makes an
/// off-detent value unrepresentable.
struct DocScaleControl: View {
    @Environment(AppModel.self) private var model
    /// Live index while dragging. `nil` when not dragging, so the committed
    /// value shows through.
    @State private var dragIndex: Double?

    private var committedIndex: Double {
        Double(DocScale.detents.firstIndex(of: model.docScaleCommitted) ?? 7)
    }
    private var index: Double { dragIndex ?? committedIndex }
    private var shown: Double { DocScale.detents[Int(index.rounded())] }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 11))
                .foregroundStyle(Palette.ink3)
                .accessibilityHidden(true)

            Slider(
                value: Binding(
                    get: { index },
                    set: { new in
                        // Preview only. Persisting per change would mean up to 13
                        // serialized disk writes for one drag.
                        dragIndex = new
                        model.previewDocScale(DocScale.detents[Int(new.rounded())])
                    }),
                in: 0...Double(DocScale.detents.count - 1),
                step: 1
            ) { editing in
                // Persist on RELEASE. The committed value is what drives anything
                // that must not react mid-drag.
                if !editing {
                    let target = shown
                    dragIndex = nil
                    Task { await model.commitDocScale(target) }
                }
            }
            .frame(width: 110)
            .controlSize(.small)

            Text("\(Int((shown * 100).rounded()))%")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Palette.ink2)
                .frame(width: 34, alignment: .trailing)
        }
        .help("Document size — how wide this guide renders in the report and every export (\(Int(DocScale.min * 100))–\(Int(DocScale.max * 100))%)")
        .accessibilityLabel("Document size")
        .accessibilityValue("\(Int((shown * 100).rounded()))%")
    }
}
