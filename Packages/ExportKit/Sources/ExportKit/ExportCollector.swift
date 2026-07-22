import Foundation
import ShotModel

/// THE shared step collector — the single fail-closed security choke point every
/// export format consumes (ported from export.ts collectSteps). For each shot it
/// routes through `resolveSendableRender` (never reads a raw shot for a step with
/// unbaked redaction/crop), verifies the render exists on disk, and bakes the
/// report's per-step zoom/pan into a static PNG crop. Numbering matches the
/// report: shots + non-empty text steps share a 1…N counter; callouts are
/// unnumbered; empty text steps are skipped (no number consumed).
func collectSteps(dir: String, manifest: ProjectManifest) throws -> [ExportItem] {
    var items: [ExportItem] = []
    var stepNo = 0

    for step in manifest.steps {
        if ReportPresentation.isCalloutStep(step), let kind = step.callout {
            let heading = (step.heading ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (step.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A note/caution/warning box is meaningful even when empty (the colored
            // box carries the signal), but an empty SECTION is just a stray divider
            // rule with no text — skip it (mirrors the empty plain-text-step skip).
            if kind == .section, heading.isEmpty, body.isEmpty { continue }
            // Callout — un-numbered.
            items.append(.callout(
                kind: CalloutKindExport(rawValue: kind.rawValue) ?? .note,
                heading: heading, body: body))
        } else if step.kind == .text {
            // Plain text step — skip when entirely empty (no number consumed).
            let heading = (step.heading ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (step.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if heading.isEmpty, body.isEmpty { continue }
            stepNo += 1
            items.append(.text(n: stepNo, heading: heading, body: body))
        } else {
            // Shot step — always numbered.
            stepNo += 1
            let label = "Step \(stepNo)"
            let render = try resolveSendableRender(dir: dir, step: step, stepLabel: label, verb: "export")
            // Extra safety net beyond the gate: a specific, actionable message
            // instead of an opaque failure mid-write if the render vanished.
            guard FileManager.default.fileExists(atPath: render.abs) else {
                throw ExportError.renderMissing(
                    step: label, rel: step.flattened?.isEmpty == false ? step.flattened! : step.screenshot)
            }
            // Bake the report zoom/pan as a static crop (nil = full render).
            let cropped = zoomCropPNG(
                path: render.abs,
                zoom: step.reportZoom ?? 1,
                panX: step.reportPanX ?? 0.5,
                panY: step.reportPanY ?? 0.5)
            let image = ExportImage(
                abs: render.abs,
                mediaType: cropped != nil ? "image/png" : render.mediaType.rawValue,
                ext: cropped != nil ? ".png" : ".\(render.ext)",
                croppedBytes: cropped)
            items.append(.shot(
                n: stepNo,
                caption: (step.caption).trimmingCharacters(in: .whitespacesAndNewlines),
                body: (step.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                note: (step.note).trimmingCharacters(in: .whitespacesAndNewlines),
                stepId: step.id,
                image: image))
        }
    }

    guard !items.isEmpty else { throw ExportError.nothingToExport }
    return items
}

/// Load an item's image bytes (the pre-cropped bytes if present, else the file).
func imageBytes(_ image: ExportImage) throws -> Data {
    if let b = image.croppedBytes { return b }
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: image.abs)) else {
        throw ExportError.imageReadFailed(step: image.abs)
    }
    return d
}
