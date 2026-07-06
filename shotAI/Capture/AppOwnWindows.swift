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
            NSWorkspace.shared.frontmostApplication?.processIdentifier
                == ProcessInfo.processInfo.processIdentifier
        }
    }
}
