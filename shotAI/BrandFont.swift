import AppKit
import CoreText
import ShotModel
import SwiftUI

/// A weight, in both vocabularies.
///
/// SwiftUI's `Font.Weight` is a struct of static properties, so it cannot be
/// switched on, and a variable font needs a number on the `wght` axis. This
/// carries both so a call site names a weight once.
enum BrandWeight: Sendable {
    case regular, medium, semibold, bold

    var system: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    var wght: Double {
        switch self {
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        }
    }
}

/// The bundled brand face.
///
/// **Registered with the process, not declared in Info.plist.** Reaching
/// `ATSApplicationFontsPath` would mean adding an `INFOPLIST_FILE` to a target
/// that uses `GENERATE_INFOPLIST_FILE`, and this app is unusually sensitive to
/// bundle identity: TCC keys Screen Recording, Accessibility and Input
/// Monitoring to the code-signing designated requirement. Registration at
/// runtime touches none of that.
///
/// Registration is a `static let`, so it happens once, lazily, on the first font
/// request — no ordering problem with the first window drawing.
enum BrandFont {
    /// The name a brand asks for.
    static let family = "Archivo"

    /// The PostScript name the descriptor is anchored to.
    ///
    /// NOT "Archivo". The variable font's default instance is `wght` 600, so its
    /// *legacy* family name is "Archivo SemiBold" and its PostScript name is
    /// "Archivo-SemiBold" — a plain `Font.custom("Archivo", size:)` either fails
    /// or silently returns semibold. The `wght` axis set below overrides that
    /// default, so nothing here is actually semibold unless asked for.
    private static let anchor = "Archivo-SemiBold"

    /// Axis tags as their four-character codes.
    private static let wghtAxis = NSNumber(value: 0x7767_6874)  // 'wght'
    private static let wdthAxis = NSNumber(value: 0x7764_7468)  // 'wdth'

    /// Normal and condensed widths. 62 is Archivo's narrowest and its named
    /// Condensed instance; the study drew 66, but the difference is a few percent
    /// of advance width at UI sizes and 62 needs no interpolation.
    static let normalWidth: Double = 100
    static let condensedWidth: Double = 62

    private static let registered: Bool = {
        guard let url = Bundle.main.url(forResource: "Archivo", withExtension: "ttf")
            ?? Bundle.main.url(forResource: "Archivo", withExtension: "ttf", subdirectory: "Fonts")
        else {
            Log.ui.error("Archivo.ttf is not in the bundle; the brand face falls back to the system font")
            return false
        }
        var err: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
        if !ok {
            Log.ui.error("Archivo registration failed: \(String(describing: err?.takeRetainedValue()), privacy: .public)")
        }
        return ok
    }()

    /// An instance at a given size, weight and width, or nil if the face is
    /// unavailable — in which case the caller falls back to the system font
    /// rather than rendering nothing.
    static func font(size: CGFloat, weight: BrandWeight, width: Double) -> Font? {
        guard registered else { return nil }
        let desc = NSFontDescriptor(fontAttributes: [
            .name: anchor,
            NSFontDescriptor.AttributeName(kCTFontVariationAttribute as String): [
                wghtAxis: NSNumber(value: weight.wght),
                wdthAxis: NSNumber(value: width),
            ],
        ])
        guard let nsFont = NSFont(descriptor: desc, size: size) else { return nil }
        return Font(nsFont)
    }
}

extension PaletteTokens {
    /// The brand's text face at a size and weight.
    ///
    /// The default brand returns `.system(size:weight:)` unchanged, so
    /// converting a call site is a no-op for anyone who has not switched brand.
    func font(_ size: CGFloat, _ weight: BrandWeight = .regular) -> Font {
        guard fontFamily != nil,
              let f = BrandFont.font(size: size, weight: weight, width: BrandFont.normalWidth)
        else { return .system(size: size, weight: weight.system) }
        return f
    }

    /// The condensed treatment — uppercase section titles, eyebrows, chip
    /// labels. The LFI guide leans on it: "uppercase, condensed treatments suit
    /// short section titles and statements."
    ///
    /// The default brand has no condensed face, so this is the same as `font`
    /// there. Condensed is part of the LFI identity, not a general affordance.
    func condensed(_ size: CGFloat, _ weight: BrandWeight = .regular) -> Font {
        guard fontFamily != nil,
              let f = BrandFont.font(size: size, weight: weight, width: BrandFont.condensedWidth)
        else { return .system(size: size, weight: weight.system) }
        return f
    }
}
