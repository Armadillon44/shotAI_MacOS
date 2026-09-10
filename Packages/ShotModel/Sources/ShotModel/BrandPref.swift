import Foundation

/// Which brand palette the UI wears.
///
/// Orthogonal to the light/dark appearance: a brand has both a light and a dark
/// set, so the two are separate settings rather than one combined picker that
/// would misrepresent them as mutually exclusive.
///
/// Lives in ShotModel rather than the app target because ExportKit resolves a
/// brand too, and has no app dependency — and because the per-project `theme`
/// key planned for `project.json` puts it in the cross-platform schema.
/// Raw values are the persisted form; do not rename them.
public enum BrandPref: String, Codable, CaseIterable, Sendable {
    case shotAI, lfi
}

public extension BrandPalette {
    static func of(_ brand: BrandPref) -> BrandPalette {
        switch brand {
        case .shotAI: .shotAI
        case .lfi: .lfi
        }
    }
}
