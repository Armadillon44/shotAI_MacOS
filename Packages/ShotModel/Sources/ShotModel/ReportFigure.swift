import Foundation

extension ReportPresentation {

    /// Everything the report's step figure draws and does, in display points,
    /// for a framed or an unframed project. Pure, so the zoom and drag rules are
    /// tested here and the view only renders this.
    ///
    /// The view passes the step with any change it has not saved yet already
    /// applied (a zoom just chosen, a pan being dragged, a pan just cleared), so
    /// what it shows does not jump when the save lands.
    public struct FigureLayout: Equatable, Sendable {
        /// True when the project's frame drives this layout (`FrameGeometry`).
        public let framed: Bool
        /// The clip box. Framed, the project's frame box, scaled down only when
        /// the column is narrower than it.
        public let boxWidth: Double
        public let boxHeight: Double
        /// The whole image as drawn, and where its top-left sits in the box:
        /// positive on an axis it is centred on with padding, ≤ 0 when panned.
        public let imageWidth: Double
        public let imageHeight: Double
        public let offsetX: Double
        public let offsetY: Double
        /// The zoom in effect, clamped to 1…`maxZoom`.
        public let zoom: Double
        public let maxZoom: Double
        /// Whether a drag moves the image on that axis.
        public let pannableX: Bool
        public let pannableY: Bool
        /// One press of zoom in / out from here; nil when the button does nothing.
        public let zoomInTarget: Double?
        public let zoomOutTarget: Double?
        /// Whether Reset does anything: a zoom above fit or, framed, a saved pan.
        public let canReset: Bool
        /// Framed, Reset also clears the saved pan, back to the click
        /// (Armadillon44/shotAI#160). Unframed, it only resets the zoom, as before.
        public var resetClearsPan: Bool { framed }

        public var canPan: Bool { pannableX || pannableY }

        /// Where a drag from `start` by `dx, dy` leaves the image: kept inside
        /// the box on a pannable axis, and unmoved on an axis that is not, where
        /// the offset is the centring padding (positive) and must stay so.
        public func draggedOffset(fromX startX: Double, fromY startY: Double,
                                  dx: Double, dy: Double) -> (x: Double, y: Double) {
            (pannableX ? min(0, max(-(imageWidth - boxWidth), startX + dx)) : offsetX,
             pannableY ? min(0, max(-(imageHeight - boxHeight), startY + dy)) : offsetY)
        }

        /// The saved pan for an offset: a fraction of the overflow on each
        /// pannable axis, and nil on an axis that is not, so a drag never writes
        /// a position the user did not choose (framed, an unset axis follows
        /// the click as the zoom changes).
        public func pan(forOffsetX x: Double, offsetY y: Double) -> (x: Double?, y: Double?) {
            func axis(_ on: Bool, _ offset: Double, _ range: Double) -> Double? {
                on && range > 0 ? min(1, max(0, -offset / range)) : nil
            }
            return (axis(pannableX, x, imageWidth - boxWidth), axis(pannableY, y, imageHeight - boxHeight))
        }
    }

    /// The figure layout for a step's image of `imagePixelSize`.
    ///
    /// `frame` nil (or none parsed) keeps the unframed report exactly as it was
    /// (`viewport`). With a frame, the box is `FrameGeometry.projectBox` for the
    /// document scale, never the measured column: a column narrower than the
    /// box (`fitWidth`) shows the same framing scaled down, so the report always
    /// shows what the exports show.
    public static func figureLayout(for step: ProjectStep,
                                    imagePixelSize: (width: Double, height: Double),
                                    frame: ShotFrame?,
                                    docScale: Double,
                                    fitWidth: Double) -> FigureLayout? {
        guard let frame else { return unframedLayout(step, imagePixelSize, docScale, fitWidth) }
        let (w, h) = imagePixelSize
        guard let box = FrameGeometry.projectBox(frame: frame, docScale: docScale) else { return nil }
        let pan = FrameGeometry.pan(for: step, imageWidth: w, imageHeight: h, box: box)
        guard let v = FrameGeometry.view(imageWidth: w, imageHeight: h, box: box,
                                         zoom: step.reportZoom ?? 1, panX: pan.x, panY: pan.y)
        else { return nil }
        let k = fitWidth.isFinite && fitWidth > 0 ? min(1, fitWidth / box.width) : 1
        let maxZoom = FrameGeometry.maxZoom(fillZoom: v.fillZoom)
        return FigureLayout(
            framed: true,
            boxWidth: box.width * k, boxHeight: box.height * k,
            imageWidth: v.imageWidth * k, imageHeight: v.imageHeight * k,
            offsetX: v.offsetX * k, offsetY: v.offsetY * k,
            zoom: v.zoom, maxZoom: maxZoom,
            pannableX: v.pannableX, pannableY: v.pannableY,
            zoomInTarget: changed(FrameGeometry.zoomIn(from: v.zoom, fillZoom: v.fillZoom), from: v.zoom),
            zoomOutTarget: changed(FrameGeometry.zoomOut(from: v.zoom, fillZoom: v.fillZoom), from: v.zoom),
            canReset: v.zoom != 1 || step.reportPanX != nil || step.reportPanY != nil)
    }

    private static func unframedLayout(_ step: ProjectStep, _ size: (width: Double, height: Double),
                                       _ docScale: Double, _ fitWidth: Double) -> FigureLayout? {
        guard let vp = viewport(for: step, imagePixelSize: size, fitWidth: fitWidth, docScale: docScale)
        else { return nil }
        let zoom = min(max(step.reportZoom ?? 1, zoomMin), zoomMax)
        return FigureLayout(
            framed: false,
            boxWidth: vp.boxWidth, boxHeight: vp.boxHeight,
            imageWidth: vp.imageWidth, imageHeight: vp.imageHeight,
            offsetX: vp.offsetX, offsetY: vp.offsetY,
            zoom: zoom, maxZoom: zoomMax,
            // Half a point of overflow is not worth a drag (the unframed rule).
            pannableX: vp.imageWidth - vp.boxWidth > 0.5,
            pannableY: vp.imageHeight - vp.boxHeight > 0.5,
            zoomInTarget: changed(min(zoom * FrameGeometry.step, zoomMax), from: zoom),
            zoomOutTarget: changed(max(zoom / FrameGeometry.step, zoomMin), from: zoom),
            canReset: zoom != 1)
    }

    /// nil when a zoom step lands where it started (at a limit).
    private static func changed(_ target: Double, from zoom: Double) -> Double? {
        abs(target - zoom) > zoom * FrameGeometry.epsilon ? target : nil
    }
}
