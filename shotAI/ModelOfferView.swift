import SOPKit
import SwiftUI

/// The failure alert's offer: switch to `to`, because `from` failed in a way
/// another model could avoid.
struct ErrorModelSwitch: Equatable {
    let to: ModelChoice
    let from: SopModelId
    /// Whether accepting it also puts away the panel's offer of `from`. Not after
    /// a 400: that may be the project's doing, and the model may be fine.
    var putsAwayItsOffer = true
}

/// The model offer, in Settings ▸ AI and the AI SOP panel: a newer Sonnet, or a
/// warning that the model in use is retiring or no longer available, with the
/// one-click switch. Nothing changes until the button is clicked.
struct ModelOfferNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    let offer: ModelOffer
    /// The AI SOP panel's version: report typography, and "Not now".
    var inPanel = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: offer.reason == .newer ? "sparkles" : "exclamationmark.triangle")
                .foregroundStyle(offer.reason == .newer ? palette.accent : Color.orange)
            Text(message)
                .font(inPanel ? palette.font(11) : .caption)
                .foregroundStyle(inPanel ? palette.ink2 : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let c = offer.candidate {
                // Verbatim: the name comes from the network, and a localized key
                // would read formatting into it.
                Button { model.chooseModel(ModelChoice(c)) } label: { Text(verbatim: "Switch to \(c.displayName)") }
                    .controlSize(.small)
                    .help(Text(verbatim: "Use \(c.displayName) for the next generation. Nothing already generated changes, and you can switch back in Settings ▸ AI."))
            }
            if inPanel, offer.dismissKey != nil {
                Button("Not now") { model.dismissModelOffer() }
                    .controlSize(.small)
                    .help("Stop showing this here. Settings ▸ AI still shows it.")
            }
        }
    }

    private var message: String {
        let current = model.modelName(offer.current)
        switch offer.reason {
        case .newer:
            return "\(offer.candidate?.displayName ?? "A newer model") is available, newer than \(current)."
        case .retiring(let date):
            let when = date.map { " on \($0.formatted(date: .long, time: .omitted))" } ?? ""
            return "Anthropic is retiring \(current)\(when)."
                + (offer.candidate == nil ? " No replacement is listed yet; ask IT if you need help." : "")
        case .unavailable:
            return "\(current) isn't available to this account, so generating will fail."
                + (offer.candidate == nil ? " No replacement is listed; ask IT for help." : "")
        }
    }
}
