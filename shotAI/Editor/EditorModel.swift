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
    }

    /// Set (or clear) the crop, clamped to the image bounds.
    func setCrop(_ rect: CGRect?) {
        guard let rect else { crop = nil; return }
        let r = clampedToImage(rect)
        crop = (r.width >= 1 && r.height >= 1) ? Rect(x: r.minX, y: r.minY, width: r.width, height: r.height) : nil
    }

    /// Topmost blur containing `point` (image px) — selection hit-test. Syncs
    /// the style controls to the selected blur so the picker reflects it and
    /// toggling mode doesn't clobber its block size.
    func selectBlur(at point: CGPoint) {
        for a in annotations.reversed() {
            if case .blur(let b) = a,
               CGRect(x: b.x, y: b.y, width: b.width, height: b.height).contains(point) {
                selectedID = b.id
                redactMode = b.mode
                redactBlock = b.blockSize
                return
            }
        }
        selectedID = nil
    }

    func rectOfSelected() -> CGRect? {
        guard let i = selectedBlurIndex, case .blur(let b) = annotations[i] else { return nil }
        return CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
    }

    /// Replace the selected blur's rect (image px), clamped to the image so a
    /// move/resize can't push it off-image (where it would be dropped at bake).
    func setSelectedRect(_ rect: CGRect) {
        guard let i = selectedBlurIndex, case .blur(var b) = annotations[i] else { return }
        let r = clampedToImage(rect)
        guard r.width >= 1, r.height >= 1 else { return }
        b.x = r.minX
        b.y = r.minY
        b.width = r.width
        b.height = r.height
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

/// Carry an immutable, thread-safe value (a CGImage) across an isolation
/// boundary into a detached task. CGImage isn't formally Sendable but is safe
/// to read concurrently.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
