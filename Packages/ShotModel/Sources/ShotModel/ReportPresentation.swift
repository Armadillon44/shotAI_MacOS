import Foundation

/// Pure presentation rules for the report view, ported from the Windows
/// renderer (`Report.tsx` + `editor/annotations.ts`) so the Mac report renders a
/// Windows-created project identically. Kept in ShotModel (UI-free) so the rules
/// are unit-tested by `swift test`.
public enum ReportPresentation {
    /// Base display box for report images (display only — export is full-res).
    public static let baseWidth: Double = 820
    public static let baseHeight: Double = 600
    /// Report zoom is IN-only: 1 = fit, never below (a legacy/hand-edited
    /// sub-1 value is floored to 1 on read, matching Windows ZOOM_MIN).
    public static let zoomMin: Double = 1
    public static let zoomMax: Double = 4

    /// High-contrast accent for markers (rose-600) and the right-click blue —
    /// same constants as `annotations.ts`.
    public static let accentHex = "#e11d48"
    public static let rightClickHex = "#2563eb"

    /// The click-ring color for a step: a user-set markerColor wins, else
    /// right-clicks are blue and everything else rose.
    public static func markerColorHex(for step: ProjectStep) -> String {
        step.markerColor ?? (step.click?.button == .right ? rightClickHex : accentHex)
    }

    /// A text step styled as a callout — an annotation, NOT a numbered step.
    public static func isCalloutStep(_ step: ProjectStep) -> Bool {
        step.kind == .text && step.callout != nil
    }

    /// Rail badge glyph per callout kind (the box color already conveys it).
    public static func calloutGlyph(_ kind: CalloutKind) -> String {
        switch kind {
        case .note: "ℹ"
        case .caution: "⚠"
        case .warning: "⛔"
        }
    }

    /// Number only NON-callout steps, contiguously 1..N (callouts get a glyph).
    public static func displayNumbers(for steps: [ProjectStep]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        var n = 0
        for step in steps where !isCalloutStep(step) {
            n += 1
            numbers[step.id] = n
        }
        return numbers
    }

    /// Which image file the report shows for a step: the flattened render
    /// (annotations baked + redaction) once the step has been edited, else the
    /// raw screenshot. nil for text steps.
    public static func displayImagePath(for step: ProjectStep) -> String? {
        if let flattened = step.flattened, !flattened.isEmpty { return flattened }
        return step.screenshot.isEmpty ? nil : step.screenshot
    }

    /// Where to draw the click-marker overlay, as a fraction (0...1) of the
    /// displayed image. nil when there's no click, when the marker is already
    /// BAKED into the flattened pixels (drawing it again would double), or when
    /// the click falls outside the visible region. When the displayed image is
    /// the cropped flatten, the crop origin is subtracted first.
    public static func markerFraction(
        for step: ProjectStep,
        displayedImageSize size: (width: Double, height: Double)
    ) -> (x: Double, y: Double)? {
        guard let click = step.click, step.markerBaked != true,
              size.width > 0, size.height > 0 else { return nil }
        let hasFlattened = !(step.flattened ?? "").isEmpty
        let offX = hasFlattened ? (step.crop?.x ?? 0) : 0
        let offY = hasFlattened ? (step.crop?.y ?? 0) : 0
        let fx = (click.image.x - offX) / size.width
        let fy = (click.image.y - offY) / size.height
        guard fx >= 0, fx <= 1, fy >= 0, fy <= 1 else { return nil }
        return (fx, fy)
    }

    /// Geometry of the report image viewport for a step, mirroring StepFigure:
    /// the image fits within 820x600 at zoom 1; the box shrinks for zoom<1 and
    /// stays fixed for zoom>1 so the image overflows and pans in both axes.
    public struct Viewport: Equatable, Sendable {
        /// The visible box the image is clipped to.
        public var boxWidth: Double
        public var boxHeight: Double
        /// The (scaled) image size inside the box.
        public var imageWidth: Double
        public var imageHeight: Double
        /// Top-left offset of the image within the box (≤ 0 when panning).
        public var offsetX: Double
        public var offsetY: Double
    }

    public static func viewport(
        for step: ProjectStep,
        imagePixelSize: (width: Double, height: Double),
        zoomOverride: Double? = nil
    ) -> Viewport? {
        let (w, h) = imagePixelSize
        guard w > 0, h > 0 else { return nil }
        // zoomOverride drives the optimistic in-editor zoom before the persisted
        // value round-trips; both are clamped to the IN-only [1, max] range.
        let zoom = min(max(zoomOverride ?? step.reportZoom ?? 1, zoomMin), zoomMax)
        let baseScale = min(baseWidth / w, baseHeight / h, 1)
        let baseW = w * baseScale
        let baseH = h * baseScale
        let boxScale = min(zoom, 1)
        let imgW = baseW * zoom
        let imgH = baseH * zoom
        let boxW = baseW * boxScale
        let boxH = baseH * boxScale
        // Persisted pan is a fraction 0..1 of the scrollable range (0.5 = center).
        let panX = min(max(step.reportPanX ?? 0.5, 0), 1)
        let panY = min(max(step.reportPanY ?? 0.5, 0), 1)
        return Viewport(
            boxWidth: boxW,
            boxHeight: boxH,
            imageWidth: imgW,
            imageHeight: imgH,
            offsetX: -(imgW - boxW) * panX,
            offsetY: -(imgH - boxH) * panY
        )
    }
}
