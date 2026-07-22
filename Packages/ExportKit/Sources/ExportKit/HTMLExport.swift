import Foundation
import ShotModel

/// The report stylesheet — ported character-for-character from export.ts DOC_CSS
/// so the HTML/PDF export renders identically to the Windows app. Trimmed of its
/// leading/trailing newline like the original `.trim()`.
let DOC_CSS = """
*{box-sizing:border-box}
html{-webkit-print-color-adjust:exact;print-color-adjust:exact}
body{margin:0;font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#1f2937;background:#fff;line-height:1.6}
.doc{max-width:820px;margin:0 auto;padding:40px 32px 64px}
.doc__title{font-size:1.9rem;line-height:1.25;margin:0 0 4px}
.doc__meta{color:#6b7280;font-size:.85rem;margin:0 0 28px}
.doc__intro{margin:0 0 28px;padding:14px 18px;border:1px solid #e7e4f2;border-left:4px solid #6344f1;border-radius:8px;background:#efeafe}
.doc__intro-eyebrow{text-transform:uppercase;letter-spacing:.6px;font-size:.7rem;font-weight:700;color:#6b7280;margin:0 0 6px}
.doc__intro-h{margin:0 0 6px;font-size:1.15rem}
.doc__intro-b{margin:0;color:#374151;white-space:pre-wrap}
.section{margin:26px 0}
.section__h{font-size:1.3rem;margin:0 0 6px;color:#111827}
.section__b{white-space:pre-wrap;margin:0}
.step{display:flex;gap:16px;margin:0 0 18px;align-items:flex-start;page-break-inside:avoid;break-inside:avoid}
.step__num{flex:0 0 auto;width:30px;height:30px;margin-top:14px;border-radius:50%;background:#6344f1;color:#fff;font-weight:600;display:flex;align-items:center;justify-content:center;font-size:.95rem}
.step__num--note{background:#ecfdf5;color:#065f46;border:1px solid #6ee7b7}
.step__num--caution{background:#fffbeb;color:#92400e;border:1px solid #fcd34d}
.step__num--warning{background:#fef2f2;color:#991b1b;border:1px solid #fca5a5}
.step__main{flex:1 1 auto;min-width:0;padding:14px 16px;border:1px solid #e7e4f2;border-radius:12px;background:#faf9ff}
.step__main--note{background:#ecfdf5;border-color:#6ee7b7;color:#065f46}
.step__main--caution{background:#fffbeb;border-color:#fcd34d;color:#92400e}
.step__main--warning{background:#fef2f2;border-color:#fca5a5;color:#991b1b}
.step__title{font-size:1.15rem;margin:0 0 10px}
.step__img{display:block;max-width:100%;height:auto;border:1px solid #e5e7eb;border-radius:8px}
.step__instr{margin:10px 0 0;white-space:pre-wrap;font-size:1.02rem}
.step--textonly .step__instr{margin-top:0}
.step__note{margin:8px 0 0;color:#6b7280;font-size:.92rem;white-space:pre-wrap}
.callout__h{display:block;font-weight:700;margin-bottom:.25rem}
.callout__b{white-space:pre-wrap}
.section{margin:28px 0 4px;padding-top:14px;border-top:2px solid #e7e4f2}
.section__h{font-size:1.2rem;font-weight:700;margin:0 0 4px;color:#191826}
.section__b{margin:0;color:#5a5772;white-space:pre-wrap}
@media print{.doc{max-width:none;padding:0 6px}.section{break-inside:avoid}}
"""

/// The rail-badge glyph for a callout — same mapping as shared/project CALLOUT_GLYPH.
func calloutGlyphExport(_ kind: CalloutKindExport) -> String {
    switch kind {
    case .note: "ℹ"
    case .caution: "⚠"
    case .warning: "⛔"
    case .section: ""
    }
}

/// Build the full self-contained styled HTML document (images inlined as base64
/// data: URIs). Ported from export.ts buildHtmlDoc.
func buildHtmlDoc(manifest: ProjectManifest, items: [ExportItem], createdLine: String) throws -> String {
    var parts: [String] = []
    for it in items {
        switch it {
        case .callout(let kind, let heading, let body):
            if kind == .section {
                // A section divider — a full-width phase heading, not a colored box.
                let h = heading.isEmpty ? "" : "<h2 class=\"section__h\">\(escapeHTML(heading))</h2>"
                let b = body.isEmpty ? "" : "<p class=\"section__b\">\(escapeHTML(body))</p>"
                parts.append("<section class=\"section\">\(h)\(b)</section>")
                break
            }
            // A colored glyph badge in the gutter + the tinted callout card (the
            // step__main itself is the colored box, matching the in-app report).
            let glyph = calloutGlyphExport(kind)
            let h = heading.isEmpty ? "" : "<strong class=\"callout__h\">\(escapeHTML(heading))</strong>"
            let b = body.isEmpty ? "" : "<div class=\"callout__b\">\(escapeHTML(body))</div>"
            parts.append(
                "<section class=\"step step--callout\">"
                + "<div class=\"step__num step__num--\(kind.rawValue)\">\(glyph)</div>"
                + "<div class=\"step__main step__main--\(kind.rawValue)\">\(h)\(b)</div>"
                + "</section>")

        case .text(let n, let heading, let body):
            // Plain text step — numbered like a step, no image. Center the body
            // against the badge when there's no heading (step--textonly).
            let th = heading.isEmpty ? "" : "<h2 class=\"step__title\">\(escapeHTML(heading))</h2>"
            let tb = body.isEmpty ? "" : "<p class=\"step__instr\">\(escapeHTML(body))</p>"
            let cls = heading.isEmpty ? "step step--textonly" : "step"
            parts.append(
                "<section class=\"\(cls)\">"
                + "<div class=\"step__num\">\(n)</div>"
                + "<div class=\"step__main\">\(th)\(tb)</div>"
                + "</section>")

        case .shot(let n, let caption, let body, let note, _, let image):
            let bytes = try imageBytes(image)
            let dataUri = "data:\(image.mediaType);base64,\(bytes.base64EncodedString())"
            let title = escapeHTML(caption.isEmpty ? "Step \(n)" : caption)
            let instr = body.isEmpty ? "" : "<p class=\"step__instr\">\(escapeHTML(body))</p>"
            let noteHtml = note.isEmpty ? "" : "<p class=\"step__note\">\(escapeHTML(note))</p>"
            parts.append(
                "<section class=\"step\">"
                + "<div class=\"step__num\">\(n)</div>"
                + "<div class=\"step__main\">"
                + "<h2 class=\"step__title\">\(title)</h2>"
                + "<img class=\"step__img\" src=\"\(dataUri)\" alt=\"Screenshot for step \(n)\">"
                + "\(instr)\(noteHtml)"
                + "</div>"
                + "</section>")
        }
    }

    let title = escapeHTML(manifest.title)
    var introHtml = ""
    if let intro = manifest.intro, !(intro.heading.isEmpty && intro.body.isEmpty) {
        introHtml = "<section class=\"doc__intro\">\n"
        introHtml += "<p class=\"doc__intro-eyebrow\">Overview</p>\n"  // eyebrow, matching the report
        if !intro.heading.isEmpty {
            introHtml += "<h2 class=\"doc__intro-h\">\(escapeHTML(intro.heading))</h2>\n"
        }
        if !intro.body.isEmpty {
            let b = escapeHTML(intro.body).replacingOccurrences(of: "\n", with: "<br>")
            introHtml += "<p class=\"doc__intro-b\">\(b)</p>\n"
        }
        introHtml += "</section>\n"
    }

    return "<!doctype html>\n<html lang=\"en\">\n<head>\n"
        + "<meta charset=\"utf-8\">\n"
        + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        + "<title>\(title)</title>\n"
        + "<style>\(DOC_CSS)</style>\n"
        + "</head>\n<body>\n<main class=\"doc\">\n"
        + "<h1 class=\"doc__title\">\(title)</h1>\n"
        + "<p class=\"doc__meta\">\(escapeHTML(createdLine))</p>\n"
        + introHtml
        + parts.joined(separator: "\n")
        + "\n</main>\n</body>\n</html>\n"
}

/// Minimal Arial stylesheet for the plain "HTML (for Word/Docs)" export — enough
/// to read well on its own while staying paste-friendly (Word / Google Docs honor
/// these basic tags + styles). Ported from the Windows app's PLAIN_CSS (shotAI PR
/// #42); keep the two in sync.
let PLAIN_CSS = """
body{font-family:Arial,Helvetica,sans-serif;color:#1f2937;line-height:1.5;max-width:800px;margin:24px auto;padding:0 20px}
h1{font-size:1.8rem;font-weight:700;margin:0 0 .3rem}
h2{font-size:1.2rem;font-weight:700;margin:1.3rem 0 .4rem}
p{margin:.5rem 0}
strong{font-weight:700}
img{max-width:100%;height:auto}
blockquote{margin:1rem 0;padding:.4rem .85rem;border-left:3px solid #cbd5e1;color:#374151}
hr{border:0;border-top:1px solid #e5e7eb;margin:1.4rem 0}
"""

/// Simple, lightly-styled standalone HTML for Word / Google Docs: semantic tags
/// (h1/h2/p/img/blockquote/strong/hr) + the minimal Arial `PLAIN_CSS` for readable
/// headers, bold, and spacing — images inlined as data: URIs. The markup stays
/// class/inline-style-free so it still pastes cleanly (the destination editor's
/// tools work on it). Ported from export.ts buildPlainHtmlDoc.
func buildPlainHtmlDoc(manifest: ProjectManifest, items: [ExportItem]) throws -> String {
    func br(_ s: String) -> String { escapeHTML(s).replacingOccurrences(of: "\n", with: "<br>") }
    var parts: [String] = ["<h1>\(escapeHTML(manifest.title))</h1>"]
    if let intro = manifest.intro, !(intro.heading.isEmpty && intro.body.isEmpty) {
        if !intro.heading.isEmpty { parts.append("<h2>\(escapeHTML(intro.heading))</h2>") }
        if !intro.body.isEmpty { parts.append("<p>\(br(intro.body))</p>") }
    }
    for (idx, it) in items.enumerated() {
        if idx > 0 { parts.append("<hr>") }  // separate steps from one another (#40)
        switch it {
        case .callout(let kind, let heading, let body):
            if kind == .section {
                // Section divider → a plain heading (no number, no glyph, no box).
                if !heading.isEmpty { parts.append("<h2>\(escapeHTML(heading))</h2>") }
                if !body.isEmpty { parts.append("<p>\(br(body))</p>") }
                break
            }
            let glyph = calloutGlyphExport(kind)
            let h = "<strong>\(glyph)\(heading.isEmpty ? "" : " \(escapeHTML(heading))")</strong>"
            let b = body.isEmpty ? "" : br(body)
            let sep = b.isEmpty ? "" : "<br>"
            parts.append("<blockquote><p>\(h)\(sep)\(b)</p></blockquote>")

        case .text(let n, let heading, let body):
            let num = "\(n). "
            if !heading.isEmpty {
                parts.append("<h2>\(num)\(escapeHTML(heading))</h2>")
                if !body.isEmpty { parts.append("<p>\(br(body))</p>") }
            } else if !body.isEmpty {
                parts.append("<p>\(num)\(br(body))</p>")
            }

        case .shot(let n, let caption, let body, let note, _, let image):
            let bytes = try imageBytes(image)
            let dataUri = "data:\(image.mediaType);base64,\(bytes.base64EncodedString())"
            parts.append("<h2>\(n). \(escapeHTML(caption.isEmpty ? "Step \(n)" : caption))</h2>")
            parts.append("<p><img src=\"\(dataUri)\" alt=\"Screenshot for step \(n)\"></p>")
            if !body.isEmpty { parts.append("<p>\(br(body))</p>") }
            if !note.isEmpty { parts.append("<p><em>\(br(note))</em></p>") }
        }
    }
    return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        + "<title>\(escapeHTML(manifest.title))</title>\n"
        + "<style>\(PLAIN_CSS)</style>\n</head>\n<body>\n"
        + parts.joined(separator: "\n")
        + "\n</body>\n</html>\n"
}
