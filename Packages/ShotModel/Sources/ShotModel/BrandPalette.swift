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
    /// embed it — as base64 it is ~0.84MB against a measured 0.8-1.5MB
    /// Freshservice paste budget, so embedding would consume the whole budget
    /// and the images would silently drop.
    public let fontFamily: String?
    /// The PostScript name of the bundled face, for building a concrete font.
    ///
    /// Not derivable from `fontFamily`: Archivo's default instance is `wght` 600,
    /// so its PostScript name is "Archivo-SemiBold" while its typographic family
    /// is "Archivo". The renderers anchor on this and set the axes explicitly.
    public let fontPostScriptName: String?
    /// Faces to try after the brand's own, for a document opened somewhere the
    /// brand face is not installed. Chosen to resemble it, not to match the OS.
    public let fontFallbacks: [String]

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
        fontPostScriptName: String?,
        fontFallbacks: [String],
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
        self.fontPostScriptName = fontPostScriptName
        self.fontFallbacks = fontFallbacks
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

// The two brand tables used to sit here, hand-written. They are now GENERATED
// into BrandPalette+Generated.swift from `contract/brand.json`, which is the
// same file Armadillon44/shotAI generates its palette from — so a colour the
// two platforms share cannot be edited on one side only, which is how every
// drift in the 2026-09-14 cross-check happened.
//
// Add or change a value there, then run `swift Scripts/gen-brand.swift`.
// Everything about how these are CONSUMED stays here, by hand.
