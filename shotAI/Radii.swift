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
}
