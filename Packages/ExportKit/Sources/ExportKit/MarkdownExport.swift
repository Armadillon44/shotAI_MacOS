import Foundation
import ShotModel

/// Collapse internal newlines (and surrounding whitespace) to a single space —
/// used for headings/captions so a multi-line title stays a single Markdown ATX
/// heading. Mirrors the JS `.replace(/\s*\n\s*/g, ' ')`.
private func collapseHeading(_ s: String) -> String {
    s.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
}

/// Assemble the Markdown document, copying each image into a per-export
/// `<stem>-images/` folder next to the `.md`. Ported from export.ts buildMarkdown.
/// Only title / created-line / headings / captions are escapeMarkdown'd; all body
/// & note text is emitted RAW so authored Markdown renders. Returns the .md path.
func buildMarkdown(
    outDir: String, manifest: ProjectManifest, items: [ExportItem], stem: String, createdLine: String
) throws -> String {
    let fm = FileManager.default
    let imagesDirName = "\(stem)-images"
    let imagesDir = (outDir as NSString).appendingPathComponent(imagesDirName)
    // Per-export images dir (stem is unique) — wipe any prior contents first.
    try? fm.removeItem(atPath: imagesDir)
    do {
        try fm.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)
    } catch {
        throw ExportError.writeFailed(error.localizedDescription)
    }

    var lines: [String] = [
        "# \(escapeMarkdown(manifest.title))",
        "",
        "_\(escapeMarkdown(createdLine))_",
        "",
    ]
    if let intro = manifest.intro, !(intro.heading.isEmpty && intro.body.isEmpty) {
        if !intro.heading.isEmpty { lines.append("## \(escapeMarkdown(intro.heading))"); lines.append("") }
        if !intro.body.isEmpty { lines.append(intro.body); lines.append("") }
    }

    for (idx, it) in items.enumerated() {
        if idx > 0 { lines.append("---"); lines.append("") }  // separate steps (#40)
        switch it {
        case .callout(let kind, let heading, let body):
            // Blockquote: bold glyph (+ heading) first, then a ">" separator line
            // and the body (adjacent quoted lines would otherwise merge).
            let glyph = calloutGlyphExport(kind)
            lines.append("> **\(glyph)\(heading.isEmpty ? "" : " \(escapeMarkdown(heading))")**")
            if !body.isEmpty {
                lines.append(">")
                lines.append("> \(body.replacingOccurrences(of: "\n", with: "\n> "))")
            }
            lines.append("")

        case .text(let n, let heading, let body):
            if !heading.isEmpty {
                lines.append("## \(n). \(escapeMarkdown(collapseHeading(heading)))")
                lines.append("")
                if !body.isEmpty { lines.append(body); lines.append("") }
            } else if !body.isEmpty {
                // Bold number prefix — a bare "N. " line would render as a
                // renumbered ordered-list item.
                lines.append("**\(n).** \(body)")
                lines.append("")
            }

        case .shot(let n, let caption, let body, let note, let stepId, let image):
            let imgName = "step-\(String(format: "%02d", n))-\(stepId)\(image.ext)"
            let dest = (imagesDir as NSString).appendingPathComponent(imgName)
            do {
                if let bytes = image.croppedBytes {
                    try bytes.write(to: URL(fileURLWithPath: dest))
                } else {
                    try fm.copyItem(atPath: image.abs, toPath: dest)
                }
            } catch {
                throw ExportError.writeFailed(error.localizedDescription)
            }
            let heading = collapseHeading(caption.isEmpty ? "Step \(n)" : caption)
            lines.append("## \(n). \(escapeMarkdown(heading))")
            lines.append("")
            // Angle-bracket the path: the stem may contain spaces/parens.
            lines.append("![Screenshot for step \(n)](<\(imagesDirName)/\(imgName)>)")
            lines.append("")
            if !body.isEmpty { lines.append(body); lines.append("") }
            if !note.isEmpty { lines.append("> \(note.replacingOccurrences(of: "\n", with: "\n> "))"); lines.append("") }
        }
    }

    let outputPath = (outDir as NSString).appendingPathComponent("\(stem).md")
    do {
        try lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
    } catch {
        throw ExportError.writeFailed(error.localizedDescription)
    }
    return outputPath
}
