import ShotModel
import SwiftUI

/// `BrandRadii` as `CGFloat`, so a call site stays `cornerRadius: palette.card`
/// rather than wrapping a conversion around every one of them.
///
/// Roles, not numbers: a radius changes because a thing is a card or a nested
/// figure, never because a literal was tuned by eye. Values live in
/// `ShotModel.BrandRadii`, shared with the exports.
extension PaletteTokens {
    var panel: CGFloat { CGFloat(radii.panel) }
    var card: CGFloat { CGFloat(radii.card) }
    var figure: CGFloat { CGFloat(radii.figure) }
    var control: CGFloat { CGFloat(radii.control) }

    /// The shape for chips and badges — tabs, mode and sort chips, the status
    /// pill, the step number, the search field.
    ///
    /// A `Shape` rather than a radius, because the default brand's answer is
    /// "capsule", which is not a number: a capsule's corner depends on the
    /// element's height, and a square element wants a circle. LFI has a real
    /// radius, so it gets a rounded rectangle.
    var chipShape: AnyShape {
        guard let r = radii.chip else { return AnyShape(Capsule()) }
        return AnyShape(RoundedRectangle(cornerRadius: CGFloat(r)))
    }

    /// The square variant — the step-number badge and the callout glyph, which
    /// are circles on the default brand rather than capsules.
    var badgeShape: AnyShape {
        guard let r = radii.chip else { return AnyShape(Circle()) }
        return AnyShape(RoundedRectangle(cornerRadius: CGFloat(r)))
    }
}
