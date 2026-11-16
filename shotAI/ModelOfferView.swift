import SOPKit
import SwiftUI

/// A model the user can switch to: one built into shotAI, or one from Anthropic's
/// model list, carrying what a request for it needs.
enum ModelChoice: Equatable {
    case builtIn(SopModelId)
    case discovered(SopModelProfile)

    /// A model from the list that this build has since learned in code is taken as
    /// built in, so its known price and request shape win.
    init(_ profile: SopModelProfile) {
        let id = SopModelId(rawValue: profile.id)
        self = id.isBuiltIn ? .builtIn(id) : .discovered(profile)
    }

    var id: SopModelId {
        switch self {
        case .builtIn(let id): id
        case .discovered(let p): SopModelId(rawValue: p.id)
        }
    }
}

/// The failure alert's offer: switch to `to`, because `from` failed in a way
/// another model could avoid.
struct ErrorModelSwitch: Equatable {
    let to: ModelChoice
    let from: SopModelId
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
