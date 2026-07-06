import Foundation

/// What an 'auto'-mode capture should frame for the active window — the macOS
/// re-derivation of the Windows captureModeFor() shell taxonomy ('Windows
/// Explorer'+'Program Manager' = desktop, SHELL_HOST_RE = Start/tray hosts).
public enum AutoMode: Sendable {
    /// Unknown focus or the desktop: full context, never a guessed crop.
    case fullscreen
    /// Shell surfaces (Dock, Spotlight, Control Center…): their windows are
    /// huge/transparent and capture badly — crop a region around the click.
    case region
    /// A normal app window: tight crop to its bounds.
    case window
}

public func captureModeFor(active: WindowSnapshot?) -> AutoMode {
    guard let active else { return .fullscreen }
    // Finder with no real front window = the desktop — a region around the
    // click is more useful for an SOP than the whole screen (the click point
    // is what matters). The grab path also falls back from .window to a region
    // crop when a click lands OUTSIDE the active window (menu bar, open menus,
    // window edges), so out-of-window clicks are framed, not fullscreened.
    if active.bundleID == "com.apple.finder", active.title.trimmingCharacters(in: .whitespaces).isEmpty {
        return .region
    }
    if let bundleID = active.bundleID, CaptureConstants.shellHostBundleIDs.contains(bundleID) {
        return .region
    }
    return .window
}
