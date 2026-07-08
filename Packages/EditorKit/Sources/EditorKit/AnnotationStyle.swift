import CoreGraphics
import Foundation
import ShotModel

/// Editor tool styles, size defaults, and annotation factories — ported from
/// `shotAI-original/src/renderer/editor/annotations.ts`. Geometry is in IMAGE
/// (screenshot) pixel coordinates, matching the schema.
public enum AnnotationStyle {
    /// High-contrast accent for outlines/arrows/stamps (rose-600).
    public static let accent = "#e11d48"
    /// Right-click marker color (blue-600).
    public static let rightClickColor = "#2563eb"
    public static let defaultStrokeWidth: CGFloat = 4
    public static let defaultBlockSize: CGFloat = 14
    /// Minimum redaction downsample factor (image px). Below this, averaged text
    /// can stay legible, so the bake clamps up to it regardless of the stored
    /// value (a hand-edited manifest can't blur text back into legibility).
    public static let minRedactBlock: CGFloat = 8

    /// Radius (image px) for the click-register marker, scaled to the image.
    public static func clickMarkerRadius(width: CGFloat, height: CGFloat) -> CGFloat {
        max(14, min(60, (min(width, height) * 0.02).rounded()))
    }

    /// Default line width, scaled to the image so it reads boldly on large shots.
    public static func defaultStrokeWidth(width: CGFloat, height: CGFloat) -> CGFloat {
        max(4, min(50, (min(width, height) * 0.008).rounded()))
    }

    /// Default numbered-stamp radius, scaled to the image.
    public static func defaultStampRadius(width: CGFloat, height: CGFloat) -> CGFloat {
        max(16, min(72, (min(width, height) * 0.022).rounded()))
    }

    /// Default text size, scaled to the image.
    public static func defaultFontSize(width: CGFloat, height: CGFloat) -> CGFloat {
        max(16, min(96, (min(width, height) * 0.022).rounded()))
    }

    /// The click-ring color for a step — a user-set markerColor wins, else
    /// right-clicks are blue and everything else rose. Single source shared by
    /// the report overlay, the merge marker, and the baked-marker color.
    public static func markerColor(for step: ProjectStep) -> String {
        if let c = step.markerColor { return c }
        return step.click?.button == .right ? rightClickColor : accent
    }
}

/// Parse a CSS hex color (`#rgb`, `#rrggbb`, `#rrggbbaa`) into a CGColor in
/// device RGB. Returns nil for anything else (the flatten path substitutes a
/// safe default rather than crashing). The Windows app stores annotation colors
/// as hex strings, so this covers every persisted value.
public func cgColor(fromHex hex: String) -> CGColor? {
    var s = hex.trimmingCharacters(in: .whitespaces)
    guard s.hasPrefix("#") else { return nil }
    s.removeFirst()
    func byte(_ sub: Substring) -> CGFloat? {
        UInt8(sub, radix: 16).map { CGFloat($0) / 255 }
    }
    let chars = Array(s)
    let r, g, b: CGFloat
    var a: CGFloat = 1
    switch chars.count {
    case 3: // #rgb → #rrggbb
        guard let rr = byte(Substring(String([chars[0], chars[0]]))),
              let gg = byte(Substring(String([chars[1], chars[1]]))),
              let bb = byte(Substring(String([chars[2], chars[2]]))) else { return nil }
        (r, g, b) = (rr, gg, bb)
    case 6, 8:
        guard let rr = byte(s.prefix(2)),
              let gg = byte(s.dropFirst(2).prefix(2)),
              let bb = byte(s.dropFirst(4).prefix(2)) else { return nil }
        (r, g, b) = (rr, gg, bb)
        if chars.count == 8, let aa = byte(s.dropFirst(6).prefix(2)) { a = aa }
    default:
        return nil
    }
    return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Generate a fresh annotation id (matches the Windows `crypto.randomUUID()` /
/// fallback shape — any unique string works).
public func newAnnotationID() -> String {
    UUID().uuidString.lowercased()
}
