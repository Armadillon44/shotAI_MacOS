import AppKit

/// AppKit (bottom-left origin, y-up) ↔ CG (top-left origin, y-down) bridging.
/// The flip is GLOBAL, about the primary display only — flipping per-screen is
/// the classic multi-monitor bug. The capture pipeline lives entirely in CG
/// top-left points; AppKit coordinates appear only at window-placement
/// boundaries (pill docking, overlay windows), which is where these run.
enum CoordinateSpaces {
    /// Height of the primary screen (the one containing AppKit's origin).
    @MainActor
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// AppKit rect (bottom-left) → CG rect (top-left), global.
    @MainActor
    static func cgRect(fromAppKit rect: NSRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
