import AppKit
import SwiftUI

/// shotAI's brand design tokens, ported verbatim from the Windows app's CSS
/// custom properties (`src/renderer/project/project.css` `:root` +
/// `[data-theme='dark']`). Each token is a **dynamic** color that resolves per
/// light/dark appearance — the native equivalent of the web app's single
/// `[data-theme]` token swap, so the whole UI reskins from here.
///
/// Read these instead of hardcoding hex, and prefer `Palette.accent` over the
/// system accent so the app reads as the violet-branded shotAI, not stock
/// SwiftUI. Values that are intentionally theme-agnostic in the Windows app
/// (the always-dark recording pill `#1f2330`, the click-register marker reds,
/// the area-select `#6366f1`) stay hardcoded at their call sites, matching the
/// source.
enum Palette {
    // Brand accent (violet) + its supporting shades.
    static let accent      = dyn(0x6344F1, 0x9A8BF7)
    static let accentPress = dyn(0x5233D4, 0xB0A4FA)
    static let accentTint  = dyn(0xEFEAFE, 0x241F3A)
    static let accentInk   = dyn(0x4A34C9, 0xC8BDFB)
    static let onAccent    = dyn(0xFFFFFF, 0x171528)

    // Ink ramp (text).
    static let ink  = dyn(0x191826, 0xECE9F7)
    static let ink2 = dyn(0x5A5772, 0xA8A4C0)
    static let ink3 = dyn(0x918EA6, 0x726F8B)

    // Hairlines / control borders.
    static let hair      = dyn(0xE7E4F2, 0x302C42)
    static let hair2     = dyn(0xEFEDF7, 0x282539)
    static let controlBd = dyn(0xCBC7DB, 0x3C3852)

    // Surfaces.
    static let surface  = dyn(0xFFFFFF, 0x1B1926)
    static let surface2 = dyn(0xFAF9FF, 0x211F2E)
    static let ground   = dyn(0xF5F4FB, 0x121019)

    // Status — semantic, kept separate from the accent.
    static let ok        = dyn(0x0E9F6E, 0x34D399)
    static let okTint    = dyn(0xE7F7EF, 0x12271E)
    static let okInk     = dyn(0x07724F, 0x6EE7B7)
    static let draft     = dyn(0xC77D16, 0xE0A355)
    static let draftTint = dyn(0xFBF1E0, 0x2A2113)
    static let draftInk  = dyn(0x8A5610, 0xF0C98A)
    static let danger     = dyn(0xDC2626, 0xF87171)
    static let dangerTint = dyn(0xFEF2F2, 0x2A1414)
    static let dangerInk  = dyn(0xB91C1C, 0xFCA5A5)

    // Callout trios (note / caution / warning).
    static let noteBg = dyn(0xECFDF5, 0x10281F)
    static let noteBd = dyn(0x6EE7B7, 0x2F6F52)
    static let noteFg = dyn(0x065F46, 0x8EE7BF)
    static let cautBg = dyn(0xFFFBEB, 0x2A2113)
    static let cautBd = dyn(0xFCD34D, 0x7A5C1E)
    static let cautFg = dyn(0x92400E, 0xF0C98A)
    static let warnBg = dyn(0xFEF2F2, 0x2A1414)
    static let warnBd = dyn(0xFCA5A5, 0x7A3A3A)
    static let warnFg = dyn(0x991B1B, 0xF6B0B0)

    /// A color that resolves to `light` under Aqua and `dark` under Dark Aqua,
    /// re-evaluated whenever the effective appearance changes.
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    /// Build from a packed `0xRRGGBB` value in the sRGB space (opaque).
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
