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

extension View {
    /// Soft card elevation — restores the Windows `--shadow-sm` the flat port
    /// dropped. `hover` lifts it a step for rollover feedback. Apply after the
    /// card's `clipShape` so the shadow follows the rounded silhouette.
    func cardElevation(hover: Bool = false) -> some View {
        shadow(
            color: hover ? Palette.cardShadowHover : Palette.cardShadow,
            radius: hover ? 13 : 8,
            x: 0,
            y: hover ? 5 : 3
        )
    }
}
