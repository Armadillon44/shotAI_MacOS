import Foundation
import ImageIO
import ShotModel

/// The width a step image is ever DISPLAYED at in either HTML export: the step
/// card's content column, `.doc__col` 816 − 30 (badge) − 16 (gap) − 32 (card
/// padding) = 738px (see DOC_CSS). **Keep in sync with DOC_CSS.**
///
/// Both exporters now also RESAMPLE the embedded pixels to this width (#64).
/// They inline images as base64 data URIs, so shipping the full render meant
/// ~3x more pixels than are ever shown plus base64's ~33% overhead — a 20-step
/// SOP came to ~5.4 MB, which is painful to copy out of a browser into another
/// system. At 738px that drops to ~2.0 MB. Measured: resampling to 2x (1476px)
/// saves nothing at all (interpolation blurs the flat colour runs screenshots are
/// made of, and PNG compresses the result worse), so 1x is the only size that
/// actually reduces the payload. The tradeoff is accepted: on a Retina display
/// the browser upscales 738 CSS px to 1476 device px, so exported images read
/// slightly softer than the in-app report.
///
/// The plain / Word-paste export ALSO needs explicit width/height attributes,
/// because Word and Google Docs drop CSS `max-width` on paste.
///
/// SCALED per project since #83. The ceiling is RE-DERIVED from the scaled
/// column, never multiplied: the chrome subtracted from it (badge, gap, padding)
/// is a constant that does not scale, so `DocScale.htmlImageMax(s)` and
/// `738 * s` agree ONLY at s == 1 — which is exactly what would let the wrong
/// version pass a spot check.
let htmlExportImageMaxWidth = 738

/// AVIF quality for the styled export. 0.85 measured indistinguishable from
/// lossless on UI text at 4x magnification while still ~9x smaller than PNG.
private let htmlExportAvifQuality = 0.85

/// Which codec an HTML variety inlines its images as.
private enum HtmlImageCodec {
    /// Styled HTML: read in a browser, so AVIF is safe and much smaller (#64).
    case avif
    /// Plain / Word-paste HTML: **must stay PNG** — Word cannot read AVIF.
    case png
}

/// The bytes + media type to inline for a step image: the collector's sendable
/// (redaction-baked, and already zoom/pan-cropped) render, resampled down to the
/// display width, then encoded for the target variety.
///
/// Every step degrades safely. If the resample finds nothing to shrink (a capture
/// already narrower than the column) the original bytes are used; if AVIF can't be
/// written on this system or the encode fails, the PNG bytes are used. The worst
/// case is the previous behavior, never a wrong or missing image.
///
/// Runs strictly AFTER the fail-closed render gate, on baked pixels — resampling
/// and re-encoding can only destroy information, never recover a redacted region.
private func htmlImageBytes(
    _ image: ExportImage, codec: HtmlImageCodec, maxWidth: Int
) throws -> (bytes: Data, mediaType: String) {
    let original = try imageBytes(image)
    // Resample to the display width first; nil means it was already small enough.
    // NB `downscalePNG` never UPSCALES, which is correct and stays that way: at
    // scale > 1 a capture already narrower than the target keeps its own
    // resolution and the browser stretches it, rather than us inventing pixels.
    let resampled = downscalePNG(original, maxWidth: maxWidth)
    let sized = resampled ?? original
    let sizedType = resampled != nil ? "image/png" : image.mediaType
    guard codec == .avif,
          let avif = encodeAVIF(sized, quality: htmlExportAvifQuality)
    else { return (sized, sizedType) }
    return (avif, "image/avif")
}

/// ` width="W" height="H"` for an inlined image, measured from the bytes actually
/// being inlined (so it reflects the post-resample size), or "" if unreadable.
///
/// BOTH HTML varieties emit these as **attributes**, not CSS, because a rich-text
/// destination (a Freshservice KB article, Word, Docs) drops the `<style>` block.
/// Word specifically NEEDS them: it ignores `max-width` on paste and would lay a
/// capture out at full pixel size without them.
///
/// Measured caveat, so nobody re-derives it: attributes are NOT what keeps a pasted
/// step card from going full width. With the stylesheet stripped, an `<img>` with no
/// width constraint already renders at its intrinsic 738px — it was the CARD that
/// expanded, and that is fixed separately by the `.doc__col` wrapper (see
/// buildHtmlDoc). A probe against a real Freshservice article also ruled OUT
/// table-based layout for that job: `<table width="880">`, a `width` attribute on
/// the `<td>`, and `<center>` + table all came back FULL WIDTH, because the
/// destination forces `table{width:100%}`. Do not reach for tables here.
///
/// In a browser the CSS still wins for shrinking (`max-width:100%;height:auto`), so
/// the export stays responsive on a narrow window; the attributes only set the
/// intrinsic size, which also avoids layout shift while the data URI decodes.
private func htmlImageSizeAttributes(_ bytes: Data, maxWidth: Int) -> String {
    guard let px = imagePixelDimensions(bytes) else { return "" }
    let scale = min(1.0, Double(maxWidth) / Double(px.w))
    return " width=\"\(Int((Double(px.w) * scale).rounded()))\""
        + " height=\"\(Int((Double(px.h) * scale).rounded()))\""
}

/// The image's pixel dimensions, read from its metadata without decoding pixels.
private func imagePixelDimensions(_ data: Data) -> (w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0 else { return nil }
    return (w, h)
}

/// The report stylesheet — ported from export.ts DOC_CSS so the HTML export renders
/// like the Windows app. Trimmed of its leading/trailing newline like `.trim()`.
///
/// **The 816px column is repeated on EVERY top-level block, deliberately** — read
/// this before "simplifying" it back onto the `.doc__col` wrapper (#64).
///
/// Pasting this document into a Freshservice KB article (Froala) does three things,
/// confirmed by reading the article's Code View afterwards:
///   1. it UNWRAPS wrappers that enclose the whole document — both `div.doc` and
///      `div.doc__col` were gone, the body started straight at `h1.doc__title`. So a
///      wrapper can never carry the width; two attempts at that failed.
///   2. it KEEPS every other element and inlines its computed styles, including
///      `.step{display:flex}` and `.step__main{flex:1 1 auto}` — that `flex-grow` is
///      what stretched the card to the editor's full width.
///   3. it strips `max-width` from `<img>` and adds its own `fr-fic fr-dib` classes,
///      which is why the image size lives in width/height ATTRIBUTES instead.
///
/// So each block self-constrains and self-centers, and the document lays out the
/// same whether it is read as a file or pasted. `.section` keeps its rule aligned
/// with the card (not the number gutter) via `.section__inner`, because INNER
/// elements do survive — only whole-document wrappers are flattened.
/// Layout tables are also ruled out: the destination forces `table{width:100%}`.
func docCSS(scale: Double = 1.0) -> String {
    let col = DocScale.htmlColumn(scale)
    return """
*{box-sizing:border-box}
html{-webkit-print-color-adjust:exact;print-color-adjust:exact}
body{margin:0;font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:#1f2937;background:#fff;line-height:1.6}
.doc{padding:40px 32px 64px}
.doc__col{max-width:\(col)px;margin:0 auto}
.doc__title{max-width:\(col)px;margin:0 auto 4px;font-size:1.9rem;line-height:1.25}
.doc__meta{max-width:\(col)px;margin:0 auto 28px;color:#6b7280;font-size:.85rem}
.doc__intro{max-width:\(col)px;margin:0 auto 28px;padding:14px 18px;border:1px solid #e7e4f2;border-left:4px solid #6344f1;border-radius:8px;background:#efeafe}
.doc__intro-eyebrow{text-transform:uppercase;letter-spacing:.6px;font-size:.7rem;font-weight:700;color:#6b7280;margin:0 0 6px}
.doc__intro-h{margin:0 0 6px;font-size:1.15rem}
.doc__intro-b{margin:0;color:#374151;white-space:pre-wrap}
.step{display:flex;gap:16px;max-width:\(col)px;margin:0 auto 18px;align-items:flex-start;page-break-inside:avoid;break-inside:avoid}
.step__num{flex:0 0 auto;width:30px;height:30px;margin-top:14px;border-radius:50%;background:#6344f1;color:#fff;font-weight:600;display:flex;align-items:center;justify-content:center;font-size:.95rem}
.step__num--note{background:#ecfdf5;color:#065f46;border:1px solid #6ee7b7}
.step__num--caution{background:#fffbeb;color:#92400e;border:1px solid #fcd34d}
.step__num--warning{background:#fef2f2;color:#991b1b;border:1px solid #fca5a5}
.step__main{flex:1 1 auto;min-width:0;padding:14px 16px;border:1px solid #e7e4f2;border-radius:12px;background:#faf9ff}
.step__main--note{background:#ecfdf5;border-color:#6ee7b7;color:#065f46}
.step__main--caution{background:#fffbeb;border-color:#fcd34d;color:#92400e}
.step__main--warning{background:#fef2f2;border-color:#fca5a5;color:#991b1b}
.step__title{font-size:1.15rem;margin:0 0 10px}
.step__img{display:block;max-width:100%;height:auto;margin-inline:auto;border:1px solid #e5e7eb;border-radius:8px}
.step__instr{margin:10px 0 0;white-space:pre-wrap;font-size:1.02rem}
.step--textonly .step__instr{margin-top:0}
.step__note{margin:8px 0 0;color:#6b7280;font-size:.92rem;white-space:pre-wrap}
.callout__h{display:block;font-weight:700;margin-bottom:.25rem}
.callout__b{white-space:pre-wrap}
.section{max-width:\(col)px;margin:28px auto 4px;padding-left:46px}
.section__inner{padding:14px 16px 0;border-top:2px solid #e7e4f2}
.section__h{font-size:1.2rem;font-weight:700;margin:0 0 4px;color:#191826}
.section__b{margin:0;color:#5a5772;white-space:pre-wrap}
@media print{.doc{padding:0 6px}.doc__col,.doc__title,.doc__meta,.doc__intro,.step,.section{max-width:none}.section{break-inside:avoid}}
"""
}

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
    // One read, used for the stylesheet, the resample target and the width
    // attributes — so a scaled column and its images cannot drift apart (#83).
    let scale = DocScale.of(manifest)
    let imgMax = DocScale.htmlImageMax(scale)
    var parts: [String] = []
    for it in items {
        switch it {
        case .callout(let kind, let heading, let body):
            if kind == .section {
                // A section divider — a full-width phase heading, not a colored box.
                let h = heading.isEmpty ? "" : "<h2 class=\"section__h\">\(escapeHTML(heading))</h2>"
                let b = body.isEmpty ? "" : "<p class=\"section__b\">\(escapeHTML(body))</p>"
                parts.append("<section class=\"section\"><div class=\"section__inner\">"
                    + "\(h)\(b)</div></section>")
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
            let (bytes, mediaType) = try htmlImageBytes(image, codec: .avif, maxWidth: imgMax)
            let dataUri = "data:\(mediaType);base64,\(bytes.base64EncodedString())"
            let title = escapeHTML(caption.isEmpty ? "Step \(n)" : caption)
            let instr = body.isEmpty ? "" : "<p class=\"step__instr\">\(escapeHTML(body))</p>"
            let noteHtml = note.isEmpty ? "" : "<p class=\"step__note\">\(escapeHTML(note))</p>"
            parts.append(
                "<section class=\"step\">"
                + "<div class=\"step__num\">\(n)</div>"
                + "<div class=\"step__main\">"
                + "<h2 class=\"step__title\">\(title)</h2>"
                + "<img class=\"step__img\" src=\"\(dataUri)\"\(htmlImageSizeAttributes(bytes, maxWidth: imgMax))"
                + " alt=\"Screenshot for step \(n)\">"
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
        + "<style>\(docCSS(scale: scale))</style>\n"
        // Two nested plain DIVs, deliberately (#64). A pasted copy of this document
        // must keep its column width, and empirically it did not: the outer wrapper
        // was a `<main>` carrying `max-width`, and after a paste the steps went full
        // width. A probe showed a NESTED `<div>` with the same constraint survives,
        // so both suspected causes are avoided at once — `<main>` (semantic tags are
        // commonly off a sanitizer's allowlist) and relying on the OUTERMOST element
        // (which a paste can unwrap). `.doc` now only pads; `.doc__col` carries the
        // width, one level in, so it survives either failure.
        + "</head>\n<body>\n<div class=\"doc\">\n<div class=\"doc__col\">\n"
        + "<h1 class=\"doc__title\">\(title)</h1>\n"
        + "<p class=\"doc__meta\">\(escapeHTML(createdLine))</p>\n"
        + introHtml
        + parts.joined(separator: "\n")
        + "\n</div>\n</div>\n</body>\n</html>\n"
}

/// Minimal Arial stylesheet for the plain "HTML (for Word/Docs)" export — enough
/// to read well on its own while staying paste-friendly (Word / Google Docs honor
/// these basic tags + styles). Ported from the Windows app's PLAIN_CSS (shotAI PR
/// #42); keep the two in sync.
func plainCSS(scale: Double = 1.0) -> String {
    let body = DocScale.plainBody(scale)
    return """
body{font-family:Arial,Helvetica,sans-serif;color:#1f2937;line-height:1.5;max-width:\(body)px;margin:24px auto;padding:0 20px}
h1{font-size:1.8rem;font-weight:700;margin:0 0 .3rem}
h2{font-size:1.2rem;font-weight:700;margin:1.3rem 0 .4rem}
p{margin:.5rem 0}
strong{font-weight:700}
img{max-width:100%;height:auto}
blockquote{margin:1rem 0;padding:.4rem .85rem;border-left:3px solid #cbd5e1;color:#374151}
hr{border:0;border-top:1px solid #e5e7eb;margin:1.4rem 0}
"""
}

/// Simple, lightly-styled standalone HTML for Word / Google Docs: semantic tags
/// (h1/h2/p/img/blockquote/strong/hr) + the minimal Arial `PLAIN_CSS` for readable
/// headers, bold, and spacing — images inlined as data: URIs. The markup stays
/// class/inline-style-free so it still pastes cleanly (the destination editor's
/// tools work on it). Ported from export.ts buildPlainHtmlDoc.
func buildPlainHtmlDoc(manifest: ProjectManifest, items: [ExportItem]) throws -> String {
    let scale = DocScale.of(manifest)
    let imgMax = DocScale.htmlImageMax(scale)
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
            let (bytes, mediaType) = try htmlImageBytes(image, codec: .png, maxWidth: imgMax)
            let dataUri = "data:\(mediaType);base64,\(bytes.base64EncodedString())"
            parts.append("<h2>\(n). \(escapeHTML(caption.isEmpty ? "Step \(n)" : caption))</h2>")
            parts.append("<p><img src=\"\(dataUri)\"\(htmlImageSizeAttributes(bytes, maxWidth: imgMax))"
                + " alt=\"Screenshot for step \(n)\"></p>")
            if !body.isEmpty { parts.append("<p>\(br(body))</p>") }
            if !note.isEmpty { parts.append("<p><em>\(br(note))</em></p>") }
        }
    }
    return "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
        + "<title>\(escapeHTML(manifest.title))</title>\n"
        + "<style>\(plainCSS(scale: scale))</style>\n</head>\n<body>\n"
        + parts.joined(separator: "\n")
        + "\n</body>\n</html>\n"
}
