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
    enum Tool: String, CaseIterable { case select, redact, crop }

    let step: ProjectStep
    let projectDir: String
    let rawImage: CGImage
    /// Image pixel size — the coordinate space of annotations/crop/click.image.
    let imageSize: CGSize

    var annotations: [Annotation]
    var crop: Rect?
    var tool: Tool = .redact
    var redactMode: BlurAnnotation.Mode = .pixelate
    var redactBlock: Double = AnnotationStyle.defaultBlockSize
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
        else { return nil }
        self.step = step
        self.projectDir = projectDir
        self.rawImage = cg
        self.imageSize = CGSize(width: cg.width, height: cg.height)
        self.annotations = step.annotations
        self.crop = step.crop
        self.store = store
        self.scanner = scanner
    }

    // MARK: - Redaction editing (the editable subset in C4a)

    /// The index of the selected blur annotation, if the selection is a blur.
    private var selectedBlurIndex: Int? {
        guard let id = selectedID else { return nil }
        return annotations.firstIndex { $0.id == id && isBlur($0) }
    }

    private func isBlur(_ a: Annotation) -> Bool {
        if case .blur = a { return true }
        return false
    }

    /// Add a redaction over `rect` (image px) with the current style; select it.
    func addRedaction(_ rect: CGRect) {
        let id = newAnnotationID()
        annotations.append(.blur(BlurAnnotation(
            id: id, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height,
            mode: redactMode, blockSize: redactBlock)))
        selectedID = id
    }

    /// Topmost blur containing `point` (image px) — selection hit-test.
    func selectBlur(at point: CGPoint) {
        for a in annotations.reversed() {
            if case .blur(let b) = a,
               CGRect(x: b.x, y: b.y, width: b.width, height: b.height).contains(point) {
                selectedID = b.id
                return
            }
        }
        selectedID = nil
    }

    func rectOfSelected() -> CGRect? {
        guard let i = selectedBlurIndex, case .blur(let b) = annotations[i] else { return nil }
        return CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
    }

    /// Replace the selected blur's rect (image px), clamped to sane minimums.
    func setSelectedRect(_ rect: CGRect) {
        guard let i = selectedBlurIndex, case .blur(var b) = annotations[i] else { return }
        b.x = rect.minX
        b.y = rect.minY
        b.width = max(1, rect.width)
        b.height = max(1, rect.height)
        annotations[i] = .blur(b)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        annotations.removeAll { $0.id == id && isBlur($0) }
        selectedID = nil
    }

    /// Apply the current style controls to the selected blur (or they apply to
    /// the next one created).
    func applyStyleToSelected() {
        guard let i = selectedBlurIndex, case .blur(var b) = annotations[i] else { return }
        b.mode = redactMode
        b.blockSize = redactBlock
        annotations[i] = .blur(b)
    }

    // MARK: - Auto-redact (Vision OCR pre-scan)

    func autoRedact() async {
        scanning = true
        defer { scanning = false }
        let rects = await scanner.scanForSensitiveRects(rawImage)
        for r in rects {
            annotations.append(.blur(BlurAnnotation(
                id: newAnnotationID(), x: r.x, y: r.y, width: r.width, height: r.height,
                mode: .pixelate, blockSize: AnnotationStyle.defaultBlockSize)))
        }
    }

    // MARK: - Save (flatten from the raw, bake the marker, persist)

    func save() async -> Bool {
        saving = true
        defer { saving = false }
        // Bake the step's click marker so the report/export/Claude all see the
        // clicked spot and the report won't double-draw its overlay.
        let marker: Flatten.Marker? = step.click.map { click in
            Flatten.Marker(x: click.image.x, y: click.image.y,
                           color: AnnotationStyle.markerColor(for: step),
                           radius: click.radius.map { CGFloat($0) })
        }
        do {
            let png = try Flatten.toPNG(image: rawImage, annotations: annotations, crop: crop, marker: marker)
            var patch = StepPatch()
            patch.annotations = annotations
            patch.crop = .set(crop)
            patch.markerBaked = (marker != nil)
            _ = try await store.updateStep(at: projectDir, stepId: step.id, patch: patch, flattenedPng: png)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
