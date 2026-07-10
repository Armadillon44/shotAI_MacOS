import CoreGraphics
import Foundation
import ScreenCaptureKit

/// The real Screenshotter: ScreenCaptureKit display captures with the app's
/// own windows excluded via the CONTENT FILTER — the only reliable exclusion
/// mechanism (NSWindow.sharingType = .none is ignored by SCK on macOS 15+).
/// Display captures include open menus/popovers (composited framebuffer),
/// which the context-menu capture path depends on.
public final class SCKScreenshotter: Screenshotter, @unchecked Sendable {
    private let ownPID: pid_t

    public init(ownPID: pid_t = getpid()) {
        self.ownPID = ownPID
    }

    /// Re-queried per capture — displays can reconfigure mid-recording.
    public func displays() async throws -> [DisplayInfo] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        return content.displays.map { display in
            DisplayInfo(
                id: display.displayID,
                frame: display.frame, // global top-left POINTS
                pixelScale: pixelScale(for: display),
                isPrimary: display.displayID == mainID,
                name: "Display \(display.displayID)"
            )
        }
    }

    public func captureDisplay(_ id: UInt32) async throws -> CapturedFrame {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Whole-app exclusion can't miss a stray tooltip/panel of ours. Match
        // by PID (precise, always present) — a bundle-id compare no-ops for a
        // non-bundled/dev run where bundleIdentifier is nil, silently leaving
        // our own windows in the captured pixels.
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        // width/height are PIXELS; sizing from contentRect × pointPixelScale
        // with .best is what yields native-resolution Retina captures.
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.captureResolution = .best
        // Exclude the mouse pointer from step screenshots — the click marker
        // already shows where the user clicked, and a stray cursor is noise.
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let info = DisplayInfo(
            id: display.displayID,
            frame: display.frame,
            // The authoritative pixels-per-point for THIS capture.
            pixelScale: display.frame.width > 0 ? CGFloat(image.width) / display.frame.width : scale,
            isPrimary: display.displayID == CGMainDisplayID(),
            name: "Display \(display.displayID)"
        )
        return CapturedFrame(image: image, display: info)
    }

    private func pixelScale(for display: SCDisplay) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID), display.frame.width > 0 else {
            return 1
        }
        // CGDisplayPixelsWide lies on Retina scaled modes; the mode's
        // pixelWidth over the point width is the true framebuffer ratio.
        return CGFloat(mode.pixelWidth) / display.frame.width
    }
}
