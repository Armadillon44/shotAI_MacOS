import Foundation
import Testing
@testable import ShotModel

/// Pins the brand tables.
///
/// This is now the ONLY definition of either brand's colours — the app builds
/// SwiftUI `Color`s from it and ExportKit builds hex strings — so a change here
/// reaches every surface at once. That is the point, and it is also why the
/// values are spelled out: a diff in this file is the review.
@Suite struct BrandPaletteContract {
    /// The accessibility floor these were chosen against.
    ///
    /// `ink3` carries date groups, MODE/SORT labels, counts and per-step notes,
    /// and in exports it carries document secondary text. It failed AA on both
    /// brands until it was darkened; the LFI dark value in particular cleared on
    /// `ground` while failing on `surface`, which is where the labels actually
    /// sit. So every background is checked, not one per mode.
    @Test(arguments: [BrandPalette.shotAI, BrandPalette.lfi])
    func tertiaryInkMeetsAAOnEveryBackground(b: BrandPalette) {
        for (bg, mode) in [(b.ground.light, "light ground"), (b.surface.light, "light surface"),
                           (b.surface2.light, "light surface2"), (b.ground.dark, "dark ground"),
                           (b.surface.dark, "dark surface"), (b.surface2.dark, "dark surface2")] {
            let fg = mode.hasPrefix("dark") ? b.ink3.dark : b.ink3.light
            #expect(contrast(fg, bg) >= 4.5, "ink3 on \(mode): \(contrast(fg, bg))")
        }
    }

    @Test func shotAIValuesArePinned() {
        let b = BrandPalette.shotAI
        #expect(b.accent == .init(0x6344F1, 0x9A8BF7))
        #expect(b.ink == .init(0x191826, 0xECE9F7))
        #expect(b.ink2 == .init(0x5A5772, 0xA8A4C0))
        #expect(b.ink3 == .init(0x6F6C88, 0x8E8AA8))
        #expect(b.hair == .init(0xE7E4F2, 0x302C42))
        #expect(b.controlBd == .init(0xCBC7DB, 0x3C3852))
        #expect(b.surface == .init(0xFFFFFF, 0x1B1926))
        #expect(b.surface2 == .init(0xFAF9FF, 0x211F2E))
        #expect(b.accentTint == .init(0xEFEAFE, 0x241F3A))
    }

    @Test func lfiValuesArePinned() {
        let b = BrandPalette.lfi
        #expect(b.accent == .init(0xB46B3E, 0xD58B5C))
        #expect(b.ink == .init(0x47443E, 0xF8F4EC))
        #expect(b.ink2 == .init(0x6F695F, 0xCFC7B8))
        #expect(b.ink3 == .init(0x756C5C, 0xB5AA99))
        #expect(b.hair == .init(0xD8D2C6, 0x4A463F))
        #expect(b.controlBd == .init(0xC9C1B3, 0x686258))
        #expect(b.surface == .init(0xFFFFFF, 0x3A3833))
        #expect(b.surface2 == .init(0xFAF8F3, 0x43403A))
        #expect(b.accentTint == .init(0xF6EDE5, 0x3A2E25))
    }

    /// Exports take the light values, so a document is never dark-on-dark
    /// whatever the app is doing. Both brands must therefore have a light
    /// surface that text can sit on.
    @Test(arguments: [BrandPalette.shotAI, BrandPalette.lfi])
    func exportsHaveAReadableLightSurface(b: BrandPalette) {
        #expect(contrast(b.ink.light, b.surface.light) >= 7)
        #expect(contrast(b.ink2.light, b.surface.light) >= 4.5)
    }

    @Test func hexIsAlwaysSixDigits() {
        #expect(BrandPalette.hex(0xFFFFFF) == "#ffffff")
        // Not "#fff": the PDF renderer scans with scanHexInt64, which would read
        // three digits as 0x000fff — a saturated blue.
        #expect(BrandPalette.hex(0x000FFF) == "#000fff")
        #expect(BrandPalette.hex(0x6344F1).count == 7)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ v: UInt32) -> Double {
            func c(_ x: UInt32) -> Double {
                let s = Double(x) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * c((v >> 16) & 0xFF) + 0.7152 * c((v >> 8) & 0xFF) + 0.0722 * c(v & 0xFF)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// The radius scale.
@Suite struct BrandRadiiContract {
    /// The default brand must be exactly what shipped before radii were
    /// tokenized — introducing a token set is not licence to restyle the app.
    @Test func defaultBrandIsUnchanged() {
        let r = BrandPalette.shotAI.radii
        #expect(r.panel == 12)
        #expect(r.card == 10)
        #expect(r.figure == 8)
        #expect(r.control == 6)
    }

    /// LFI's card radius is the one value the study settled explicitly.
    @Test func lfiCardIsEight() {
        #expect(BrandPalette.lfi.radii.card == 8)
    }

    /// Siblings match, and a nested element takes a smaller radius than its
    /// container. Asserted as a RELATIONSHIP, on every brand, because the
    /// Windows port flattened all three when "10px everywhere" was read as one
    /// number (Armadillon44/shotAI#77).
    @Test(arguments: [BrandPalette.shotAI, BrandPalette.lfi])
    func nestedElementsAreRounderInward(b: BrandPalette) {
        #expect(b.radii.figure < b.radii.card, "the screenshot sits inside a card")
        #expect(b.radii.control < b.radii.card, "a control is smaller than a card")
        #expect(b.radii.card <= b.radii.panel, "a card sits inside a panel")
    }
}

/// Chips and badges.
@Suite struct BrandChipShape {
    /// The default brand's chips are capsules, and that is not a number — a
    /// capsule's corner depends on the element's height, and a square element
    /// wants a circle. `nil` says so; a sentinel like 999 would not.
    @Test func defaultBrandChipsAreFullyRounded() {
        #expect(BrandPalette.shotAI.radii.chip == nil)
    }

    /// LFI gives them a real radius — the value the study drew.
    @Test func lfiChipsMatchItsCards() {
        #expect(BrandPalette.lfi.radii.chip == 8)
        #expect(BrandPalette.lfi.radii.chip == BrandPalette.lfi.radii.card,
                "a chip and a card read as the same family in the study")
    }
}

/// The callout glyphs are a cross-platform contract: the same project must show
/// the same mark on both apps and in every export.
@Suite struct CalloutGlyphContract {
    @Test func warningIsATypographicBarNotAnEmojiOrb() {
        let g = ReportPresentation.calloutGlyph(.warning)
        #expect(g == "━", "U+2501 BOX DRAWINGS HEAVY HORIZONTAL")
        // ⛔ U+26D4 renders as a red emoji orb in most fonts, which is what this
        // replaced. Nothing here should carry emoji presentation.
        #expect(g != "⛔")
        for s in g.unicodeScalars {
            #expect(!s.properties.isEmojiPresentation, "\(s) defaults to emoji presentation")
        }
    }

    @Test func everyKindHasAGlyphExceptSection() {
        #expect(!ReportPresentation.calloutGlyph(.note).isEmpty)
        #expect(!ReportPresentation.calloutGlyph(.caution).isEmpty)
        #expect(!ReportPresentation.calloutGlyph(.warning).isEmpty)
        #expect(ReportPresentation.calloutGlyph(.section).isEmpty, "a divider carries no glyph")
    }
}
