import SwiftUI

/// A small shared type scale for the Home surface, so titles and labels sit on
/// one ladder instead of ad-hoc `.system(size:)` values scattered per call site.
/// (Adopted on Home first; other screens can move onto it incrementally.)
enum Typo {
    static let wordmark     = Font.system(size: 17, weight: .bold)
    static let heroTitle    = Font.system(size: 21, weight: .bold)
    static let sectionTitle = Font.system(size: 15, weight: .semibold)
    static let cardTitle    = Font.system(size: 15, weight: .semibold)
    static let body         = Font.system(size: 13)
    static let tagline      = Font.system(size: 12)
    static let eyebrow      = Font.system(size: 11, weight: .bold)   // MODE / SORT labels
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
