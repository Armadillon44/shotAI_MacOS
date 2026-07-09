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
    enum Tool: String, CaseIterable { case select, box, arrow, redact, crop }

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
        // read boldly on large captures (matches the Windows editor on load).
        self.strokeWidth = Double(AnnotationStyle.defaultStrokeWidth(
            width: imageSize.width, height: imageSize.height))
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

    // MARK: - Selection & editing (all editable shape types)

    private var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return annotations.firstIndex { $0.id == id }
    }

    /// Bounding rect (image px) of an editable annotation — for hit-testing,
    /// selection handles, and resize. nil for types E1 doesn't edit yet
    /// (stamp / marker / text stay preview-only until E2).
    func bounds(of a: Annotation) -> CGRect? {
        switch a {
        case .rect(let r): return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        case .blur(let b): return CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
        case .arrow(let ar) where ar.points.count == 4:
            return normalizedPositive(CGRect(
                x: ar.points[0], y: ar.points[1],
                width: ar.points[2] - ar.points[0], height: ar.points[3] - ar.points[1]))
        default: return nil
        }
    }

    func boundsOfSelected() -> CGRect? {
        guard let i = selectedIndex else { return nil }
        return bounds(of: annotations[i])
    }

    /// The selected annotation, or nil.
    var selected: Annotation? {
        guard let i = selectedIndex else { return nil }
        return annotations[i]
    }

    /// Whether the selection exposes the color + stroke-width controls.
    var selectedIsColorable: Bool {
        switch selected { case .rect, .arrow: return true; default: return false }
    }

    var selectedIsBlur: Bool {
        if case .blur = selected { return true }
        return false
    }

    /// Select the topmost editable annotation under `point` (image px), syncing
    /// the style controls to it. Deselects if nothing editable is hit.
    func selectAnnotation(at point: CGPoint) {
        for a in annotations.reversed() where hitTest(a, point) {
            selectedID = a.id
            switch a {
            case .rect(let r): strokeColor = r.stroke; strokeWidth = r.strokeWidth
            case .arrow(let ar): strokeColor = ar.stroke; strokeWidth = ar.strokeWidth
            case .blur(let b): redactMode = b.mode; redactBlock = b.blockSize
            default: break
            }
            return
        }
        selectedID = nil
    }

    private func hitTest(_ a: Annotation, _ p: CGPoint) -> Bool {
        switch a {
        case .rect, .blur:
            return bounds(of: a)?.contains(p) ?? false
        case .arrow(let ar) where ar.points.count == 4:
            let d = distanceToSegment(p,
                CGPoint(x: ar.points[0], y: ar.points[1]),
                CGPoint(x: ar.points[2], y: ar.points[3]))
            return d <= max(ar.strokeWidth, 10) // fat hit band so thin arrows are grabbable
        default:
            return false
        }
    }

    /// Translate the selected annotation by (dx, dy), starting from `original`
    /// (the snapshot taken at drag start). Blur stays clamped to the image;
    /// box/arrow may overhang (the bake clips them), matching Windows.
    func moveSelected(_ original: Annotation, dx: CGFloat, dy: CGFloat) {
        guard let i = selectedIndex else { return }
        annotations[i] = storable(translate(original, dx: dx, dy: dy))
    }

    /// Resize the selected annotation to `newBounds`, scaling `original`'s
    /// geometry from its own bounds.
    func resizeSelected(_ original: Annotation, to newBounds: CGRect) {
        guard let i = selectedIndex, let ob = bounds(of: original) else { return }
        annotations[i] = storable(scale(original, to: newBounds, from: ob))
    }

    func setSelectedColor(_ hex: String) {
        guard let i = selectedIndex else { return }
        switch annotations[i] {
        case .rect(var r): r.stroke = hex; annotations[i] = .rect(r)
        case .arrow(var ar): ar.stroke = hex; annotations[i] = .arrow(ar)
        default: break
        }
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
        default: return a
        }
    }

    /// Redaction must stay on-image (off-image blur is dropped at bake, leaking
    /// pixels); box/arrow may overhang and are clipped by the bake.
    private func storable(_ a: Annotation) -> Annotation {
        guard case .blur(var b) = a else { return a }
        let r = clampedToImage(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
        guard r.width >= 1, r.height >= 1 else { return a }
        b.x = r.minX; b.y = r.minY; b.width = r.width; b.height = r.height
        return .blur(b)
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        if dx == 0, dy == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Auto-redact (Vision OCR pre-scan)

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
        let stepId = step.id // captured for logging (os.Logger interpolation needs it out of self)
        Log.editor.notice("save() started for step \(stepId, privacy: .public)")
        // Bake the step's click marker so the report/export/Claude all see the
        // clicked spot and the report won't double-draw its overlay.
        let marker: Flatten.Marker? = step.click.map { click in
            Flatten.Marker(x: click.image.x, y: click.image.y,
                           color: AnnotationStyle.markerColor(for: step),
                           radius: click.radius.map { CGFloat($0) })
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
