import AppKit
import SwiftUI

/// shotAI's design tokens, as a **brand** you can swap at runtime.
///
/// There are two independent axes and it matters that they stay independent:
///
/// - **Appearance** — light vs dark. Handled inside `dyn(_:_:)` by `NSColor`'s
///   dynamic provider, which AppKit re-invokes when the effective appearance
///   changes. This has always worked and is untouched.
/// - **Brand** — which palette. A brand is *not* an appearance, so it cannot be
///   a third branch of `dyn`: every brand has both a light and a dark set, so
///   the real shape is brand × appearance = 4 palettes.
///
/// **Why this is a struct in the environment and not an enum of statics.**
/// Reading a `static let` from a view body registers no SwiftUI dependency, so
/// changing the brand would repaint nothing — and would fail *partially*, since
/// any view re-rendering for an unrelated reason (hover, scroll, a model change)
/// would pick up the new colour while its neighbours kept the old one. That
/// reads as a flaky bug rather than a missing wire. Declaring
/// `@Environment(\.palette)` in a body is precisely what registers the
/// dependency. `.id(brand)` on the root would also force it, but destroys every
/// `@State` below — scroll position, editor state, inline-edit focus.
///
/// Values that are intentionally brand-agnostic (the always-dark recording pill
/// `#1f2330`, the click-register marker reds, the area-select `#6366f1`) stay
/// hardcoded at their call sites, matching the Windows app. See
/// `design/LFI-THEME-PLAN.md` §2.
struct PaletteTokens: Sendable {
    // Brand accent + supporting shades.
    let accent, accentPress, accentTint, accentInk, onAccent: Color
    // Ink ramp (text).
    let ink, ink2, ink3: Color
    // Hairlines / control borders.
    let hair, hair2, controlBd: Color
    // Surfaces. `field` must stay LIGHTER than the surfaces in dark mode, or a
    // text field stops reading as an input on an elevated card.
    let surface, surface2, ground, field: Color
    // Elevation. Alpha-carrying, so built by `shadow` rather than `dyn`.
    let cardShadow, cardShadowHover: Color
    // Status — semantic, kept separate from the accent.
    let ok, okTint, okInk: Color
    let draft, draftTint, draftInk: Color
    let danger, dangerTint, dangerInk: Color
    // Callout trios (note / caution / warning).
    let noteBg, noteBd, noteFg: Color
    let cautBg, cautBd, cautFg: Color
    let warnBg, warnBd, warnFg: Color
}

extension PaletteTokens {
    /// shotAI's own identity — violet, ported verbatim from the Windows app's
    /// CSS custom properties (`project.css` `:root` + `[data-theme='dark']`).
    /// These are the values every existing user sees; changing one is never
    /// incidental.
    static let shotAI = PaletteTokens(
        accent: dyn(0x6344F1, 0x9A8BF7),
        accentPress: dyn(0x5233D4, 0xB0A4FA),
        accentTint: dyn(0xEFEAFE, 0x241F3A),
        accentInk: dyn(0x4A34C9, 0xC8BDFB),
        onAccent: dyn(0xFFFFFF, 0x171528),
        // The dark `ink3` is lifted slightly from the Windows value so secondary
        // labels don't vanish against the near-black `ground`.
        ink: dyn(0x191826, 0xECE9F7),
        ink2: dyn(0x5A5772, 0xA8A4C0),
        ink3: dyn(0x918EA6, 0x8E8AA8),
        hair: dyn(0xE7E4F2, 0x302C42),
        hair2: dyn(0xEFEDF7, 0x282539),
        controlBd: dyn(0xCBC7DB, 0x3C3852),
        surface: dyn(0xFFFFFF, 0x1B1926),
        surface2: dyn(0xFAF9FF, 0x211F2E),
        ground: dyn(0xF5F4FB, 0x121019),
        field: dyn(0xFFFFFF, 0x2E2B40),
        cardShadow: shadow(0x241B4D, light: 0.10, dark: 0.55),
        cardShadowHover: shadow(0x241B4D, light: 0.18, dark: 0.70),
        ok: dyn(0x0E9F6E, 0x34D399),
        okTint: dyn(0xE7F7EF, 0x12271E),
        okInk: dyn(0x07724F, 0x6EE7B7),
        draft: dyn(0xC77D16, 0xE0A355),
        draftTint: dyn(0xFBF1E0, 0x2A2113),
        draftInk: dyn(0x8A5610, 0xF0C98A),
        danger: dyn(0xDC2626, 0xF87171),
        dangerTint: dyn(0xFEF2F2, 0x2A1414),
        dangerInk: dyn(0xB91C1C, 0xFCA5A5),
        noteBg: dyn(0xECFDF5, 0x10281F),
        noteBd: dyn(0x6EE7B7, 0x2F6F52),
        noteFg: dyn(0x065F46, 0x8EE7BF),
        cautBg: dyn(0xFFFBEB, 0x2A2113),
        cautBd: dyn(0xFCD34D, 0x7A5C1E),
        cautFg: dyn(0x92400E, 0xF0C98A),
        warnBg: dyn(0xFEF2F2, 0x2A1414),
        warnBd: dyn(0xFCA5A5, 0x7A3A3A),
        warnFg: dyn(0x991B1B, 0xF6B0B0)
    )

    /// LaCrosse Footwear corporate — charcoal and warm neutrals carrying the
    /// surface, rust as a focused pop. See `design/lfi-theme-study.html` for the
    /// mock-up these values were settled against.
    ///
    /// The four exact brand colours are Charcoal `0x47443E`, Cream `0xEEE8DB`,
    /// Taupe `0x938978` and Rust `0xB46B3E`; everything else is derived, because
    /// the guide defines a brand rather than an interface. The dark set is
    /// likewise derived — the guide specifies one palette, not two modes.
    ///
    /// Two derivations are worth knowing about:
    ///
    /// **Success is forest, not the guide's chart olive.** LFI defines no green.
    /// The olive (`0x7D846D`) was tried first and read as ambiguous for
    /// "success"; forest also measures better, 6.83:1 on its own tint against
    /// the olive's 5.56:1.
    ///
    /// **`ink3` is brand taupe, unadjusted, at 3.08:1 on `ground`** — below AA
    /// for normal text. Deliberately left: the *existing* shotAI theme is 2.90:1
    /// at the same token, so this is marginally better than what ships today
    /// rather than a regression this brand introduces. The tertiary ink is too
    /// low contrast on both brands and deserves its own fix, not a silent one
    /// buried in a plumbing change.
    static let lfi = PaletteTokens(
        accent: dyn(0xB46B3E, 0xD58B5C),
        accentPress: dyn(0x9A5A33, 0xE3A579),
        accentTint: dyn(0xF6EDE5, 0x3A2E25),
        accentInk: dyn(0x8F5430, 0xE3A579),
        onAccent: dyn(0xFFFFFF, 0x211F1C),
        ink: dyn(0x47443E, 0xF8F4EC),
        ink2: dyn(0x6F695F, 0xCFC7B8),
        ink3: dyn(0x938978, 0xA79C8B),
        hair: dyn(0xD8D2C6, 0x4A463F),
        hair2: dyn(0xE7E2D7, 0x3F3C36),
        controlBd: dyn(0xC9C1B3, 0x686258),
        surface: dyn(0xFFFFFF, 0x3A3833),
        surface2: dyn(0xFAF8F3, 0x43403A),
        ground: dyn(0xF5F2EB, 0x2F2D29),
        field: dyn(0xFFFFFF, 0x4A4740),
        cardShadow: shadow(0x47443E, light: 0.10, dark: 0.55),
        cardShadowHover: shadow(0x47443E, light: 0.18, dark: 0.70),
        ok: dyn(0x3E7D5A, 0x6FB089),
        okTint: dyn(0xE9F1EB, 0x23302A),
        okInk: dyn(0x2B5B40, 0x9BCEB1),
        draft: dyn(0xC79A72, 0xD5AE89),
        draftTint: dyn(0xF7EFE6, 0x332A21),
        draftInk: dyn(0x8A5F35, 0xE0C09E),
        danger: dyn(0x9D3F32, 0xC96253),
        dangerTint: dyn(0xF7EAE7, 0x33211E),
        dangerInk: dyn(0x7F3227, 0xE0897B),
        noteBg: dyn(0xE9F1EB, 0x23302A),
        noteBd: dyn(0x3E7D5A, 0x6FB089),
        noteFg: dyn(0x2B5B40, 0x9BCEB1),
        cautBg: dyn(0xF7EFE6, 0x332A21),
        cautBd: dyn(0xC79A72, 0xD5AE89),
        cautFg: dyn(0x8A5F35, 0xE0C09E),
        warnBg: dyn(0xF7EAE7, 0x33211E),
        warnBd: dyn(0xC97F72, 0xC96253),
        warnFg: dyn(0x7F3227, 0xE0897B)
    )

    static func of(_ brand: BrandPref) -> PaletteTokens {
        switch brand {
        case .shotAI: .shotAI
        case .lfi: .lfi
        }
    }
}

// MARK: - Environment

private struct PaletteKey: EnvironmentKey {
    /// shotAI's own brand. A view rendered outside the app's scene roots — an
    /// Xcode preview, a detached panel — gets the default identity rather than
    /// nothing.
    static let defaultValue = PaletteTokens.shotAI
}

extension EnvironmentValues {
    /// The active brand's tokens. Read it in a body — `@Environment(\.palette)
    /// private var palette` — and use `palette.accent` rather than any hardcoded
    /// hex, so the whole UI reskins from one place.
    var palette: PaletteTokens {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - Token constructors

/// A colour that resolves to `light` under Aqua and `dark` under Dark Aqua,
/// re-evaluated whenever the effective appearance changes.
private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(rgb: isDark ? dark : light)
    })
}

/// An appearance-aware translucent colour (for shadows) — the same `rgb` with a
/// per-mode alpha.
private func shadow(_ rgb: UInt32, light: Double, dark: Double) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(rgb: rgb).withAlphaComponent(isDark ? dark : light)
    })
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
