import SwiftUI
import ShotModel

/// The report toolbar's Frame menu: the shape every step's image is shown in,
/// in the report and in every export (Armadillon44/shotAI#160). Sits beside the
/// document-size control, the other per-project presentation setting.
///
/// "Original" removes `shotFrame` from project.json; a preset writes it. A
/// frame that parses but is not a preset (another build or a hand edit) gets
/// its own ticked row, so the menu never claims a state the project is not in;
/// a value this build cannot parse ticks nothing, like View ▸ Brand.
struct FrameMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker("Frame", selection: selection) {
                Text("Original").tag(AppModel.FrameMenuSelection.original)
                ForEach(ShotFrame.presets, id: \.self) { frame in
                    Text(Self.label(frame)).tag(AppModel.FrameMenuSelection.frame(frame))
                }
                if case .frame(let frame) = model.frameMenuSelection, !ShotFrame.presets.contains(frame) {
                    Text("\(frame.rawValue) (custom)").tag(AppModel.FrameMenuSelection.frame(frame))
                }
            }
            .pickerStyle(.inline)
        } label: {
            // Title and icon both, as Export does: this toolbar renders an
            // image-bearing label icon-only by default.
            Label(title, systemImage: "aspectratio")
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.visible)
        .help("Screenshot frame: the shape every step's image is shown in, here and in every export. Zoom and drag place each image in its frame. The screenshots are not changed.")
    }

    private var title: String {
        if case .frame(let frame) = model.frameMenuSelection { return "Frame \(frame.rawValue)" }
        return "Frame"
    }

    static func label(_ frame: ShotFrame) -> String {
        switch frame.rawValue {
        case "1:1": "1:1 Square"
        case "16:9": "16:9 Widescreen"
        default: frame.rawValue
        }
    }

    /// Writes go through `AppModel`, which refuses a no-op and reloads.
    private var selection: Binding<AppModel.FrameMenuSelection> {
        Binding(get: { model.frameMenuSelection },
                set: { sel in Task { await model.applyFrameMenuSelection(sel) } })
    }
}
