import AppKit
import XCTest
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
        XCTAssertEqual(t.text, "#1f2937")
        XCTAssertEqual(t.bodyText, "#374151")
        XCTAssertEqual(t.meta, "#6b7280")
        XCTAssertEqual(t.pageBg, "#ffffff")
        XCTAssertEqual(t.accent, "#6344f1")
        XCTAssertEqual(t.onAccent, "#ffffff")
        XCTAssertEqual(t.cardBg, "#faf9ff")
        XCTAssertEqual(t.cardBorder, "#e7e4f2")
        XCTAssertEqual(t.hair, "#e5e7eb")
        XCTAssertEqual(t.introBg, "#efeafe")
        XCTAssertEqual(t.quoteRule, "#cbd5e1")
        XCTAssertEqual(t.sectionHeading, "#191826")
        XCTAssertEqual(t.sectionBody, "#5a5772")
        XCTAssertEqual(t.sectionRule, "#e7e4f2")
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
        XCTAssertEqual(hex(Ink.title), t.text)
        XCTAssertEqual(hex(Ink.body), t.bodyText)
        XCTAssertEqual(hex(Ink.meta), t.meta)
        XCTAssertEqual(hex(Ink.note), t.meta)
        XCTAssertEqual(hex(Ink.eyebrow), t.meta)
        XCTAssertEqual(hex(Ink.badge), t.accent)
        XCTAssertEqual(hex(Ink.onBadge), t.onAccent)
        XCTAssertEqual(hex(Ink.hair), t.hair)
        XCTAssertEqual(hex(Ink.cardBg), t.cardBg)
        XCTAssertEqual(hex(Ink.cardBorder), t.cardBorder)
        XCTAssertEqual(hex(Ink.introBg), t.introBg)

        for (kind, expected) in [(CalloutKindExport.note, t.note),
                                 (.caution, t.caution),
                                 (.warning, t.warning)] {
            let c = Ink.callout(kind)
            XCTAssertEqual(hex(c.bg), expected.bg, "\(kind) bg")
            XCTAssertEqual(hex(c.border), expected.border, "\(kind) border")
            XCTAssertEqual(hex(c.text), expected.text, "\(kind) text")
        }

        XCTAssertEqual(hex(Ink.sectionHeading), t.sectionHeading)
        XCTAssertEqual(hex(Ink.sectionBody), t.sectionBody)
        XCTAssertEqual(hex(Ink.sectionRule), t.sectionRule)
        XCTAssertTrue(ExportTheme.knownDivergences.isEmpty,
                      "still divergent: \(ExportTheme.knownDivergences)")
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
         ("quoteRule", t.quoteRule), ("sectionHeading", t.sectionHeading),
         ("sectionBody", t.sectionBody), ("sectionRule", t.sectionRule),
         ("note.bg", t.note.bg), ("note.border", t.note.border), ("note.text", t.note.text),
         ("caution.bg", t.caution.bg), ("caution.border", t.caution.border),
         ("caution.text", t.caution.text),
         ("warning.bg", t.warning.bg), ("warning.border", t.warning.border),
         ("warning.text", t.warning.text)]
    }
}
