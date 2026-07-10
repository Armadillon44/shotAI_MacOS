import AppKit
import CoreGraphics
import EditorKit
import Foundation
import ImageIO
import Observation
import ShotModel

/// Working state for the redaction-first annotation editor (C4a). Edits the RAW
/// screenshot (never the already-flattened render); save re-flattens from the
/// raw with the full annotation list + crop + baked click marker, so redaction
/// is always destroyed into fresh pixels. Non-blur annotations are preserved
/// untouched and re-baked on save.
@MainActor
@Observable
final class EditorModel {
    enum Tool: String, CaseIterable { case select, box, arrow, redact, number, marker, text, crop }

    /// Sentinel selection id for the step's captured click marker (the Windows
    /// CLICK_ID pseudo-element) — it's not an annotation, so selection/edit
    /// special-case this id.
    static let clickID = "__click__"

    let step: ProjectStep
    let projectDir: String
    let rawImage: CGImage
    /// Image pixel size — the coordinate space of annotations/crop/click.image.
    let imageSize: CGSize

    var annotations: [Annotation]
    var crop: Rect?
    var tool: Tool = .select
    var redactMode: BlurAnnotation.Mode = .pixelate
    var redactBlock: Double = AnnotationStyle.defaultBlockSize
    /// Draw color for NEW shapes (box/arrow) and applied to the colorable
    /// selection. Hex, matching the Windows accent default.
    var strokeColor: String = AnnotationStyle.accent
    /// Stroke width for new shapes + applied to the selection (seeded to the
    /// image-scaled default in init).
    var strokeWidth: Double = Double(AnnotationStyle.defaultStrokeWidth)
    /// Font size for new text + applied to the selected text (seeded in init).
    var fontSize: Double = 28

    // Editable captured click marker (the __click__ pseudo-element). Seeded from
    // step.click; nil clickPoint = the marker was removed.
    var clickPoint: CGPoint?
    var clickRadius: Double?
    var markerColor: String = AnnotationStyle.accent

    // Inline text editing state — lifted from the view so save() can flush it
    // deterministically (a Save while a field is focused must not lose the text).
    var editingTextID: String?
    var editingText: String = ""

    var selectedID: String?
    var scanning = false
    var saving = false
    var errorMessage: String?

    private let store: ProjectStore
    private let scanner: any OCRScanning

    init?(step: ProjectStep, projectDir: String, store: ProjectStore, scanner: any OCRScanning) {
        // Load the RAW screenshot (confined), not step.flattened — the editor
        // always composes from the original pixels.
        guard !step.screenshot.isEmpty,
              let abs = confinePath(dir: projectDir, rel: step.screenshot),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: abs) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            Log.editor.error("raw screenshot load failed for step \(step.id, privacy: .public)")
            return nil
        }
        self.step = step
        self.projectDir = projectDir
        self.rawImage = cg
        self.imageSize = CGSize(width: cg.width, height: cg.height)
        self.annotations = step.annotations
        self.crop = step.crop
        self.store = store
        self.scanner = scanner
        // Seed the new-shape stroke width to the image-scaled default so lines
        // read boldly on large captures. Cap at the slider's ceiling (40) so a
        // very large image's default can't sit above the slider's range.
        self.strokeWidth = min(40, Double(AnnotationStyle.defaultStrokeWidth(
            width: imageSize.width, height: imageSize.height)))
        self.fontSize = Double(AnnotationStyle.defaultFontSize(
            width: imageSize.width, height: imageSize.height))
        // Seed the editable click marker from the captured click.
        if let c = step.click {
            self.clickPoint = CGPoint(x: c.image.x, y: c.image.y)
            self.clickRadius = c.radius
        }
        self.markerColor = AnnotationStyle.markerColor(for: step)
        Log.editor.info("editor opened step \(step.id, privacy: .public) raw=\(cg.width, privacy: .public)x\(cg.height, privacy: .public)")
    }

    // MARK: - Geometry helpers

    /// Clamp a rect (image px) to the image bounds. A redaction or crop drawn
    /// starting in the letterbox margin has negative/oversized coords; without
    /// this the crop far edge shifts outward and RE-INCLUDES pixels the user
    /// cropped out, and off-image redactions get silently dropped at flatten.
    func clampedToImage(_ r: CGRect) -> CGRect {
        let x0 = max(0, min(r.minX, imageSize.width))
        let y0 = max(0, min(r.minY, imageSize.height))
        let x1 = max(0, min(r.maxX, imageSize.width))
        let y1 = max(0, min(r.maxY, imageSize.height))
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Add a redaction over `rect` (image px, clamped to the image) with the
    /// current style; select it. Ignores a degenerate rect.
    func addRedaction(_ rect: CGRect) {
        let r = clampedToImage(rect)
        guard r.width >= 1, r.height >= 1 else { return }
        let id = newAnnotationID()
        annotations.append(.blur(BlurAnnotation(
            id: id, x: r.minX, y: r.minY, width: r.width, height: r.height,
            mode: redactMode, blockSize: redactBlock)))
        selectedID = id
        tool = .select // every draw tool drops to Select + selects the new shape
    }

    /// Set (or clear) the crop, clamped to the image bounds.
    func setCrop(_ rect: CGRect?) {
        guard let rect else { crop = nil; return }
        let r = clampedToImage(rect)
        crop = (r.width >= 1 && r.height >= 1) ? Rect(x: r.minX, y: r.minY, width: r.width, height: r.height) : nil
    }

    // MARK: - Shape creation (box / arrow)

    /// Add a rounded box over `rect` (image px) with the current stroke style;
    /// select it and drop to the Select tool (matches the Windows editor, which
    /// auto-selects a freshly drawn shape so it's immediately adjustable).
    func addRect(_ rect: CGRect) {
        let r = normalizedPositive(rect)
        guard r.width >= 1, r.height >= 1 else { return }
        let id = newAnnotationID()
        annotations.append(.rect(RectAnnotation(
            id: id, x: r.minX, y: r.minY, width: r.width, height: r.height,
            cornerRadius: 10, stroke: strokeColor, strokeWidth: strokeWidth, fill: nil)))
        selectedID = id
        tool = .select
    }

    /// Add an arrow from `a` to `b` (image px) with the current stroke style.
    func addArrow(from a: CGPoint, to b: CGPoint) {
        guard hypot(b.x - a.x, b.y - a.y) >= 1 else { return }
        let id = newAnnotationID()
        annotations.append(.arrow(ArrowAnnotation(
            id: id, points: [a.x, a.y, b.x, b.y], stroke: strokeColor, strokeWidth: strokeWidth)))
        selectedID = id
        tool = .select
    }

    /// Add a numbered stamp centered at `point`. The number is (existing stamps)+1
    /// — free labels, NOT tied to step order, and NOT renumbered on delete
    /// (matching Windows). Fill = current color; digits white.
    func addStamp(at point: CGPoint) {
        let n = annotations.reduce(0) { if case .stamp = $1 { return $0 + 1 }; return $0 } + 1
        let radius = Double(AnnotationStyle.defaultStampRadius(width: imageSize.width, height: imageSize.height))
        let id = newAnnotationID()
        annotations.append(.stamp(StampAnnotation(
            id: id, x: point.x, y: point.y, n: n, radius: radius,
            fill: strokeColor, textColor: "#ffffff")))
        selectedID = id
        tool = .select
    }

    /// Add a movable click-register ring centered at `point` (radius derived from
    /// the image at draw time — only center + color are stored).
    func addMarker(at point: CGPoint) {
        let id = newAnnotationID()
        annotations.append(.marker(MarkerAnnotation(
            id: id, x: point.x, y: point.y, color: strokeColor, radius: nil)))
        selectedID = id
        tool = .select
    }

    /// Add an (initially empty) text label at `point`; the overlay opens the
    /// inline editor. Empty text is dropped on commit/save.
    @discardableResult
    func addText(at point: CGPoint) -> String {
        let id = newAnnotationID()
        annotations.append(.text(TextAnnotation(
            id: id, x: point.x, y: point.y, text: "", fontSize: fontSize, fill: strokeColor)))
        selectedID = id
        tool = .select
        editingText = ""
        editingTextID = id // open the inline editor
        return id
    }

    // MARK: - Inline text editing (model-owned so save() can flush it)

    func beginEditingText(id: String, initial: String) {
        editingText = initial
        editingTextID = id
    }

    /// Commit the in-progress inline text edit; empty labels are dropped.
    /// Idempotent, and called at the top of save() so a Save-while-focused can't
    /// lose the typed text or persist an orphaned empty label.
    func commitPendingText() {
        guard let id = editingTextID else { return }
        let text = editingText
        editingTextID = nil
        editingText = ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            deleteAnnotation(id: id)
        } else {
            setTextContent(id: id, text)
        }
    }

    // MARK: - Click marker (the __click__ pseudo-element)

    func clickEffectiveRadius() -> Double {
        clickRadius ?? Double(AnnotationStyle.clickMarkerRadius(width: imageSize.width, height: imageSize.height))
    }

    func clickBounds() -> CGRect? {
        guard let p = clickPoint else { return nil }
        let r = clickEffectiveRadius()
        return CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
    }

    func setClickPoint(_ p: CGPoint) {
        clickPoint = CGPoint(x: max(0, min(p.x, imageSize.width)), y: max(0, min(p.y, imageSize.height)))
    }

    func removeClickMarker() {
        clickPoint = nil
        if selectedID == Self.clickID { selectedID = nil }
    }

    // MARK: - Selection & editing (all editable shape types)

    private var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return annotations.firstIndex { $0.id == id }
    }

    /// Bounding rect (image px) of an editable annotation — for hit-testing,
    /// selection handles, and resize. nil only for unknown/unsupported types.
    func bounds(of a: Annotation) -> CGRect? {
        switch a {
        case .rect(let r): return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        case .blur(let b): return CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
        case .arrow(let ar) where ar.points.count == 4:
            return normalizedPositive(CGRect(
                x: ar.points[0], y: ar.points[1],
                width: ar.points[2] - ar.points[0], height: ar.points[3] - ar.points[1]))
        case .stamp(let s):
            return CGRect(x: s.x - s.radius, y: s.y - s.radius, width: s.radius * 2, height: s.radius * 2)
        case .marker(let m):
            let r = m.radius ?? Double(AnnotationStyle.clickMarkerRadius(width: imageSize.width, height: imageSize.height))
            return CGRect(x: m.x - r, y: m.y - r, width: r * 2, height: r * 2)
        case .text(let t):
            return textBounds(t)
        default:
            return nil
        }
    }

    /// Measured bounding box of a text label (image px), top-left at (x,y). Uses
    /// Helvetica to match Flatten's baked font; an empty label gets a small
    /// clickable box so it can still be selected.
    func textBounds(_ t: TextAnnotation) -> CGRect {
        let font = NSFont(name: "Helvetica", size: t.fontSize) ?? NSFont.systemFont(ofSize: t.fontSize)
        let measured = (t.text.isEmpty ? "Text" : t.text) as NSString
        let size = measured.size(withAttributes: [.font: font])
        return CGRect(x: t.x, y: t.y,
                      width: max(size.width, t.fontSize), height: max(size.height, t.fontSize))
    }

    func boundsOfSelected() -> CGRect? {
        if selectedID == Self.clickID { return clickBounds() }
        guard let i = selectedIndex else { return nil }
        return bounds(of: annotations[i])
    }

    /// The selected annotation, or nil.
    var selected: Annotation? {
        guard let i = selectedIndex else { return nil }
        return annotations[i]
    }

    /// Whether the selection has a user-editable color (drives the color picker).
    var selectedIsColorable: Bool {
        if selectedID == Self.clickID { return true }
        switch selected { case .rect, .arrow, .stamp, .marker, .text: return true; default: return false }
    }

    /// A circle whose resize is radius-from-center (stamp / marker / click ring).
    var selectedIsCircle: Bool {
        if selectedID == Self.clickID { return true }
        switch selected { case .stamp, .marker: return true; default: return false }
    }

    /// Whether the selection uses the stroke-width slider (box/arrow only).
    var selectedHasStrokeWidth: Bool {
        switch selected { case .rect, .arrow: return true; default: return false }
    }

    var selectedIsBlur: Bool {
        if case .blur = selected { return true }
        return false
    }

    var selectedIsText: Bool {
        if case .text = selected { return true }
        return false
    }

    /// Text is sized via the font slider, not corner handles; everything else
    /// (incl. the click marker) gets a resize handle.
    var selectedIsResizable: Bool {
        if selectedID == Self.clickID { return clickPoint != nil }
        guard selectedID != nil, !selectedIsText else { return false }
        return boundsOfSelected() != nil
    }

    /// Select the topmost editable annotation under `point` (image px), syncing
    /// the style controls to it. Deselects if nothing editable is hit.
    func selectAnnotation(at point: CGPoint) {
        // The click marker is drawn on top of the annotations, so hit-test it
        // first. Sync the color picker to its color.
        if let p = clickPoint, hypot(point.x - p.x, point.y - p.y) <= clickEffectiveRadius() {
            selectedID = Self.clickID
            strokeColor = markerColor
            return
        }
        for a in annotations.reversed() where hitTest(a, point) {
            selectedID = a.id
            switch a {
            case .rect(let r): strokeColor = r.stroke; strokeWidth = r.strokeWidth
            case .arrow(let ar): strokeColor = ar.stroke; strokeWidth = ar.strokeWidth
            case .blur(let b): redactMode = b.mode; redactBlock = b.blockSize
            case .stamp(let s): strokeColor = s.fill
            case .marker(let m): strokeColor = m.color
            case .text(let t): strokeColor = t.fill; fontSize = t.fontSize
            default: break
            }
            return
        }
        selectedID = nil
    }

    private func hitTest(_ a: Annotation, _ p: CGPoint) -> Bool {
        switch a {
        case .rect, .blur, .text:
            return bounds(of: a)?.contains(p) ?? false
        case .arrow(let ar) where ar.points.count == 4:
            let d = distanceToSegment(p,
                CGPoint(x: ar.points[0], y: ar.points[1]),
                CGPoint(x: ar.points[2], y: ar.points[3]))
            return d <= max(ar.strokeWidth, 10) // fat hit band so thin arrows are grabbable
        case .stamp(let s):
            return hypot(p.x - s.x, p.y - s.y) <= s.radius
        case .marker(let m):
            let r = m.radius ?? Double(AnnotationStyle.clickMarkerRadius(width: imageSize.width, height: imageSize.height))
            return hypot(p.x - m.x, p.y - m.y) <= r
        default:
            return false
        }
    }

    /// Topmost text label under `point` — for double-click-to-edit.
    func textAt(_ point: CGPoint) -> TextAnnotation? {
        for a in annotations.reversed() {
            if case .text(let t) = a, textBounds(t).contains(point) { return t }
        }
        return nil
    }

    /// Translate the selected annotation by (dx, dy), starting from `original`
    /// (the snapshot taken at drag start). A moved blur keeps its SIZE and stays
    /// fully on-image (origin clamped) — an intersection clamp would shrink it at
    /// an edge and could reveal pixels the user meant to redact. Box/arrow may
    /// overhang (the bake clips them), matching Windows.
    func moveSelected(_ original: Annotation, dx: CGFloat, dy: CGFloat) {
        guard let i = selectedIndex else { return }
        annotations[i] = clampBlurOrigin(translate(original, dx: dx, dy: dy))
    }

    /// Resize the selected annotation to `newBounds`, scaling `original`'s
    /// geometry from its own bounds.
    func resizeSelected(_ original: Annotation, to newBounds: CGRect) {
        guard let i = selectedIndex, let ob = bounds(of: original) else { return }
        annotations[i] = storable(scale(original, to: newBounds, from: ob))
    }

    func setSelectedColor(_ hex: String) {
        if selectedID == Self.clickID { markerColor = hex; return }
        guard let i = selectedIndex else { return }
        switch annotations[i] {
        case .rect(var r): r.stroke = hex; annotations[i] = .rect(r)
        case .arrow(var ar): ar.stroke = hex; annotations[i] = .arrow(ar)
        case .stamp(var s): s.fill = hex; annotations[i] = .stamp(s)
        case .marker(var m): m.color = hex; annotations[i] = .marker(m)
        case .text(var t): t.fill = hex; annotations[i] = .text(t)
        default: break
        }
    }

    /// Set the radius of the selected circle (click marker / stamp / marker) — a
    /// center-anchored resize where the handle tracks the pointer.
    func setSelectedRadius(_ r: Double) {
        let radius = max(4, r)
        if selectedID == Self.clickID { clickRadius = radius; return }
        guard let i = selectedIndex else { return }
        switch annotations[i] {
        case .stamp(var s): s.radius = radius; annotations[i] = .stamp(s)
        case .marker(var m): m.radius = radius; annotations[i] = .marker(m)
        default: break
        }
    }

    func setSelectedFontSize(_ size: Double) {
        guard let i = selectedIndex, case .text(var t) = annotations[i] else { return }
        t.fontSize = size
        annotations[i] = .text(t)
    }

    /// Set a text label's content (inline editor commit). Empty text is left for
    /// the caller to drop.
    func setTextContent(id: String, _ text: String) {
        guard let i = annotations.firstIndex(where: { $0.id == id }),
              case .text(var t) = annotations[i] else { return }
        t.text = text
        annotations[i] = .text(t)
    }

    /// Remove a specific annotation by id (used to drop an empty text on commit).
    func deleteAnnotation(id: String) {
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func setSelectedStrokeWidth(_ w: Double) {
        guard let i = selectedIndex else { return }
        switch annotations[i] {
        case .rect(var r): r.strokeWidth = w; annotations[i] = .rect(r)
        case .arrow(var ar): ar.strokeWidth = w; annotations[i] = .arrow(ar)
        default: break
        }
    }

    func deleteSelected() {
        if selectedID == Self.clickID { removeClickMarker(); return }
        guard let id = selectedID else { return }
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    /// Apply the redaction style controls to the selected blur (else they apply
    /// to the next one created).
    func applyStyleToSelected() {
        guard let i = selectedIndex, case .blur(var b) = annotations[i] else { return }
        b.mode = redactMode
        b.blockSize = redactBlock
        annotations[i] = .blur(b)
    }

    // MARK: - Geometry primitives

    private func normalizedPositive(_ r: CGRect) -> CGRect {
        CGRect(x: min(r.minX, r.maxX), y: min(r.minY, r.maxY),
               width: abs(r.width), height: abs(r.height))
    }

    private func translate(_ a: Annotation, dx: CGFloat, dy: CGFloat) -> Annotation {
        switch a {
        case .rect(var r): r.x += dx; r.y += dy; return .rect(r)
        case .blur(var b): b.x += dx; b.y += dy; return .blur(b)
        case .arrow(var ar) where ar.points.count == 4:
            ar.points = [ar.points[0] + dx, ar.points[1] + dy, ar.points[2] + dx, ar.points[3] + dy]
            return .arrow(ar)
        case .stamp(var s): s.x += dx; s.y += dy; return .stamp(s)
        case .marker(var m): m.x += dx; m.y += dy; return .marker(m)
        case .text(var t): t.x += dx; t.y += dy; return .text(t)
        default: return a
        }
    }

    private func scale(_ a: Annotation, to nb: CGRect, from ob: CGRect) -> Annotation {
        func mapX(_ x: CGFloat) -> CGFloat { ob.width > 0 ? nb.minX + (x - ob.minX) / ob.width * nb.width : nb.midX }
        func mapY(_ y: CGFloat) -> CGFloat { ob.height > 0 ? nb.minY + (y - ob.minY) / ob.height * nb.height : nb.midY }
        switch a {
        case .rect(var r):
            r.x = nb.minX; r.y = nb.minY; r.width = max(4, nb.width); r.height = max(4, nb.height)
            return .rect(r)
        case .blur(var b):
            b.x = nb.minX; b.y = nb.minY; b.width = max(4, nb.width); b.height = max(4, nb.height)
            return .blur(b)
        case .arrow(var ar) where ar.points.count == 4:
            ar.points = [mapX(ar.points[0]), mapY(ar.points[1]), mapX(ar.points[2]), mapY(ar.points[3])]
            return .arrow(ar)
        case .stamp(var s):
            // keepRatio: grow/shrink the circle from its (unchanged) center.
            s.radius = max(4, max(nb.width, nb.height) / 2); return .stamp(s)
        case .marker(var m):
            m.radius = max(4, max(nb.width, nb.height) / 2); return .marker(m)
        default: return a // text isn't handle-resized
        }
    }

    /// Intersection-clamp a resized blur to the image (shrinking at an edge is
    /// the intended behavior for a RESIZE). Box/arrow overhang and are clipped by
    /// the bake. A degenerate (<1px) result keeps the incoming rect rather than
    /// vanishing — the user is actively dragging and sees the preview.
    private func storable(_ a: Annotation) -> Annotation {
        guard case .blur(var b) = a else { return a }
        let r = clampedToImage(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
        guard r.width >= 1, r.height >= 1 else { return a }
        b.x = r.minX; b.y = r.minY; b.width = r.width; b.height = r.height
        return .blur(b)
    }

    /// Keep a MOVED blur fully on-image by clamping its origin (size preserved),
    /// so a reposition near an edge never shrinks it or floats it off-image
    /// (both would expose pixels the user meant to redact). Non-blur passes
    /// through unchanged.
    private func clampBlurOrigin(_ a: Annotation) -> Annotation {
        guard case .blur(var b) = a else { return a }
        b.x = max(0, min(b.x, max(0, imageSize.width - b.width)))
        b.y = max(0, min(b.y, max(0, imageSize.height - b.height)))
        return .blur(b)
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        if dx == 0, dy == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Auto-redact (Vision OCR pre-scan)

    /// NOTE: intentionally NOT surfaced in the UI right now — the Auto-redact
    /// button was removed by design. This (and the injected `scanner` + the
    /// `scanning` save-gate) is kept wired for an easy future re-add; it is
    /// dormant, not dead. Re-add a button that calls this to re-enable it.
    func autoRedact() async {
        scanning = true
        defer { scanning = false }
        let rects = await scanner.scanForSensitiveRects(rawImage)
        Log.editor.info("auto-redact OCR scan found \(rects.count, privacy: .public) region(s)")
        for r in rects {
            // SOLID for auto-detected secrets — definitive, matching the Windows
            // app (a mosaic of a short token can be brute-legible; a hard fill
            // can't). The user can switch any region to pixelate afterward.
            annotations.append(.blur(BlurAnnotation(
                id: newAnnotationID(), x: r.x, y: r.y, width: r.width, height: r.height,
                mode: .solid, blockSize: AnnotationStyle.defaultBlockSize)))
        }
    }

    // MARK: - Save (flatten from the raw, bake the marker, persist)

    func save() async -> Bool {
        saving = true
        defer { saving = false }
        // Flush any open inline text edit BEFORE snapshotting — a Save while a
        // field is focused must not lose the typed text or bake an empty label.
        commitPendingText()
        // Defense-in-depth: never persist/bake an empty text label.
        annotations.removeAll {
            if case .text(let t) = $0 { return t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return false
        }
        let stepId = step.id // captured for logging (os.Logger interpolation needs it out of self)
        Log.editor.notice("save() started for step \(stepId, privacy: .public)")
        // Bake the (edited) click marker so the report/export/Claude see the
        // clicked spot; nil clickPoint = the marker was removed → no bake.
        let marker: Flatten.Marker? = clickPoint.map { p in
            Flatten.Marker(x: p.x, y: p.y, color: markerColor, radius: clickRadius.map { CGFloat($0) })
        }
        do {
            // Flatten off the main actor — crop + mosaic + PNG encode of a
            // Retina screenshot is CPU-heavy and would hitch the UI. CGImage is
            // immutable/thread-safe (boxed to cross the isolation boundary).
            let image = UncheckedSendable(rawImage)
            let anns = annotations
            let cropRect = crop
            let png = try await Task.detached(priority: .userInitiated) {
                try Flatten.toPNG(image: image.value, annotations: anns, crop: cropRect, marker: marker)
            }.value
            Log.editor.info("flatten produced PNG \(png.count, privacy: .public) bytes for step \(stepId, privacy: .public)")
            var patch = StepPatch()
            patch.annotations = annotations
            patch.crop = .set(crop)
            patch.markerBaked = (marker != nil)
            patch.markerColor = markerColor
            // Persist the click marker's edited position/radius, or remove it.
            if let p = clickPoint, var c = step.click {
                c.image = Point(x: p.x, y: p.y)
                c.radius = clickRadius
                patch.click = .set(c)
            } else if clickPoint == nil {
                patch.click = .set(nil) // removed
            }
            let manifest = try await store.updateStep(at: projectDir, stepId: stepId, patch: patch, flattenedPng: png)
            let newRev = manifest.steps.first { $0.id == stepId }?.renderRev ?? 0
            Log.editor.notice("flattened render written for step \(stepId, privacy: .public) renderRev=\(newRev, privacy: .public)")
            return true
        } catch {
            Log.editor.error("save failed for step \(stepId, privacy: .public) [\(String(describing: type(of: error)), privacy: .public)]: \(error.localizedDescription, privacy: .private)")
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// Carry an immutable, thread-safe value (a CGImage) across an isolation
/// boundary into a detached task. CGImage isn't formally Sendable but is safe
/// to read concurrently.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
