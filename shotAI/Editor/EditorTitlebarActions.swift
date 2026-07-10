import SwiftUI

/// The editor's window-level actions (Cancel / Save), hosted in the window's
/// TITLE BAR as a trailing NSTitlebarAccessoryViewController (see ContentView).
/// This is the native macOS way to put controls up top: the traffic-light
/// buttons stay visible and managed by AppKit, there's no blank title-bar band,
/// and these buttons are properly hit-tested (unlike SwiftUI content drawn under
/// the title bar's drag region). Observes the shared EditorModel for its saving
/// state.
struct EditorActionsBar: View {
    let model: EditorModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Cancel") { onCancel() }
                .disabled(model.saving) // don't cancel out from under an in-flight save

            Button(action: onSave) {
                if model.saving { ProgressView().controlSize(.small) } else { Text("Save") }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            // Block save mid-scan — it would bake without pending OCR redactions.
            .disabled(model.saving || model.scanning)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
