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

    // Section dividers.
    public let sectionHeading: String
    public let sectionBody: String
    public let sectionRule: String

    // Callouts.
    public let note: Callout
    public let caution: Callout
    public let warning: Callout

    public init(
        text: String, bodyText: String, meta: String, pageBg: String,
        accent: String, onAccent: String,
        cardBg: String, cardBorder: String, hair: String, introBg: String, quoteRule: String,
        sectionHeading: String, sectionBody: String, sectionRule: String,
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
        self.sectionHeading = sectionHeading
        self.sectionBody = sectionBody
        self.sectionRule = sectionRule
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
        text: "#1f2937",
        bodyText: "#374151",
        meta: "#6b7280",
        pageBg: "#ffffff",
        accent: "#6344f1",
        onAccent: "#ffffff",
        cardBg: "#faf9ff",
        cardBorder: "#e7e4f2",
        hair: "#e5e7eb",
        introBg: "#efeafe",
        quoteRule: "#cbd5e1",
        sectionHeading: "#191826",
        sectionBody: "#5a5772",
        sectionRule: "#e7e4f2",
        note: Callout(bg: "#ecfdf5", border: "#6ee7b7", text: "#065f46"),
        caution: Callout(bg: "#fffbeb", border: "#fcd34d", text: "#92400e"),
        warning: Callout(bg: "#fef2f2", border: "#fca5a5", text: "#991b1b")
    )

    /// Where the PDF renderer knowingly disagrees with the HTML today.
    ///
    /// All three are section-divider colours: `PdfExport.drawSection` reuses
    /// `title`/`meta`/`hair` where the CSS has dedicated `section*` values. The
    /// PDF is therefore slightly cooler and lower-contrast on section headings
    /// than the HTML for the same project.
    ///
    /// **Preserved on purpose.** Tokenizing was supposed to change nothing an
    /// existing user can see, and fixing these changes the PDF. They are listed
    /// here — rather than left as an undocumented difference — so
    /// `exportPalettesAgreeExceptKnownDivergences` fails the moment a FOURTH one
    /// appears, which is the regression this whole pass exists to make visible.
    static let knownDivergences: [String] = [
        "sectionHeading — CSS .section__h #191826, PDF Ink.title #1f2937",
        "sectionBody — CSS .section__b #5a5772, PDF Ink.meta #6b7280",
        "sectionRule — CSS .section__inner border-top #e7e4f2, PDF Ink.hair #e5e7eb",
        "badge text — CSS .step__num color #ffffff, PDF a bare NSColor.white "
            + "(generic gray, not sRGB). Identical colour; switching it shrinks "
            + "the PDF ~10% by dropping a DeviceGray colour space.",
    ]
}
