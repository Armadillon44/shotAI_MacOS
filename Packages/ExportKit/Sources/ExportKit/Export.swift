import Foundation
import ShotModel

/// Build the document footer line: "Created on <datetime>", plus " by <name>"
/// when the caller supplies a byline (the app gates that on a future opt-in
/// display-name setting; for now it passes nil). Split out for unit testing with
/// a fixed date.
func buildCreatedLine(generatedAt: Date, byline: String?) -> String {
    let df = DateFormatter()
    df.dateStyle = .short
    df.timeStyle = .short
    let stamp = df.string(from: generatedAt)
    if let byline, !byline.isEmpty { return "Created on \(stamp) by \(byline)" }
    return "Created on \(stamp)"
}

/// Export a project to `format` under `<dir>/export/`, returning the written path.
///
/// The caller is expected to have flattened all shot steps first (so every render
/// is current, redaction-baked, and marker-baked). `collectSteps` is the shared
/// fail-closed gate: a shot with an unbaked redaction/crop is REFUSED here rather
/// than falling back to the raw screenshot.
///
/// - dir: the resolved, project-confined folder (contains project.json + shots/).
/// - manifest: the freshly-loaded manifest for `dir`.
/// - byline: optional author name for the footer (nil = date only).
public func exportProject(
    dir: String,
    manifest: ProjectManifest,
    format: ExportFormat,
    byline: String? = nil,
    generatedAt: Date = Date(),
    to destination: ExportDestination = .projectFolder
) async throws -> ExportResult {
    let items = try collectSteps(dir: dir, manifest: manifest)
    let createdLine = buildCreatedLine(generatedAt: generatedAt, byline: byline)

    // Resolve the target directory + filename stem. `.projectFolder` keeps the
    // historical export/ + collision-numbered naming; `.custom` writes exactly
    // where the user chose (overwriting — the Save dialog owns that prompt).
    let outDir: String
    let stem: String
    switch destination {
    case .projectFolder:
        outDir = (dir as NSString).appendingPathComponent("export")
        let base = safeFileBase(manifest.title)
        stem = nextAvailableStem(exportDir: outDir, stem: base + format.stemSuffix, ext: format.ext)
    case .custom(let directory, let chosenStem):
        outDir = directory
        stem = chosenStem
    }
    do {
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    } catch {
        throw ExportError.writeFailed(error.localizedDescription)
    }

    let outputPath: String
    switch format {
    case .markdown:
        outputPath = try buildMarkdown(outDir: outDir, manifest: manifest, items: items, stem: stem, createdLine: createdLine)

    case .htmlPlain:
        let html = try buildPlainHtmlDoc(manifest: manifest, items: items)
        outputPath = (outDir as NSString).appendingPathComponent("\(stem).html")
        try writeText(html, to: outputPath)

    case .html:
        let html = try buildHtmlDoc(manifest: manifest, items: items, createdLine: createdLine)
        outputPath = (outDir as NSString).appendingPathComponent("\(stem).html")
        try writeText(html, to: outputPath)

    case .pdf:
        outputPath = (outDir as NSString).appendingPathComponent("\(stem).pdf")
        // Native CoreText/CG renderer — NOT WKWebView printing, which hangs the
        // main thread in WebKit's print pagination (see PdfExport.swift).
        try renderPdf(title: manifest.title, createdLine: createdLine,
                      intro: manifest.intro, items: items, outputPath: outputPath)
    }

    return ExportResult(format: format, outputPath: outputPath)
}

private func writeText(_ s: String, to path: String) throws {
    do {
        try s.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        throw ExportError.writeFailed(error.localizedDescription)
    }
}
