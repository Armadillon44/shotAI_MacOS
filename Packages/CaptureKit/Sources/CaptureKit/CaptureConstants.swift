import Foundation

/// Constants ported 1:1 from CaptureController.ts. The Windows values are in
/// "logical px × monitor scaleFactor"; on macOS the global unit is the POINT,
/// which IS the logical unit — so these apply directly, with no scale-factor
/// multiplication (multiplying again would double-apply Retina scale).
public enum CaptureConstants {
    /// Default downscale factor applied to every stored PNG (T2). ≥ 1 disables.
    public static let captureScale: CGFloat = 0.85
    /// Allowed screenshot-quality range (mirrors the Windows CAPTURE_SCALE_MIN/MAX).
    /// Lower = smaller files + cheaper AI, softer text.
    public static let captureScaleMin: CGFloat = 0.5
    public static let captureScaleMax: CGFloat = 1.0
    /// Readability floor (MIN_CAPTURE_LONG_EDGE): never downscale a capture's
    /// longer edge below this many pixels, so even the lowest quality setting
    /// keeps text legible for Claude + exports. Ported from CaptureController.ts.
    public static let minCaptureLongEdge: CGFloat = 1100

    /// Clamp an untrusted screenshot-quality value into the allowed range;
    /// non-finite input falls back to the default.
    public static func clampCaptureScale(_ v: CGFloat) -> CGFloat {
        guard v.isFinite else { return captureScale }
        return min(captureScaleMax, max(captureScaleMin, v))
    }

    /// ms after a right-click during which the next left click is treated as a
    /// context-menu selection.
    public static let menuFollowUpWindow: TimeInterval = 30.0
    /// Shorter re-arm window after each selection (submenu/flyout chains).
    public static let submenuFollowUpWindow: TimeInterval = 6.0
    /// Proximity gate (points, per-axis/Chebyshev): a click farther than this
    /// from the last menu point disarms.
    public static let menuProximityX: CGFloat = 640
    public static let menuProximityY: CGFloat = 680
    /// Monitor poll interval while a menu is armed.
    public static let menuPollInterval: TimeInterval = 0.4
    /// Max polled frames per arm (~13 s); after the cap the last frame is
    /// reused (an open menu is static).
    public static let maxPollFrames = 32
    /// Max selections one right-click can chain through re-arming.
    public static let maxMenuChain = 4

    /// Double left-mousedown collapse window / distance (points, per-axis).
    public static let doubleClickWindow: TimeInterval = 0.4
    public static let doubleClickDistance: CGFloat = 6

    /// Symmetric half-size (points) of the box unioned around a menu-selection
    /// click (symmetric because menus flip up/left near screen edges).
    public static let menuClickBoxHalf: CGFloat = 620

    /// Centered crop box (points) for 'auto' shell-region captures
    /// (Dock/Spotlight/Control Center analogs of taskbar/Start/tray).
    public static let regionBoxWidth: CGFloat = 820
    public static let regionBoxHeight: CGFloat = 640

    /// Height (points) of the top menu-bar band. A click within this band of a
    /// display's top edge is on the system menu bar — which sits ABOVE every app
    /// window, so auto mode must NOT crop to the active window (that omits the
    /// bar) but capture a region around the click. Generous enough to cover
    /// notched displays (~37 pt) plus the standard 24 pt.
    public static let menuBarBand: CGFloat = 40

    /// Hard cap waiting for an element-at-point query; late results discarded.
    public static let elementQueryTimeout: TimeInterval = 0.6

    /// macOS analog of SHELL_HOST_RE: shell surfaces whose windows are huge or
    /// transparent and capture badly — classified 'region' in auto mode.
    public static let shellHostBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.Spotlight",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.systemuiserver",
        "com.apple.loginwindow",
    ]

    /// Shot filename allocation, same as Windows: step-NNNN.png.
    public static func shotFilename(order: Int) -> String {
        "step-" + String(format: "%04d", order) + ".png"
    }

    /// Upper bound on a parsed orphan step number. A real project never has
    /// millions of shots; the cap keeps a hostile filename (e.g.
    /// step-9223372036854775807.png in a shared/downloaded project) from
    /// seeding the counter at Int.max and trapping on the next `+= 1`.
    public static let maxOrphanStepNumber = 1_000_000

    /// Orphan-seed parse of an existing shots/ filename (case-insensitive
    /// step-NNNN.png, like the Windows /^step-(\d+)\.png$/i). Clamped so an
    /// oversized number can't overflow the capture counter.
    public static func shotFilenameNumber(_ name: String) -> Int? {
        let lower = name.lowercased()
        guard lower.hasPrefix("step-"), lower.hasSuffix(".png") else { return nil }
        let digits = lower.dropFirst("step-".count).dropLast(".png".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        guard let n = Int(digits) else { return nil }
        return min(n, maxOrphanStepNumber)
    }
}
