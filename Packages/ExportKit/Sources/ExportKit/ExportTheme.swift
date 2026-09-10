import Foundation

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
/// ⚠️ **The mirroring is a convention, not a mechanism.** ExportKit cannot see
/// `Palette` — it is a separate package with no app dependency, deliberately, so
/// an export renders the same whatever appearance the app is in. Nothing fails
/// if someone changes `Palette.ink` and not `text` here. Making it structural
/// means lifting the shared light values into ShotModel, which both sides
/// already depend on; that is worth doing if this ever drifts again.
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
    /// shotAI's default brand — the violet identity, at the exact values both
    /// renderers already shipped. Changing anything here changes every existing
    /// user's next export, so `ExportThemeTests` pins all of them.
    static let shotAI = ExportTheme(
        text: "#191826",        // Palette.ink
        bodyText: "#5a5772",    // Palette.ink2
        meta: "#6f6c88",        // Palette.ink3
        pageBg: "#ffffff",
        accent: "#6344f1",      // Palette.accent
        onAccent: "#ffffff",
        cardBg: "#faf9ff",      // Palette.surface2
        cardBorder: "#e7e4f2",  // Palette.hair
        hair: "#e7e4f2",        // Palette.hair
        introBg: "#efeafe",     // Palette.accentTint
        quoteRule: "#cbc7db",   // Palette.controlBd
        note: Callout(bg: "#ecfdf5", border: "#6ee7b7", text: "#065f46"),
        caution: Callout(bg: "#fffbeb", border: "#fcd34d", text: "#92400e"),
        warning: Callout(bg: "#fef2f2", border: "#fca5a5", text: "#991b1b")
    )

    /// Where the PDF renderer still disagrees with the HTML.
    ///
    /// Empty. The three section-divider differences were corrected once the
    /// shared vocabulary made them visible, and the badge's colour space with
    /// them. Kept as a named, asserted list rather than deleted: it is the
    /// anchor for `testPdfMatchesTheCSS`, and a future divergence should have to
    /// be written down here to pass.
    static let knownDivergences: [String] = []
}
