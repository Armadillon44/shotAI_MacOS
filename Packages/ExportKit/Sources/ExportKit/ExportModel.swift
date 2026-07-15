import Foundation

/// The export formats ExportKit can produce. (Native .docx/.pptx are out of
/// scope for now; html-plain is the "paste into Word/Docs" path.)
public enum ExportFormat: String, CaseIterable, Sendable {
    case html            // self-contained styled HTML, images inlined as data URIs
    case htmlPlain = "html-plain" // semantic-only HTML for pasting into Word/Docs
    case markdown        // .md + a sibling <stem>-images/ folder
    case pdf             // rendered from the styled HTML (X2)

    public var ext: String {
        switch self {
        case .html, .htmlPlain: ".html"
        case .markdown: ".md"
        case .pdf: ".pdf"
        }
    }

    /// The stem suffix (html-plain writes `<base>-plain.html` so it doesn't
    /// collide with the styled `<base>.html`).
    public var stemSuffix: String { self == .htmlPlain ? "-plain" : "" }
}

/// Where a document export is written.
public enum ExportDestination: Sendable {
    /// The project's own `export/` folder, auto-named with collision numbering
    /// (the historical default).
    case projectFolder
    /// A user-chosen location (e.g. from a Save dialog): write `<stem><ext>` (and,
    /// for Markdown, a sibling `<stem>-images/`) into `directory`, OVERWRITING an
    /// existing file of that name — the Save dialog already handled the overwrite
    /// prompt.
    case custom(directory: String, stem: String)
}

/// The suggested filename (with extension) for an export Save dialog. Matches the
/// auto-naming used for the project's `export/` folder, minus the collision
/// number — so "Save" in the default folder lands the same name it always would.
public func defaultExportFilename(title: String, format: ExportFormat) -> String {
    safeFileBase(title) + format.stemSuffix + format.ext
}

/// The next non-colliding export filename (with extension) for `directory`, so a
/// Save dialog defaults to "keep both" (numbered ` (1)`, ` (2)`, …) instead of
/// prompting to overwrite a previous export. For Markdown it also steps past an
/// existing `<stem>/` container or `<stem>-images/` folder, not just the `.md`.
public func availableExportFilename(inDirectory directory: String, title: String, format: ExportFormat) -> String {
    let base = safeFileBase(title) + format.stemSuffix
    let ext = format.ext
    let fm = FileManager.default
    func taken(_ stem: String) -> Bool {
        if fm.fileExists(atPath: (directory as NSString).appendingPathComponent(stem + ext)) { return true }
        if format == .markdown {
            if fm.fileExists(atPath: (directory as NSString).appendingPathComponent(stem)) { return true }
            if fm.fileExists(atPath: (directory as NSString).appendingPathComponent(stem + "-images")) { return true }
        }
        return false
    }
    var n = 0
    while true {
        let stem = n == 0 ? base : "\(base) (\(n))"
        if !taken(stem) { return stem + ext }
        n += 1
    }
}

/// The result of an export: which format + where the file landed.
public struct ExportResult: Sendable {
    public var format: ExportFormat
    public var outputPath: String
    public init(format: ExportFormat, outputPath: String) {
        self.format = format
        self.outputPath = outputPath
    }
}

public enum ExportError: Error, LocalizedError, Equatable {
    case nothingToExport
    case renderMissing(step: String, rel: String)
    case imageReadFailed(step: String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToExport:
            "This project has nothing to export yet — add a step first."
        case .renderMissing(let step, let rel):
            "\(step)'s screenshot render is missing from disk (\(rel)). Open it in the editor and save to re-bake the render, then export again."
        case .imageReadFailed(let step):
            "\(step)'s image could not be read."
        case .writeFailed(let msg):
            "Could not write the export: \(msg)"
        }
    }
}

/// The safe, resolved image for a shot step: an on-disk render path plus, when
/// the report is zoomed, the pre-cropped PNG bytes (which override the path). A
/// crop is always re-encoded PNG, so `mediaType`/`ext` flip to PNG then.
struct ExportImage {
    var abs: String
    var mediaType: String // "image/png" | "image/jpeg"
    var ext: String       // ".png" | ".jpg" | …
    var croppedBytes: Data?
}

/// One collected export unit — mirrors the Windows ExportItem union produced by
/// collectSteps (the single fail-closed collector all formats consume).
enum ExportItem {
    case shot(n: Int, caption: String, body: String, note: String, stepId: String, image: ExportImage)
    case text(n: Int, heading: String, body: String)
    case callout(kind: CalloutKindExport, heading: String, body: String)
}

/// The three callout kinds, re-exposed so ExportKit doesn't leak the ShotModel
/// enum through its item type. Mapped 1:1 from ShotModel.CalloutKind.
enum CalloutKindExport: String { case note, caution, warning }
