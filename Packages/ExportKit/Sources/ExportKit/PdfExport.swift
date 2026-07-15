import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ShotModel

// Native CoreText/CoreGraphics PDF renderer. We do NOT use WKWebView printing:
// `NSPrintOperation` (both run() and runModal(for:)) drives WKWebView's print
// pagination synchronously on the main thread, and `-[WKPrintingView rectForPage:]`
// spins forever on some setups — freezing the whole app (confirmed via sample()).
// Drawing the PDF directly from the collected ExportItems is pure Core Graphics:
// no cross-process print IPC, so it can't hang, and we control pagination (a
// screenshot never splits from its caption; long body text flows across pages).

/// Render the collected export items to a paginated US-Letter PDF at `outputPath`.
/// Synchronous + pure Core Graphics (safe off the main thread; never blocks it).
func renderPdf(
    title: String, createdLine: String, intro: SopIntro?, items: [ExportItem], outputPath: String
) throws {
    let pdf = PdfCanvas(outputPath: outputPath)
    guard pdf.start() else { throw ExportError.writeFailed("Could not create the PDF document.") }

    pdf.beginPage()
    pdf.draw(Ink.attr(title, size: 22, weight: .bold, color: Ink.title), width: pdf.contentW)
    pdf.advance(4)
    pdf.draw(Ink.attr(createdLine, size: 10, color: Ink.meta), width: pdf.contentW)
    pdf.advance(18)

    if let intro, !(intro.heading.isEmpty && intro.body.isEmpty) {
        pdf.drawIntro(heading: intro.heading, body: intro.body)
    }

    for (idx, item) in items.enumerated() {
        let separator = idx > 0  // subtle hairline between steps (#40)
        switch item {
        case .shot(let n, let caption, let body, let note, _, let image):
            let cg = (try? imageBytes(image)).flatMap(Self_cgImage)
            pdf.drawStep(
                badge: "\(n)", badgeColor: Ink.badge,
                caption: caption.isEmpty ? "Step \(n)" : caption,
                image: cg, body: body, note: note, separator: separator)

        case .text(let n, let heading, let body):
            pdf.drawStep(
                badge: "\(n)", badgeColor: Ink.badge,
                caption: heading, image: nil, body: body, note: "", separator: separator)

        case .callout(let kind, let heading, let body):
            pdf.drawCallout(kind: kind, heading: heading, body: body, separator: separator)
        }
    }

    pdf.finish()

    // Fail closed: never leave a 0-byte/missing PDF as if it succeeded.
    let attrs = try? FileManager.default.attributesOfItem(atPath: outputPath)
    guard ((attrs?[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
        try? FileManager.default.removeItem(atPath: outputPath)
        throw ExportError.writeFailed("PDF rendering produced an empty document.")
    }
}

/// Decode image bytes to a CGImage (nil on failure → the step renders text-only).
private func Self_cgImage(_ data: Data) -> CGImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - Colors / fonts (ported from DOC_CSS)

private enum Ink {
    static let title = color("#1f2937")
    static let meta = color("#6b7280")
    static let body = color("#374151")
    static let note = color("#6b7280")
    static let badge = color("#6344f1")       // app accent (Palette.accent)
    static let hair = color("#e5e7eb")
    static let cardBg = color("#faf9ff")      // step card fill (Palette.surface2)
    static let cardBorder = color("#e7e4f2")  // step card border (Palette.hair)
    static let introBg = color("#efeafe")     // overview fill (Palette.accentTint)
    static let eyebrow = color("#6b7280")     // "OVERVIEW" label

    struct Callout { let bg, border, text: NSColor }
    static func callout(_ kind: CalloutKindExport) -> Callout {
        switch kind {
        case .note:    Callout(bg: color("#ecfdf5"), border: color("#6ee7b7"), text: color("#065f46"))
        case .caution: Callout(bg: color("#fffbeb"), border: color("#fcd34d"), text: color("#92400e"))
        case .warning: Callout(bg: color("#fef2f2"), border: color("#fca5a5"), text: color("#991b1b"))
        }
    }

    static func color(_ hex: String) -> NSColor {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight, italic: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return base }
        let desc = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: desc, size: size) ?? base
    }

    static func attr(
        _ s: String, size: CGFloat, weight: NSFont.Weight = .regular,
        color: NSColor, italic: Bool = false
    ) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return NSAttributedString(string: s, attributes: [
            .font: font(size, weight, italic: italic),
            .foregroundColor: color,
            .paragraphStyle: p,
        ])
    }
}

// MARK: - PDF canvas (page/cursor management + drawing primitives)

/// A vertical-flow PDF drawing surface. Tracks a `cursorY` (PDF y-up, measured
/// down from the content top) and starts a new page when a block won't fit.
private final class PdfCanvas {
    let pageW: CGFloat = 612, pageH: CGFloat = 792
    let margin: CGFloat = 40
    var contentW: CGFloat { pageW - margin * 2 }
    private var contentTop: CGFloat { pageH - margin }
    private var contentBottom: CGFloat { margin }
    private var contentH: CGFloat { contentTop - contentBottom }

    // Step layout: a number badge column on the left, content to its right.
    private let badgeD: CGFloat = 26
    private let badgeGap: CGFloat = 14
    private var mainX: CGFloat { margin + badgeD + badgeGap }
    private var mainW: CGFloat { contentW - badgeD - badgeGap }

    private let outputPath: String
    private var ctx: CGContext?
    private var cursorY: CGFloat = 0
    private var pageOpen = false

    init(outputPath: String) { self.outputPath = outputPath }

    func start() -> Bool {
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let c = CGContext(URL(fileURLWithPath: outputPath) as CFURL, mediaBox: &box, nil) else {
            return false
        }
        ctx = c
        return true
    }

    func beginPage() {
        ctx?.beginPDFPage(nil)
        pageOpen = true
        cursorY = contentTop
    }

    private func endPage() {
        if pageOpen { ctx?.endPDFPage(); pageOpen = false }
    }

    func finish() {
        endPage()
        ctx?.closePDF()
        ctx = nil
    }

    func advance(_ dy: CGFloat) { cursorY -= dy }

    /// Page-break if `height` won't fit in the space left on the current page
    /// (unless we're already at the top — then the block is simply taller than a
    /// page and will be handled by flowing/capping). Returns true if it started a
    /// fresh page, so callers can suppress a leading separator (a page break is
    /// its own separation, and a rule would strand at the old page's bottom).
    @discardableResult
    private func ensureRoom(_ height: CGFloat) -> Bool {
        if !pageOpen { beginPage(); return true }
        if cursorY - height < contentBottom && cursorY < contentTop {
            endPage(); beginPage(); return true
        }
        return false
    }

    /// A subtle full-width hairline at the current cursor — the between-steps
    /// separator (#40). Drawn only when the following item fits on this page.
    private func strokeStepRule() {
        guard let ctx, pageOpen else { return }
        ctx.setStrokeColor(Ink.hair.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: cursorY))
        ctx.addLine(to: CGPoint(x: margin + contentW, y: cursorY))
        ctx.strokePath()
    }

    static func measure(_ a: NSAttributedString, width: CGFloat) -> CGFloat {
        guard a.length > 0 else { return 0 }
        let fs = CTFramesetterCreateWithAttributedString(a)
        let sz = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: a.length), nil,
            CGSize(width: width, height: 1e6), nil)
        return ceil(sz.height)
    }

    /// Draw a single already-fitting block at the current cursor, advancing it.
    func draw(_ a: NSAttributedString, width: CGFloat) {
        guard a.length > 0, let ctx else { return }
        let h = Self.measure(a, width: width)
        ensureRoom(h)
        drawAt(a, x: margin, width: width, height: h, top: cursorY, ctx: ctx)
        cursorY -= h
    }

    private func drawAt(
        _ a: NSAttributedString, x: CGFloat, width: CGFloat, height: CGFloat,
        top: CGFloat, ctx: CGContext
    ) {
        let fs = CTFramesetterCreateWithAttributedString(a)
        let path = CGPath(rect: CGRect(x: x, y: top - height, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
    }

    /// Draw text that may exceed the remaining page, flowing it across pages.
    func drawFlowing(_ a: NSAttributedString, x: CGFloat, width: CGFloat) {
        guard a.length > 0, let ctx else { return }
        let fs = CTFramesetterCreateWithAttributedString(a)
        var start = 0
        while start < a.length {
            if cursorY - contentBottom < 16 { endPage(); beginPage() }
            let colH = cursorY - contentBottom
            let path = CGPath(rect: CGRect(x: x, y: contentBottom, width: width, height: colH), transform: nil)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let vis = CTFrameGetVisibleStringRange(frame)
            guard vis.length > 0 else { break } // safety: nothing fit
            let sz = CTFramesetterSuggestFrameSizeWithConstraints(
                fs, CFRange(location: start, length: vis.length), nil,
                CGSize(width: width, height: 1e6), nil)
            cursorY -= ceil(sz.height)
            start += vis.length
            if start < a.length { endPage(); beginPage() }
        }
    }

    // MARK: Step + callout

    /// Fill + stroke a rounded rect (the step/callout card, and the overview box).
    private func fillRoundedRect(_ rect: CGRect, radius: CGFloat, fill: NSColor, stroke: NSColor, ctx: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(fill.cgColor); ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(1); ctx.addPath(path); ctx.strokePath()
    }

    /// A badge circle in the left gutter, top at `topY`, `text` centered. `ring`
    /// (optional) strokes the edge — callout glyph badges are a light fill + a
    /// colored ring + dark glyph, matching the report; numbered badges are solid.
    private func drawBadge(_ text: String, fill: NSColor, textColor: NSColor, ring: NSColor?, topY: CGFloat, ctx: CGContext) {
        let rect = CGRect(x: margin, y: topY - badgeD, width: badgeD, height: badgeD)
        ctx.setFillColor(fill.cgColor); ctx.fillEllipse(in: rect)
        if let ring {
            ctx.setStrokeColor(ring.cgColor); ctx.setLineWidth(1); ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
        let a = Ink.attr(text, size: 12, weight: .semibold, color: textColor)
        let line = CTLineCreateWithAttributedString(a)
        let bw = CTLineGetTypographicBounds(line, nil, nil, nil)
        let f = Ink.font(12, .semibold, italic: false)
        ctx.textPosition = CGPoint(x: rect.midX - CGFloat(bw) / 2, y: rect.midY - (f.ascender + f.descender) / 2)
        CTLineDraw(line, ctx)
    }

    func drawStep(badge: String, badgeColor: NSColor, caption: String, image: CGImage?, body: String, note: String, separator: Bool) {
        guard let ctx else { return }
        // Layout: a badge in the left gutter + a tinted card holding the content,
        // matching the in-app report. `innerW` is the card's content width.
        let innerPad: CGFloat = 12
        let cardW = mainW
        let innerX = mainX + innerPad
        let innerW = cardW - innerPad * 2

        let capAttr = caption.isEmpty ? nil : Ink.attr(caption, size: 13, weight: .semibold, color: Ink.title)
        let capH = capAttr.map { Self.measure($0, width: innerW) } ?? 0
        let headerH = max(badgeD, capH)

        func imageDims(_ w: CGFloat) -> (CGFloat, CGFloat) {
            guard let image else { return (0, 0) }
            let nw = CGFloat(image.width), nh = CGFloat(image.height)
            guard nw > 0, nh > 0 else { return (0, 0) }
            var iw = w, ih = w * nh / nw
            let maxH = contentH * 0.55
            if ih > maxH { ih = maxH; iw = ih * nw / nh }
            return (iw, ih)
        }
        let (imgW, imgH) = imageDims(innerW)
        let bodyAttr = body.isEmpty ? nil : Ink.attr(body, size: 11, color: Ink.body)
        let bodyH = bodyAttr.map { Self.measure($0, width: innerW) } ?? 0
        let noteAttr = note.isEmpty ? nil : Ink.attr(note, size: 10, color: Ink.note, italic: true)
        let noteH = noteAttr.map { Self.measure($0, width: innerW) } ?? 0

        let blockH = headerH + (imgH > 0 ? 10 + imgH : 0) + (bodyH > 0 ? 8 + bodyH : 0) + (noteH > 0 ? 6 + noteH : 0)
        let cardH = innerPad * 2 + blockH
        let sepGap: CGFloat = separator ? 18 : 0

        if cardH <= contentH {
            // Fits a page → draw the framed card.
            _ = ensureRoom(sepGap + cardH)
            if separator { advance(sepGap) }   // gap between cards (no rule — the frame separates)
            let cardTop = cursorY
            fillRoundedRect(CGRect(x: mainX, y: cardTop - cardH, width: cardW, height: cardH),
                            radius: 10, fill: Ink.cardBg, stroke: Ink.cardBorder, ctx: ctx)
            let top = cardTop - innerPad
            drawBadge(badge, fill: badgeColor, textColor: .white, ring: nil, topY: top, ctx: ctx)
            if let capAttr { drawAt(capAttr, x: innerX, width: innerW, height: capH, top: top, ctx: ctx) }
            cursorY = top - headerH
            if imgW > 0, let image {
                advance(10)
                let r = CGRect(x: innerX, y: cursorY - imgH, width: imgW, height: imgH)
                ctx.draw(image, in: r)
                ctx.setStrokeColor(Ink.hair.cgColor); ctx.setLineWidth(0.5); ctx.stroke(r)
                cursorY -= imgH
            }
            if let bodyAttr { advance(8); drawAt(bodyAttr, x: innerX, width: innerW, height: bodyH, top: cursorY, ctx: ctx); cursorY -= bodyH }
            if let noteAttr { advance(6); drawAt(noteAttr, x: innerX, width: innerW, height: noteH, top: cursorY, ctx: ctx); cursorY -= noteH }
            cursorY = cardTop - cardH   // land just below the card
        } else {
            // Taller than a page (big image + long body) → flow it, box-less.
            let (fImgW, fImgH) = imageDims(mainW)
            let broke = ensureRoom(sepGap + headerH + (fImgH > 0 ? 10 + fImgH : 0))
            if separator && !broke { advance(14); strokeStepRule(); advance(14) }
            let top = cursorY
            drawBadge(badge, fill: badgeColor, textColor: .white, ring: nil, topY: top, ctx: ctx)
            if let capAttr { drawAt(capAttr, x: mainX, width: mainW, height: capH, top: top, ctx: ctx) }
            cursorY = top - headerH
            if fImgW > 0, let image {
                advance(10)
                let r = CGRect(x: mainX, y: cursorY - fImgH, width: fImgW, height: fImgH)
                ctx.draw(image, in: r)
                ctx.setStrokeColor(Ink.hair.cgColor); ctx.setLineWidth(0.5); ctx.stroke(r)
                cursorY -= fImgH
            }
            if let bodyAttr { advance(8); drawFlowing(bodyAttr, x: mainX, width: mainW) }
            if let noteAttr { advance(6); drawFlowing(noteAttr, x: mainX, width: mainW) }
        }
    }

    func drawCallout(kind: CalloutKindExport, heading: String, body: String, separator: Bool) {
        guard let ctx else { return }
        let c = Ink.callout(kind)
        let innerPad: CGFloat = 12
        let cardW = mainW
        let innerX = mainX + innerPad
        let innerW = cardW - innerPad * 2

        let headAttr = heading.isEmpty ? nil : Ink.attr(heading, size: 13, weight: .bold, color: c.text)
        let bodyAttr = body.isEmpty ? nil : Ink.attr(body, size: 11, color: c.text)
        let hH = headAttr.map { Self.measure($0, width: innerW) } ?? 0
        let bH = bodyAttr.map { Self.measure($0, width: innerW) } ?? 0
        let gap: CGFloat = (hH > 0 && bH > 0) ? 4 : 0
        let cardH = innerPad * 2 + hH + bH + gap

        let sepGap: CGFloat = separator ? 18 : 0
        _ = ensureRoom(sepGap + cardH)
        if separator { advance(sepGap) }   // gap between cards
        let cardTop = cursorY
        fillRoundedRect(CGRect(x: mainX, y: cardTop - cardH, width: cardW, height: cardH),
                        radius: 10, fill: c.bg, stroke: c.border, ctx: ctx)
        // Glyph badge in the gutter (light fill + colored ring), matching the report.
        let top = cardTop - innerPad
        drawBadge(calloutGlyphExport(kind), fill: c.bg, textColor: c.text, ring: c.border, topY: top, ctx: ctx)
        var y = top
        if let headAttr { drawAt(headAttr, x: innerX, width: innerW, height: hH, top: y, ctx: ctx); y -= hH + gap }
        if let bodyAttr { drawAt(bodyAttr, x: innerX, width: innerW, height: bH, top: y, ctx: ctx) }
        cursorY = cardTop - cardH
    }

    /// The overview box (report parity): an "OVERVIEW" eyebrow + heading + body in
    /// a tinted, left-accented card. Falls back to plain text for a very long
    /// overview that can't fit a page. Adds its own trailing gap.
    func drawIntro(heading: String, body: String) {
        guard let ctx else { return }
        let borderW: CGFloat = 4, padX: CGFloat = 14, padY: CGFloat = 12, radius: CGFloat = 8
        let innerX = margin + borderW + padX
        let innerW = contentW - borderW - padX * 2
        let eyebrow = Ink.attr("OVERVIEW", size: 9, weight: .bold, color: Ink.eyebrow)
        let eH = Self.measure(eyebrow, width: innerW)
        let headAttr = heading.isEmpty ? nil : Ink.attr(heading, size: 15, weight: .semibold, color: Ink.title)
        let hH = headAttr.map { Self.measure($0, width: innerW) } ?? 0
        let bodyAttr = body.isEmpty ? nil : Ink.attr(body, size: 11, color: Ink.body)
        let bH = bodyAttr.map { Self.measure($0, width: innerW) } ?? 0
        let g1: CGFloat = hH > 0 ? 4 : 0
        let g2: CGFloat = bH > 0 ? 6 : 0
        let boxH = padY * 2 + eH + g1 + hH + g2 + bH

        if boxH <= contentH {
            _ = ensureRoom(boxH)
            let top = cursorY
            fillRoundedRect(CGRect(x: margin, y: top - boxH, width: contentW, height: boxH),
                            radius: radius, fill: Ink.introBg, stroke: Ink.cardBorder, ctx: ctx)
            // Left accent bar, inset vertically so it stays inside the rounded corners.
            ctx.setFillColor(Ink.badge.cgColor)
            ctx.fill(CGRect(x: margin, y: top - boxH + radius, width: borderW, height: boxH - radius * 2))
            var y = top - padY
            drawAt(eyebrow, x: innerX, width: innerW, height: eH, top: y, ctx: ctx); y -= eH + g1
            if let headAttr { drawAt(headAttr, x: innerX, width: innerW, height: hH, top: y, ctx: ctx); y -= hH + g2 }
            if let bodyAttr { drawAt(bodyAttr, x: innerX, width: innerW, height: bH, top: y, ctx: ctx) }
            cursorY = top - boxH
        } else {
            draw(eyebrow, width: contentW); advance(4)
            if let headAttr { draw(headAttr, width: contentW); advance(4) }
            if let bodyAttr { drawFlowing(bodyAttr, x: margin, width: contentW) }
        }
        advance(20)
    }
}
