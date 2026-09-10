import Foundation
import ShotModel

/// The colour vocabulary every styled export renders from.
///
/// **One source of truth for two renderers.** The HTML exports build CSS strings
/// (`docCSS`, `plainCSS`) and the PDF is drawn natively with CoreText/CoreGraphics
/// (`PdfExport`), so the same step card was expressed twice, in two hand-copied
/// sets of hex literals. They drifted: see `knownDivergences` below. This type is
/// what both now read.
///
/// ExportKit deliberately does NOT read the app target's `Palette`. It is a
/// separate package with no app dependency, and — more importantly — an exported
/// document must render the same regardless of the appearance the app happens to
/// be in. An export is not a screenshot of the UI.
///
/// **One neutral ramp, and it is the app's.** The export stylesheets were once
/// written against Tailwind's greys while the app used its own violet-tinted
/// inks, and the two ended up mixed *within a single document*: body text in
/// `#1f2937` with a section heading one line below in `#191826`, a screenshot
/// border in `#e5e7eb` inside a card border in `#e7e4f2`. Invisible — each pair
/// sits within a few percent — which is exactly why it survived. The Tailwind
/// values are gone; every token below is annotated with the `Palette` token it
/// mirrors.
///
/// Three tokens disappeared in that collapse rather than being kept as
/// duplicates: `sectionHeading`, `sectionBody` and `sectionRule` became
/// identical to `text`, `bodyText` and `hair`. A section heading *is* primary
/// text; keeping a second name for the same role is how they drift apart again.
///
/// **The mirroring is structural, not a convention.** Both this type and the
/// app's `PaletteTokens` are built from one `ShotModel.BrandPalette`, so a
/// changed token reaches both by construction. ExportKit still has no
/// dependency on the app target — the shared definition sits in the model
/// package they both already use.
///
/// **Values are 6-digit hex strings, always.** `Ink.color(_:)` scans with
/// `scanHexInt64`, so a 3-digit `#fff` would parse as `0x000fff` — blue, silently.
/// The CSS previously spelled two colours `#fff`; they are `#ffffff` here, which
/// is the only byte-level change this type introduced and is visually identical.
///
/// Adding a second brand (see `design/LFI-THEME-PLAN.md`) means adding another
/// instance and threading it through as a parameter. That is deliberately NOT
/// done here — this pass only removes the duplication, at the existing values.
public struct ExportTheme: Sendable, Equatable {
    /// A callout's three colours, which always move together.
    public struct Callout: Sendable, Equatable {
        public let bg: String
        public let border: String
        public let text: String
        public init(bg: String, border: String, text: String) {
            self.bg = bg
            self.border = border
            self.text = text
        }
    }

    // Document text.
    /// Primary text; also the PDF's title colour.
    public let text: String
    /// Long-form body copy — the overview body and blockquotes.
    public let bodyText: String
    /// Secondary text: the date line, the OVERVIEW eyebrow, per-step notes.
    public let meta: String
    /// Page background.
    public let pageBg: String

    // Brand.
    public let accent: String
    /// Text drawn on top of `accent` — the step number inside its badge.
    public let onAccent: String

    // Surfaces and rules.
    public let cardBg: String
    public let cardBorder: String
    /// Neutral hairline: image borders and the `<hr>` in the Word-facing export.
    public let hair: String
    public let introBg: String
    /// The blockquote rule in the Word-facing export.
    public let quoteRule: String

    // Callouts.
    public let note: Callout
    public let caution: Callout
    public let warning: Callout

    public init(
        text: String, bodyText: String, meta: String, pageBg: String,
        accent: String, onAccent: String,
        cardBg: String, cardBorder: String, hair: String, introBg: String, quoteRule: String,
        note: Callout, caution: Callout, warning: Callout
    ) {
        self.text = text
        self.bodyText = bodyText
        self.meta = meta
        self.pageBg = pageBg
        self.accent = accent
        self.onAccent = onAccent
        self.cardBg = cardBg
        self.cardBorder = cardBorder
        self.hair = hair
        self.introBg = introBg
        self.quoteRule = quoteRule
        self.note = note
        self.caution = caution
        self.warning = warning
    }
}

public extension ExportTheme {
    /// Derive a document theme from a brand.
    ///
    /// Takes the brand's LIGHT values unconditionally. The export axis is *which
    /// brand*, never *which appearance*: a dark-background SOP is unreadable
    /// printed and ruinous on toner, so a user in dark mode still exports a
    /// light document.
    ///
    /// One ramp, and it is the app's. `hair` and `cardBorder` both resolve to
    /// the same token today — different elements, same hairline — and are kept
    /// separate so a brand could distinguish them without a schema change.
    init(_ b: BrandPalette) {
        self.init(
            text: BrandPalette.hex(b.ink.light),
            bodyText: BrandPalette.hex(b.ink2.light),
            meta: BrandPalette.hex(b.ink3.light),
            pageBg: BrandPalette.hex(b.surface.light),
            accent: BrandPalette.hex(b.accent.light),
            onAccent: BrandPalette.hex(b.onAccent.light),
            cardBg: BrandPalette.hex(b.surface2.light),
            cardBorder: BrandPalette.hex(b.hair.light),
            hair: BrandPalette.hex(b.hair.light),
            introBg: BrandPalette.hex(b.accentTint.light),
            quoteRule: BrandPalette.hex(b.controlBd.light),
            note: Callout(bg: BrandPalette.hex(b.noteBg.light),
                          border: BrandPalette.hex(b.noteBd.light),
                          text: BrandPalette.hex(b.noteFg.light)),
            caution: Callout(bg: BrandPalette.hex(b.cautBg.light),
                             border: BrandPalette.hex(b.cautBd.light),
                             text: BrandPalette.hex(b.cautFg.light)),
            warning: Callout(bg: BrandPalette.hex(b.warnBg.light),
                             border: BrandPalette.hex(b.warnBd.light),
                             text: BrandPalette.hex(b.warnFg.light))
        )
    }

    static let shotAI = ExportTheme(.shotAI)
    static let lfi = ExportTheme(.lfi)

    static func of(_ brand: BrandPref) -> ExportTheme { ExportTheme(BrandPalette.of(brand)) }

    /// Where the PDF renderer still disagrees with the HTML.
    ///
    /// Empty. The three section-divider differences were corrected once the
    /// shared vocabulary made them visible, and the badge's colour space with
    /// them. Kept as a named, asserted list rather than deleted: it is the
    /// anchor for `testPdfMatchesTheCSS`, and a future divergence should have to
    /// be written down here to pass.
    static let knownDivergences: [String] = []
}
