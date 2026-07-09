import AppKit
import CaptureKit
import Foundation

/// The app-side OwnWindowChecking: a geometric hit test against every visible
/// own window, in the tap's CG top-left point space. This check is
/// load-bearing for "pill clicks create no steps" — the non-activating pill
/// never reports as the frontmost app, so pid checks alone would miss it.
final class AppOwnWindows: OwnWindowChecking, Sendable {
    func pointHitsOwnWindow(_ point: CGPoint) async -> Bool {
        await MainActor.run {
            for window in NSApp.windows where window.isVisible {
                let frame = CoordinateSpaces.cgRect(fromAppKit: window.frame)
                // Half-open bounds, matching the Windows hit test.
                if point.x >= frame.minX, point.x < frame.maxX,
                   point.y >= frame.minY, point.y < frame.maxY {
                    return true
                }
            }
            return false
        }
    }

    func frontmostIsOwnApp() async -> Bool {
        await MainActor.run {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier else { return false }
            // Being the active app isn't enough. Once recording hides the report
            // window we STAY the active app with nothing on screen but the
            // non-activating pill, yet the user's click lands on ANOTHER app —
            // suppressing it here would eat their first capture (the dead first
            // click). Only suppress when a real, main-capable window of ours is
            // actually visible (e.g. the report window itself, or the no-hide
            // test mode). The pill/overlay are caught geometrically by
            // pointHitsOwnWindow, so this stays safe.
            return NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        }
    }
}
