import CoreGraphics
import Foundation

/// Crop geometry ported formula-for-formula from CaptureController.ts, in the
/// global POINT space (the Windows math ran in global physical px; the units
/// change, the formulas don't). All rects are global top-left points; the
/// pixel conversion happens once, at CGImage cropping time (Downscale.swift).
public enum GrabMath {
    /// A crop result: the region in monitor-local points plus the global
    /// origin of the cropped image (== monitor.origin + crop.origin).
    public struct Crop: Equatable, Sendable {
        public var local: CGRect
        public var originX: CGFloat
        public var originY: CGFloat
    }

    /// cropToRegion: clamp a global-point region to the monitor. The right and
    /// bottom edges are computed from the UNCLAMPED local origin, so a region
    /// hanging off the left/top shrinks correctly.
    public static func cropToRegion(monitor: CGRect, region: CGRect) -> Crop {
        let lx = (region.minX - monitor.minX).rounded()
        let ly = (region.minY - monitor.minY).rounded()
        let cropX = max(0, min(lx, monitor.width - 1))
        let cropY = max(0, min(ly, monitor.height - 1))
        let cropW = max(1, min(lx + region.width.rounded(), monitor.width) - cropX)
        let cropH = max(1, min(ly + region.height.rounded(), monitor.height) - cropY)
        return Crop(
            local: CGRect(x: cropX, y: cropY, width: cropW, height: cropH),
            originX: monitor.minX + cropX,
            originY: monitor.minY + cropY
        )
    }

    /// Area-mode clamp — deliberately DIFFERENT from cropToRegion (preserved
    /// quirk): the width is clamped as min(w, monW − cropX) directly, so an
    /// area hanging off the monitor's left edge keeps its full width extending
    /// right from the edge rather than shrinking by the off-screen amount.
    public static func areaCrop(monitor: CGRect, area: CGRect) -> Crop {
        let cropX = max(0, min((area.minX - monitor.minX).rounded(), monitor.width - 1))
        let cropY = max(0, min((area.minY - monitor.minY).rounded(), monitor.height - 1))
        let cropW = max(1, min(area.width.rounded(), monitor.width - cropX))
        let cropH = max(1, min(area.height.rounded(), monitor.height - cropY))
        return Crop(
            local: CGRect(x: cropX, y: cropY, width: cropW, height: cropH),
            originX: monitor.minX + cropX,
            originY: monitor.minY + cropY
        )
    }

    /// 'auto' shell-region crop: an 820×640-point box centered on the click,
    /// shifted (not shrunk) to stay fully on-monitor.
    public static func regionCrop(monitor: CGRect, point: CGPoint) -> Crop {
        let boxW = min(CaptureConstants.regionBoxWidth.rounded(), monitor.width)
        let boxH = min(CaptureConstants.regionBoxHeight.rounded(), monitor.height)
        let cx = point.x - monitor.minX
        let cy = point.y - monitor.minY
        let cropX = max(0, min(cx - (boxW / 2).rounded(.down), monitor.width - boxW))
        let cropY = max(0, min(cy - (boxH / 2).rounded(.down), monitor.height - boxH))
        return Crop(
            local: CGRect(x: cropX, y: cropY, width: boxW, height: boxH),
            originX: monitor.minX + cropX,
            originY: monitor.minY + cropY
        )
    }

    /// The symmetric square unioned around a menu-selection click (symmetric
    /// because menus flip up/left near screen edges).
    public static func clickBox(point: CGPoint) -> CGRect {
        let half = CaptureConstants.menuClickBoxHalf.rounded()
        return CGRect(x: point.x - half, y: point.y - half, width: half * 2, height: half * 2)
    }

    /// Smallest rect containing both.
    public static func unionRect(_ a: CGRect, _ b: CGRect) -> CGRect {
        let minX = min(a.minX, b.minX)
        let minY = min(a.minY, b.minY)
        return CGRect(
            x: minX,
            y: minY,
            width: max(a.maxX, b.maxX) - minX,
            height: max(a.maxY, b.maxY) - minY
        )
    }

    /// Per-axis (Chebyshev) proximity, in points.
    public static func withinDistance(_ a: CGPoint, _ b: CGPoint, dx: CGFloat, dy: CGFloat) -> Bool {
        abs(a.x - b.x) <= dx && abs(a.y - b.y) <= dy
    }

    /// The display containing a point, else the primary, else the first. Use
    /// for the CLICK point / hotkey (mirrors the Windows clickMonitor
    /// derivation: fall back to a real monitor so a capture always happens).
    public static func display(for point: CGPoint?, in displays: [DisplayInfo]) -> DisplayInfo? {
        if let point, let hit = displays.first(where: { $0.frame.contains(point) }) {
            return hit
        }
        return displays.first(where: \.isPrimary) ?? displays.first
    }

    /// The display STRICTLY containing a point, or nil — NO primary fallback.
    /// Use for a window/area ORIGIN so callers can fall back to the click's
    /// monitor (`?? clickDisplay`) exactly as the Windows `Monitor.fromPoint
    /// (rect.origin) ?? clickMonitor` does; the primary-fallback variant above
    /// would silently capture the wrong screen for an off-arrangement origin.
    public static func display(containing point: CGPoint, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }
}
