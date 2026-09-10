import Foundation

/// A brand's colour tokens, as raw values — the single definition both the app
/// UI and every export read.
///
/// **Why this lives in ShotModel.** The app builds SwiftUI `Color`s from these
/// and ExportKit builds hex strings; before this type they were two hand-copied
/// sets that drifted, in one document, invisibly. ExportKit deliberately has no
/// dependency on the app target — an export must render the same whatever
/// appearance the app is in — so a shared *model* package is the only place a
/// single definition can sit. `ReportPresentation` and `DocScale` already
/// establish that presentation constants belong here.
///
/// No SwiftUI, no AppKit: raw `UInt32` in `0xRRGGBB`, and each consumer builds
/// its own representation. That is what keeps ShotModel UI-free.
/// A brand's corner radii, by ROLE rather than by number.
///
/// The LFI guide calls for "restrained corner rounding" and specifies 2px; the
/// study settled on **8** for cards, because at a 22px badge 2px reads as
/// printed collateral while 10px reads as a consumer app. See
/// `design/lfi-theme-study.html`.
///
/// The default brand's values are exactly what shipped before this type existed,
/// so nothing moves for anyone who does not switch brand.
///
/// Only `card` was decided explicitly. `panel`, `figure` and `control` are
/// derived from it on one principle: **siblings match, and a nested element
/// takes a smaller radius than its container.** That is why the screenshot sits
/// below the card it lives inside, on both brands.
public struct BrandRadii: Sendable, Equatable {
    /// Large surfaces: Home's project cards, the report's AI panel.
    public let panel: Double
    /// Document cards: the report's step card and overview. Siblings, one value.
    public let card: Double
    /// Nested media: the screenshot inside a step card, and drop targets.
    public let figure: Double
    /// Small controls: inline editors, the zoom pill.
    public let control: Double
    /// Chips and badges — the tab, mode and sort chips, the status pill, the
    /// step number, the search field.
    ///
    /// `nil` means fully rounded: a capsule, and a circle where the element is
    /// square. That is the default brand's look and it is not expressible as a
    /// number, because a capsule's radius depends on the element's height.
    /// LFI gives it a real value, which is what the study drew.
    public let chip: Double?

    public init(panel: Double, card: Double, figure: Double, control: Double,
                chip: Double?) {
        self.panel = panel
        self.card = card
        self.figure = figure
        self.control = control
        self.chip = chip
    }
}

public struct BrandPalette: Sendable, Equatable {
    public let radii: BrandRadii
    /// The brand's typeface family, or nil for the platform's system face.
    ///
    /// A family NAME, not a file: the app resolves it to a bundled face, and the
    /// exports name it first in their CSS stack. Exports deliberately do not
    /// embed it — as base64 it is ~1.37MB against a measured 0.8-1.5MB
    /// Freshservice paste budget, so embedding would consume the whole budget
    /// and the images would silently drop.
    public let fontFamily: String?

    /// A token's light and dark values. Appearance is resolved by the consumer —
    /// the app through `NSColor`'s dynamic provider, exports by taking `.light`
    /// unconditionally, because a dark-background document is unreadable printed.
    public struct Pair: Sendable, Equatable {
        public let light: UInt32
        public let dark: UInt32
        public init(_ light: UInt32, _ dark: UInt32) {
            self.light = light
            self.dark = dark
        }
    }

    /// One colour at two alphas — shadows, which are the only alpha-carrying
    /// tokens.
    public struct Alpha: Sendable, Equatable {
        public let rgb: UInt32
        public let light: Double
        public let dark: Double
        public init(_ rgb: UInt32, light: Double, dark: Double) {
            self.rgb = rgb
            self.light = light
            self.dark = dark
        }
    }

    public let accent: Pair
    public let accentPress: Pair
    public let accentTint: Pair
    public let accentInk: Pair
    public let onAccent: Pair
    public let ink: Pair
    public let ink2: Pair
    public let ink3: Pair
    public let hair: Pair
    public let hair2: Pair
    public let controlBd: Pair
    public let surface: Pair
    public let surface2: Pair
    public let ground: Pair
    public let field: Pair
    public let cardShadow: Alpha
    public let cardShadowHover: Alpha
    public let ok: Pair
    public let okTint: Pair
    public let okInk: Pair
    public let draft: Pair
    public let draftTint: Pair
    public let draftInk: Pair
    public let danger: Pair
    public let dangerTint: Pair
    public let dangerInk: Pair
    public let noteBg: Pair
    public let noteBd: Pair
    public let noteFg: Pair
    public let cautBg: Pair
    public let cautBd: Pair
    public let cautFg: Pair
    public let warnBg: Pair
    public let warnBd: Pair
    public let warnFg: Pair

    public init(
        radii: BrandRadii,
        fontFamily: String?,
        accent: Pair,
        accentPress: Pair,
        accentTint: Pair,
        accentInk: Pair,
        onAccent: Pair,
        ink: Pair,
        ink2: Pair,
        ink3: Pair,
        hair: Pair,
        hair2: Pair,
        controlBd: Pair,
        surface: Pair,
        surface2: Pair,
        ground: Pair,
        field: Pair,
        cardShadow: Alpha,
        cardShadowHover: Alpha,
        ok: Pair,
        okTint: Pair,
        okInk: Pair,
        draft: Pair,
        draftTint: Pair,
        draftInk: Pair,
        danger: Pair,
        dangerTint: Pair,
        dangerInk: Pair,
        noteBg: Pair,
        noteBd: Pair,
        noteFg: Pair,
        cautBg: Pair,
        cautBd: Pair,
        cautFg: Pair,
        warnBg: Pair,
        warnBd: Pair,
        warnFg: Pair
    ) {
        self.radii = radii
        self.fontFamily = fontFamily
        self.accent = accent
        self.accentPress = accentPress
        self.accentTint = accentTint
        self.accentInk = accentInk
        self.onAccent = onAccent
        self.ink = ink
        self.ink2 = ink2
        self.ink3 = ink3
        self.hair = hair
        self.hair2 = hair2
        self.controlBd = controlBd
        self.surface = surface
        self.surface2 = surface2
        self.ground = ground
        self.field = field
        self.cardShadow = cardShadow
        self.cardShadowHover = cardShadowHover
        self.ok = ok
        self.okTint = okTint
        self.okInk = okInk
        self.draft = draft
        self.draftTint = draftTint
        self.draftInk = draftInk
        self.danger = danger
        self.dangerTint = dangerTint
        self.dangerInk = dangerInk
        self.noteBg = noteBg
        self.noteBd = noteBd
        self.noteFg = noteFg
        self.cautBg = cautBg
        self.cautBd = cautBd
        self.cautFg = cautFg
        self.warnBg = warnBg
        self.warnBd = warnBd
        self.warnFg = warnFg
    }

    /// `#rrggbb`. The form CSS needs, and the only form the PDF renderer's hex
    /// parser accepts — it scans with `scanHexInt64`, so a 3-digit `#fff` would
    /// read as `0x000fff`, a saturated blue.
    public static func hex(_ v: UInt32) -> String { String(format: "#%06x", v) }
}

public extension BrandPalette {
    /// shotAI's own identity — violet. Ported from the Windows app's CSS custom properties; these are the values every existing user sees.
    static let shotAI = BrandPalette(
        radii: BrandRadii(panel: 12, card: 10, figure: 8, control: 6, chip: nil),
        fontFamily: nil,
        accent: Pair(0x6344F1, 0x9A8BF7),
        accentPress: Pair(0x5233D4, 0xB0A4FA),
        accentTint: Pair(0xEFEAFE, 0x241F3A),
        accentInk: Pair(0x4A34C9, 0xC8BDFB),
        onAccent: Pair(0xFFFFFF, 0x171528),
        ink: Pair(0x191826, 0xECE9F7),
        ink2: Pair(0x5A5772, 0xA8A4C0),
        ink3: Pair(0x6F6C88, 0x8E8AA8),
        hair: Pair(0xE7E4F2, 0x302C42),
        hair2: Pair(0xEFEDF7, 0x282539),
        controlBd: Pair(0xCBC7DB, 0x3C3852),
        surface: Pair(0xFFFFFF, 0x1B1926),
        surface2: Pair(0xFAF9FF, 0x211F2E),
        ground: Pair(0xF5F4FB, 0x121019),
        field: Pair(0xFFFFFF, 0x2E2B40),
        cardShadow: Alpha(0x241B4D, light: 0.10, dark: 0.55),
        cardShadowHover: Alpha(0x241B4D, light: 0.18, dark: 0.70),
        ok: Pair(0x0E9F6E, 0x34D399),
        okTint: Pair(0xE7F7EF, 0x12271E),
        okInk: Pair(0x07724F, 0x6EE7B7),
        draft: Pair(0xC77D16, 0xE0A355),
        draftTint: Pair(0xFBF1E0, 0x2A2113),
        draftInk: Pair(0x8A5610, 0xF0C98A),
        danger: Pair(0xDC2626, 0xF87171),
        dangerTint: Pair(0xFEF2F2, 0x2A1414),
        dangerInk: Pair(0xB91C1C, 0xFCA5A5),
        noteBg: Pair(0xECFDF5, 0x10281F),
        noteBd: Pair(0x6EE7B7, 0x2F6F52),
        noteFg: Pair(0x065F46, 0x8EE7BF),
        cautBg: Pair(0xFFFBEB, 0x2A2113),
        cautBd: Pair(0xFCD34D, 0x7A5C1E),
        cautFg: Pair(0x92400E, 0xF0C98A),
        warnBg: Pair(0xFEF2F2, 0x2A1414),
        warnBd: Pair(0xFCA5A5, 0x7A3A3A),
        warnFg: Pair(0x991B1B, 0xF6B0B0)
    )

    /// LaCrosse Footwear corporate — charcoal and warm neutrals carrying the surface, rust as a focused pop. See design/lfi-theme-study.html.
    static let lfi = BrandPalette(
        radii: BrandRadii(panel: 8, card: 8, figure: 6, control: 5, chip: 8),
        fontFamily: "Archivo",
        accent: Pair(0xB46B3E, 0xD58B5C),
        accentPress: Pair(0x9A5A33, 0xE3A579),
        accentTint: Pair(0xF6EDE5, 0x3A2E25),
        accentInk: Pair(0x8F5430, 0xE3A579),
        onAccent: Pair(0xFFFFFF, 0x211F1C),
        ink: Pair(0x47443E, 0xF8F4EC),
        ink2: Pair(0x6F695F, 0xCFC7B8),
        ink3: Pair(0x756C5C, 0xB5AA99),
        hair: Pair(0xD8D2C6, 0x4A463F),
        hair2: Pair(0xE7E2D7, 0x3F3C36),
        controlBd: Pair(0xC9C1B3, 0x686258),
        surface: Pair(0xFFFFFF, 0x3A3833),
        surface2: Pair(0xFAF8F3, 0x43403A),
        ground: Pair(0xF5F2EB, 0x2F2D29),
        field: Pair(0xFFFFFF, 0x4A4740),
        cardShadow: Alpha(0x47443E, light: 0.10, dark: 0.55),
        cardShadowHover: Alpha(0x47443E, light: 0.18, dark: 0.70),
        ok: Pair(0x3E7D5A, 0x6FB089),
        okTint: Pair(0xE9F1EB, 0x23302A),
        okInk: Pair(0x2B5B40, 0x9BCEB1),
        draft: Pair(0xC79A72, 0xD5AE89),
        draftTint: Pair(0xF7EFE6, 0x332A21),
        draftInk: Pair(0x8A5F35, 0xE0C09E),
        danger: Pair(0x9D3F32, 0xC96253),
        dangerTint: Pair(0xF7EAE7, 0x33211E),
        dangerInk: Pair(0x7F3227, 0xE0897B),
        noteBg: Pair(0xE9F1EB, 0x23302A),
        noteBd: Pair(0x3E7D5A, 0x6FB089),
        noteFg: Pair(0x2B5B40, 0x9BCEB1),
        cautBg: Pair(0xF7EFE6, 0x332A21),
        cautBd: Pair(0xC79A72, 0xD5AE89),
        cautFg: Pair(0x8A5F35, 0xE0C09E),
        warnBg: Pair(0xF7EAE7, 0x33211E),
        warnBd: Pair(0xC97F72, 0xC96253),
        warnFg: Pair(0x7F3227, 0xE0897B)
    )
}
