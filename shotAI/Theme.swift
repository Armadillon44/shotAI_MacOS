import AppKit
import ShotModel
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
    /// Corner radii, by role. Part of the brand: the LFI guide treats corner
    /// rounding as identity, not decoration.
    let radii: BrandRadii
    /// The brand's typeface family, or nil for the system face.
    let fontFamily: String?
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
    /// Build the SwiftUI representation of a brand.
    ///
    /// The values live in `ShotModel.BrandPalette` so the exports read the same
    /// definition; this only turns them into `Color`s. Adding a token means
    /// adding it there, and both consumers get it.
    init(_ b: BrandPalette) {
        self.init(
            radii: b.radii,
            fontFamily: b.fontFamily,
            accent: dyn(b.accent), accentPress: dyn(b.accentPress),
            accentTint: dyn(b.accentTint), accentInk: dyn(b.accentInk),
            onAccent: dyn(b.onAccent),
            ink: dyn(b.ink), ink2: dyn(b.ink2), ink3: dyn(b.ink3),
            hair: dyn(b.hair), hair2: dyn(b.hair2), controlBd: dyn(b.controlBd),
            surface: dyn(b.surface), surface2: dyn(b.surface2),
            ground: dyn(b.ground), field: dyn(b.field),
            cardShadow: shadow(b.cardShadow), cardShadowHover: shadow(b.cardShadowHover),
            ok: dyn(b.ok), okTint: dyn(b.okTint), okInk: dyn(b.okInk),
            draft: dyn(b.draft), draftTint: dyn(b.draftTint), draftInk: dyn(b.draftInk),
            danger: dyn(b.danger), dangerTint: dyn(b.dangerTint), dangerInk: dyn(b.dangerInk),
            noteBg: dyn(b.noteBg), noteBd: dyn(b.noteBd), noteFg: dyn(b.noteFg),
            cautBg: dyn(b.cautBg), cautBd: dyn(b.cautBd), cautFg: dyn(b.cautFg),
            warnBg: dyn(b.warnBg), warnBd: dyn(b.warnBd), warnFg: dyn(b.warnFg)
        )
    }

    static let shotAI = PaletteTokens(.shotAI)
    static let lfi = PaletteTokens(.lfi)

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
private func dyn(_ p: BrandPalette.Pair) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(rgb: isDark ? p.dark : p.light)
    })
}

/// An appearance-aware translucent colour (for shadows) — the same `rgb` with a
/// per-mode alpha.
private func shadow(_ a: BrandPalette.Alpha) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(rgb: a.rgb).withAlphaComponent(isDark ? a.dark : a.light)
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
