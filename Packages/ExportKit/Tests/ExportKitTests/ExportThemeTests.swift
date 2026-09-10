import AppKit
import XCTest
import ShotModel
@testable import ExportKit

/// Pins the export colour vocabulary.
///
/// These values ship in every HTML and PDF a user has ever exported, so changing
/// one is never incidental. The suite exists so that a change is a failing test
/// rather than a surprise in someone's document.
final class ExportThemeTests: XCTestCase {
    private let t = ExportTheme.shotAI

    /// Every value, spelled out. A diff here is the review.
    func testShotAIValuesArePinned() {
        XCTAssertEqual(t.text, "#191826")        // Palette.ink
        XCTAssertEqual(t.bodyText, "#5a5772")    // Palette.ink2
        XCTAssertEqual(t.meta, "#6f6c88")        // Palette.ink3
        XCTAssertEqual(t.pageBg, "#ffffff")
        XCTAssertEqual(t.accent, "#6344f1")
        XCTAssertEqual(t.onAccent, "#ffffff")
        XCTAssertEqual(t.cardBg, "#faf9ff")
        XCTAssertEqual(t.cardBorder, "#e7e4f2")
        XCTAssertEqual(t.hair, "#e7e4f2")        // Palette.hair
        XCTAssertEqual(t.introBg, "#efeafe")
        XCTAssertEqual(t.quoteRule, "#cbc7db")   // Palette.controlBd
        XCTAssertEqual(t.note, .init(bg: "#ecfdf5", border: "#6ee7b7", text: "#065f46"))
        XCTAssertEqual(t.caution, .init(bg: "#fffbeb", border: "#fcd34d", text: "#92400e"))
        XCTAssertEqual(t.warning, .init(bg: "#fef2f2", border: "#fca5a5", text: "#991b1b"))
    }

    /// Six digits, always.
    ///
    /// `Ink.color(_:)` scans with `scanHexInt64`, so a 3-digit `#fff` parses as
    /// `0x000fff` — a saturated blue, silently, in the PDF only. The CSS used to
    /// spell two colours `#fff`; they cannot be shared with the PDF in that form.
    func testEveryValueIsSixDigitHex() {
        for (name, value) in Self.allValues(t) {
            XCTAssertEqual(value.count, 7, "\(name) = \(value)")
            XCTAssertTrue(value.hasPrefix("#"), "\(name) = \(value)")
            XCTAssertNotNil(UInt32(value.dropFirst(), radix: 16), "\(name) = \(value) is not hex")
        }
    }

    /// The CSS emits the theme's values rather than keeping its own copies.
    func testCSSCarriesTheThemeValues() {
        let css = docCSS() + plainCSS()
        for (name, value) in Self.allValues(t) {
            XCTAssertTrue(css.contains(value), "\(name) (\(value)) is not in the exported CSS")
        }
    }

    /// No renderer may reintroduce a literal.
    ///
    /// Both stylesheets are built entirely from the theme, so any hex in the
    /// output must be a theme value. This is what catches a hand-added colour,
    /// which is exactly how the PDF and the CSS drifted apart in the first place.
    func testCSSContainsNoUntokenizedColour() {
        let css = docCSS() + plainCSS()
        let known = Set(Self.allValues(t).map(\.1))
        var found: Set<String> = []
        var i = css.startIndex
        while let r = css.range(of: "#", range: i..<css.endIndex) {
            let hex = css[r.upperBound...].prefix { $0.isHexDigit }
            if hex.count >= 3 { found.insert("#" + hex.lowercased()) }
            i = r.upperBound
        }
        XCTAssertTrue(found.subtracting(known).isEmpty,
                      "untokenized colour(s) in the CSS: \(found.subtracting(known).sorted())")
    }

    /// The PDF resolves to exactly the colours the CSS emits.
    ///
    /// Nothing is exempt any more. `knownDivergences` is empty and asserted so:
    /// a future difference has to be written down there to pass, which makes
    /// "the two renderers disagree" a deliberate act rather than a slow drift.
    func testPdfMatchesTheCSS() {
        let ink = Ink(t)
        XCTAssertEqual(hex(ink.title), t.text)
        XCTAssertEqual(hex(ink.body), t.bodyText)
        XCTAssertEqual(hex(ink.meta), t.meta)
        XCTAssertEqual(hex(ink.note), t.meta)
        XCTAssertEqual(hex(ink.eyebrow), t.meta)
        XCTAssertEqual(hex(ink.badge), t.accent)
        XCTAssertEqual(hex(ink.onBadge), t.onAccent)
        XCTAssertEqual(hex(ink.hair), t.hair)
        XCTAssertEqual(hex(ink.cardBg), t.cardBg)
        XCTAssertEqual(hex(ink.cardBorder), t.cardBorder)
        XCTAssertEqual(hex(ink.introBg), t.introBg)

        for (kind, expected) in [(CalloutKindExport.note, t.note),
                                 (.caution, t.caution),
                                 (.warning, t.warning)] {
            let c = ink.callout(kind)
            XCTAssertEqual(hex(c.bg), expected.bg, "\(kind) bg")
            XCTAssertEqual(hex(c.border), expected.border, "\(kind) border")
            XCTAssertEqual(hex(c.text), expected.text, "\(kind) text")
        }

        // Section styling is the general ramp now, in both renderers.
        XCTAssertEqual(hex(ink.sectionHeading), t.text)
        XCTAssertEqual(hex(ink.sectionBody), t.bodyText)
        XCTAssertEqual(hex(ink.sectionRule), t.hair)
        XCTAssertTrue(ExportTheme.knownDivergences.isEmpty,
                      "still divergent: \(ExportTheme.knownDivergences)")
    }

    /// The document radius SCALE, not a single number.
    ///
    /// Card and overview are sibling document cards, so they share 10. The
    /// screenshot is nested *inside* a card, so it takes a smaller 8 —
    /// concentric radii read correctly and equal ones do not.
    ///
    /// Stating this as "10 everywhere" is what caused the Windows port to
    /// flatten all three and open a cross-platform gap (Armadillon44/shotAI#77).
    /// Asserted in both directions so neither drift can return.
    func testDocumentRadiusScale() {
        let css = docCSS()
        let t = ExportTheme.shotAI
        XCTAssertTrue(css.contains("border-radius:10px;background:\(t.cardBg)}"),
                      "step card should be 10")
        XCTAssertTrue(css.contains("border-radius:10px;background:\(t.introBg)}"),
                      "overview should be 10, matching the step card")
        XCTAssertTrue(css.contains("border:1px solid \(t.hair);border-radius:8px}"),
                      "the screenshot is nested in a card and should stay 8")
        XCTAssertFalse(css.contains("border-radius:12px"), "12 was the pre-0b card radius")
    }

    /// One neutral ramp, not two.
    ///
    /// The Tailwind greys the export stylesheets used to carry are gone. This
    /// asserts none of them can come back — it is the specific regression the
    /// collapse exists to prevent, and it would have caught the original drift.
    func testNoTailwindGreysRemain() {
        let css = docCSS() + plainCSS()
        for grey in ["#1f2937", "#374151", "#6b7280", "#e5e7eb", "#cbd5e1"] {
            XCTAssertFalse(css.contains(grey),
                           "\(grey) is a Tailwind grey; the export ramp is the app's inks")
        }
    }

    /// The document renders in the selected brand, in both renderers.
    ///
    /// This is what the app-chrome brand axis was missing: before it, an LFI
    /// user got a corporate app and a violet document.
    func testExportsFollowTheBrand() {
        let lfi = ExportTheme.of(.lfi)
        XCTAssertEqual(lfi.accent, "#b46b3e", "rust, not violet")
        XCTAssertEqual(lfi.text, "#47443e", "charcoal, not the shotAI ink")
        XCTAssertTrue(docCSS(theme: lfi).contains("#b46b3e"))
        XCTAssertFalse(docCSS(theme: lfi).contains("#6344f1"), "no violet in an LFI document")
        XCTAssertEqual(hex(Ink(lfi).badge), lfi.accent, "the PDF follows too")
        // Always the LIGHT values: a dark-background SOP is unreadable printed.
        XCTAssertEqual(lfi.pageBg, "#ffffff")
    }

    /// Geometry follows the brand, and keeps the concentric relationship.
    ///
    /// The screenshot is nested inside a card, so it must stay SMALLER than the
    /// card on every brand — not merely different. Asserting the relationship
    /// rather than two numbers is what stops a future brand flattening them,
    /// which is exactly what the Windows port did when "10px everywhere" was
    /// read literally (Armadillon44/shotAI#77).
    func testRadiiFollowTheBrandAndStayConcentric() {
        for theme in [ExportTheme.shotAI, .lfi] {
            XCTAssertGreaterThan(theme.cardRadius, theme.figureRadius,
                                 "a nested figure must be rounder-inward than its card")
        }
        XCTAssertEqual(ExportTheme.shotAI.cardRadius, 10)
        XCTAssertEqual(ExportTheme.shotAI.figureRadius, 8)
        XCTAssertEqual(ExportTheme.lfi.cardRadius, 8)
        XCTAssertEqual(ExportTheme.lfi.figureRadius, 6)

        XCTAssertTrue(docCSS(theme: .lfi).contains("border-radius:8px"))
        XCTAssertFalse(docCSS(theme: .lfi).contains("border-radius:10px"),
                       "an LFI document should carry no default-brand radius")
    }

    /// The export's glyph table is a second copy of the app's. They must agree,
    /// or the same callout carries one mark on screen and another in the file.
    ///
    /// This is the same duplication that let the colour ramps drift, caught here
    /// by assertion rather than by someone noticing months later.
    func testExportGlyphsMatchTheApp() {
        XCTAssertEqual(calloutGlyphExport(.note), ReportPresentation.calloutGlyph(.note))
        XCTAssertEqual(calloutGlyphExport(.caution), ReportPresentation.calloutGlyph(.caution))
        XCTAssertEqual(calloutGlyphExport(.warning), ReportPresentation.calloutGlyph(.warning))
        XCTAssertEqual(calloutGlyphExport(.section), ReportPresentation.calloutGlyph(.section))
    }

    // MARK: helpers

    private func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02x%02x%02x",
                      Int((s.redComponent * 255).rounded()),
                      Int((s.greenComponent * 255).rounded()),
                      Int((s.blueComponent * 255).rounded()))
    }

    private static func allValues(_ t: ExportTheme) -> [(String, String)] {
        [("text", t.text), ("bodyText", t.bodyText), ("meta", t.meta), ("pageBg", t.pageBg),
         ("accent", t.accent), ("onAccent", t.onAccent), ("cardBg", t.cardBg),
         ("cardBorder", t.cardBorder), ("hair", t.hair), ("introBg", t.introBg),
         ("quoteRule", t.quoteRule),
         ("note.bg", t.note.bg), ("note.border", t.note.border), ("note.text", t.note.text),
         ("caution.bg", t.caution.bg), ("caution.border", t.caution.border),
         ("caution.text", t.caution.text),
         ("warning.bg", t.warning.bg), ("warning.border", t.warning.border),
         ("warning.text", t.warning.text)]
    }
}
