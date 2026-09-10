import SwiftUI

/// A small shared type scale, so titles and labels sit on one ladder instead of
/// ad-hoc `.system(size:)` values per call site.
///
/// These are on `PaletteTokens` rather than a `Typo` enum of static `Font`s
/// because the face is part of the brand, and a static cannot read the
/// environment — the same reason the colours moved. The default brand resolves
/// every one of them to `.system`, unchanged.
extension PaletteTokens {
    var wordmark: Font { font(17, .bold) }
    var heroTitle: Font { font(21, .bold) }
    var sectionTitle: Font { font(15, .semibold) }
    var cardTitle: Font { font(15, .semibold) }
    var bodyText: Font { font(13) }
    var tagline: Font { font(12) }
    /// MODE / SORT labels. Condensed: the guide asks for it on short uppercase
    /// labels, and these are the app's only ones.
    var eyebrow: Font { condensed(11, .bold) }
}

/// Soft card elevation — restores the Windows `--shadow-sm` the flat port
/// dropped. `hover` lifts it a step for rollover feedback.
///
/// A `ViewModifier` rather than a plain `View` extension because the shadow is a
/// brand token: a free function on `View` has no environment to read, so it
/// could never follow a brand change.
private struct CardElevation: ViewModifier {
    @Environment(\.palette) private var palette
    let hover: Bool

    func body(content: Content) -> some View {
        content.shadow(
            color: hover ? palette.cardShadowHover : palette.cardShadow,
            radius: hover ? 13 : 8,
            x: 0,
            y: hover ? 5 : 3
        )
    }
}

extension View {
    /// Apply after the card's `clipShape` so the shadow follows the rounded
    /// silhouette.
    func cardElevation(hover: Bool = false) -> some View {
        modifier(CardElevation(hover: hover))
    }
}
