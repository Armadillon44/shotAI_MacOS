import Foundation

/// Where a step's image sits inside its project frame (`ShotFrame`), for the
/// report and for exports. Pure, so the two can be pinned to each other and to
/// the Windows port by the shared table in `contract/frame-geometry.json`.
///
/// The rules (Armadillon44/shotAI#160):
/// - Zoom 1 FITS the whole image inside the frame and never enlarges it; an
///   image that does not fill the frame is centred with padding.
/// - The next zoom level FILLS the frame (`fillZoom`), and the overflow can be
///   panned. Zoom keeps stepping ×1.25 from there.
/// - Every frame in a project is the same size (`projectBox`), whatever the
///   image and whatever the window: it depends only on the frame and the
///   document scale, so the report, every export, a package and the Windows
///   port all frame a step the same way. A report column narrower than the box
///   draws the same framing scaled down; it never reframes.
/// - Pan is a fraction 0...1 of the overflow range on each axis, as it is for an
///   unframed step; unset, it centres the view on the click (`defaultPan`).
///
/// Units: image sizes and the visible region are in render pixels; the box,
/// the displayed image size and offsets are in the caller's display units
/// (report points).
public enum FrameGeometry {

    public struct Size: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public init(width: Double, height: Double) { self.width = width; self.height = height }
    }

    /// The project's frame box: the largest box of the frame's shape inside the
    /// document's image budget at this scale (`DocScale.htmlImageMax`, which the
    /// report's figure equals in a wide window, and the 600 × scale height cap).
    ///
    /// Framing is computed on this box, never on a measured column: for an image
    /// smaller than the box, fit, fill and what a stored zoom shows all depend on
    /// the box's absolute size, so a window-dependent box would make the report
    /// disagree with an export and change a saved zoom's meaning on resize.
    public static func projectBox(frame: ShotFrame, docScale: Double?) -> Size? {
        let s = DocScale.clamp(docScale)
        return box(budgetWidth: Double(DocScale.htmlImageMax(s)),
                   budgetHeight: ReportPresentation.baseHeight * s, frame: frame)
    }

    /// The largest box of the frame's shape inside a budget. The primitive under
    /// `projectBox`; nil for a degenerate budget.
    public static func box(budgetWidth: Double, budgetHeight: Double, frame: ShotFrame) -> Size? {
        guard budgetWidth.isFinite, budgetHeight.isFinite, budgetWidth > 0, budgetHeight > 0 else { return nil }
        let r = frame.ratio
        if budgetWidth / budgetHeight > r {
            return Size(width: budgetHeight * r, height: budgetHeight)
        }
        return Size(width: budgetWidth, height: budgetWidth / r)
    }

    /// The scale at zoom 1: the whole image inside the box, never enlarged.
    public static func fitScale(imageWidth w: Double, imageHeight h: Double, box: Size) -> Double {
        min(box.width / w, box.height / h, 1)
    }

    /// The zoom level at which the image covers the box: the first step in from
    /// fit. 1 when fit already fills it, or nearly: within `fillSnap` of fit the
    /// fill step would be a visual no-op (a crop a few pixels off the frame's
    /// shape), so zoom-in goes straight to ×1.25, which covers it.
    public static func fillZoom(imageWidth w: Double, imageHeight h: Double, box: Size) -> Double {
        let z = max(box.width / w, box.height / h) / fitScale(imageWidth: w, imageHeight: h, box: box)
        return z <= 1 + fillSnap ? 1 : z
    }

    /// The highest zoom: the usual 4×, or fill if that is further, so fill is
    /// always reachable.
    public static func maxZoom(fillZoom: Double) -> Double { max(ReportPresentation.zoomMax, fillZoom) }

    /// One press of zoom-in: fit goes to fill, then ×1.25, up to `maxZoom`.
    public static func zoomIn(from zoom: Double, fillZoom: Double) -> Double {
        let z = clampZoom(zoom, fillZoom: fillZoom)
        if fillZoom > 1, z < fillZoom * (1 - epsilon) { return fillZoom }
        return min(z * step, maxZoom(fillZoom: fillZoom))
    }

    /// One press of zoom-out, mirroring `zoomIn`: ÷1.25 down to fill, then fit.
    public static func zoomOut(from zoom: Double, fillZoom: Double) -> Double {
        let z = clampZoom(zoom, fillZoom: fillZoom)
        if z <= fillZoom * (1 + epsilon) { return 1 }
        return max(z / step, fillZoom)
    }

    /// What one image looks like in the box at a zoom and pan.
    public struct View: Equatable, Sendable {
        /// The zoom actually used, clamped to 1...`maxZoom`.
        public let zoom: Double
        public let fillZoom: Double
        /// Display units per image pixel.
        public let scale: Double
        /// The part of the image inside the box, in image pixels.
        public let visibleX: Double
        public let visibleY: Double
        public let visibleWidth: Double
        public let visibleHeight: Double
        /// The whole image as displayed, and where its top-left sits relative to
        /// the box's: positive when centred with padding, negative when panned.
        public let imageWidth: Double
        public let imageHeight: Double
        public let offsetX: Double
        public let offsetY: Double
        /// Whether the image overflows the box on that axis, so a drag can pan it.
        public var pannableX: Bool { imageWidth > boxWidth * (1 + epsilon) }
        public var pannableY: Bool { imageHeight > boxHeight * (1 + epsilon) }
        let boxWidth: Double
        let boxHeight: Double
    }

    public static func view(imageWidth w: Double, imageHeight h: Double, box: Size,
                            zoom: Double, panX: Double, panY: Double) -> View? {
        guard w.isFinite, h.isFinite, w > 0, h > 0, box.width > 0, box.height > 0 else { return nil }
        let fz = fillZoom(imageWidth: w, imageHeight: h, box: box)
        let z = clampZoom(zoom, fillZoom: fz)
        let d = fitScale(imageWidth: w, imageHeight: h, box: box) * z
        let vw = min(w, box.width / d), vh = min(h, box.height / d)
        let px = clampFraction(panX), py = clampFraction(panY)
        let iw = w * d, ih = h * d
        return View(
            zoom: z, fillZoom: fz, scale: d,
            visibleX: (w - vw) * px, visibleY: (h - vh) * py, visibleWidth: vw, visibleHeight: vh,
            imageWidth: iw, imageHeight: ih,
            offsetX: iw <= box.width ? (box.width - iw) / 2 : -(iw - box.width) * px,
            offsetY: ih <= box.height ? (box.height - ih) / 2 : -(ih - box.height) * py,
            boxWidth: box.width, boxHeight: box.height)
    }

    /// The pan that centres the view on the click, clamped so the view stays
    /// inside the image: near an edge or corner it is as close as it can get.
    /// `click` is in render pixels (`ProjectStep.clickInRender`). No click, or
    /// one outside the image, centres the image instead (0.5, 0.5).
    public static func defaultPan(click: (x: Double, y: Double)?, imageWidth w: Double, imageHeight h: Double,
                                  box: Size, zoom: Double) -> (x: Double, y: Double) {
        guard let c = click, c.x.isFinite, c.y.isFinite, c.x >= 0, c.y >= 0, c.x <= w, c.y <= h,
              let v = view(imageWidth: w, imageHeight: h, box: box, zoom: zoom, panX: 0.5, panY: 0.5)
        else { return (0.5, 0.5) }
        func axis(_ p: Double, _ full: Double, _ visible: Double) -> Double {
            let range = full - visible
            guard range > full * epsilon else { return 0.5 }
            return clampFraction((p - visible / 2) / range)
        }
        return (axis(c.x, w, v.visibleWidth), axis(c.y, h, v.visibleHeight))
    }

    /// An export's framed image, in whole pixels: a transparent canvas the frame's
    /// shape, and the region of the render drawn on it. With overflow on both
    /// axes there is no padding and this is a plain crop.
    public struct ExportLayout: Equatable, Sendable {
        public let canvasWidth: Int
        public let canvasHeight: Int
        public let cropX: Int
        public let cropY: Int
        public let cropWidth: Int
        public let cropHeight: Int
        /// Where the crop's top-left goes on the canvas.
        public let originX: Int
        public let originY: Int
        /// The render's size, so `isIdentity` can tell the whole image from a crop.
        public let imageWidth: Int
        public let imageHeight: Int
        /// True when the result would be the render itself, unchanged: the crop is
        /// the whole image and there is no padding.
        public var isIdentity: Bool {
            cropWidth == imageWidth && cropHeight == imageHeight
                && canvasWidth == cropWidth && canvasHeight == cropHeight
        }
    }

    /// The export framing for the same inputs as `view`, so an export shows what
    /// the report shows. Rounds half up (`.rounded()` on positive values, which
    /// is JavaScript's `Math.round` too).
    public static func exportLayout(imageWidth: Int, imageHeight: Int, box: Size,
                                    zoom: Double, panX: Double, panY: Double) -> ExportLayout? {
        let w = Double(imageWidth), h = Double(imageHeight)
        guard imageWidth > 0, imageHeight > 0,
              let v = view(imageWidth: w, imageHeight: h, box: box, zoom: zoom, panX: panX, panY: panY)
        else { return nil }
        let cw = Int(min(w, max(1, v.visibleWidth.rounded())))
        let ch = Int(min(h, max(1, v.visibleHeight.rounded())))
        let cx = Int(min(w - Double(cw), max(0, ((w - Double(cw)) * clampFraction(panX)).rounded())))
        let cy = Int(min(h - Double(ch), max(0, ((h - Double(ch)) * clampFraction(panY)).rounded())))
        let canvasW = max(cw, Int((box.width / v.scale).rounded()))
        let canvasH = max(ch, Int((box.height / v.scale).rounded()))
        return ExportLayout(canvasWidth: canvasW, canvasHeight: canvasH,
                            cropX: cx, cropY: cy, cropWidth: cw, cropHeight: ch,
                            originX: (canvasW - cw) / 2, originY: (canvasH - ch) / 2,
                            imageWidth: imageWidth, imageHeight: imageHeight)
    }

    // MARK: -

    static let step = 1.25
    static let epsilon = 1e-9
    /// Fill within 1% of fit counts as fit (see `fillZoom`).
    static let fillSnap = 0.01

    static func clampZoom(_ zoom: Double, fillZoom: Double) -> Double {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, 1), maxZoom(fillZoom: fillZoom))
    }

    static func clampFraction(_ v: Double) -> Double {
        guard v.isFinite else { return 0.5 }
        return min(max(v, 0), 1)
    }
}

extension ProjectStep {
    /// The click in the render's pixels, for `FrameGeometry.defaultPan`: the
    /// render is the crop at 1:1 (or the whole screenshot without one), so this
    /// is `click.image` less the crop origin. nil without a click.
    public var clickInRender: (x: Double, y: Double)? {
        guard let c = click else { return nil }
        return (c.image.x - (crop?.x ?? 0), c.image.y - (crop?.y ?? 0))
    }
}
