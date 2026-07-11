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
        if !intro.heading.isEmpty {
            pdf.draw(Ink.attr(intro.heading, size: 15, weight: .semibold, color: Ink.title), width: pdf.contentW)
            pdf.advance(4)
        }
        if !intro.body.isEmpty {
            pdf.drawFlowing(Ink.attr(intro.body, size: 11, color: Ink.body), x: pdf.margin, width: pdf.contentW)
        }
        pdf.advance(20)
    }

    for item in items {
        switch item {
        case .shot(let n, let caption, let body, let note, _, let image):
            let cg = (try? imageBytes(image)).flatMap(Self_cgImage)
            pdf.drawStep(
                badge: "\(n)", badgeColor: Ink.badge,
                caption: caption.isEmpty ? "Step \(n)" : caption,
                image: cg, body: body, note: note)

        case .text(let n, let heading, let body):
            pdf.drawStep(
                badge: "\(n)", badgeColor: Ink.badge,
                caption: heading, image: nil, body: body, note: "")

        case .callout(let kind, let heading, let body):
            pdf.drawCallout(kind: kind, heading: heading, body: body)
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
    static let badge = color("#4f46e5")
    static let hair = color("#e5e7eb")

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
    /// page and will be handled by flowing/capping).
    private func ensureRoom(_ height: CGFloat) {
        if !pageOpen { beginPage(); return }
        if cursorY - height < contentBottom && cursorY < contentTop {
            endPage(); beginPage()
        }
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

    func drawStep(badge: String, badgeColor: NSColor, caption: String, image: CGImage?, body: String, note: String) {
        guard let ctx else { return }
        let capAttr = caption.isEmpty ? nil : Ink.attr(caption, size: 13, weight: .semibold, color: Ink.title)
        let capH = capAttr.map { Self.measure($0, width: mainW) } ?? 0
        let headerH = max(badgeD, capH)

        // Image dimensions (fit width; cap height so header+image stay together).
        var imgW: CGFloat = 0, imgH: CGFloat = 0
        if let image {
            let nw = CGFloat(image.width), nh = CGFloat(image.height)
            if nw > 0, nh > 0 {
                imgW = mainW
                imgH = imgW * nh / nw
                let maxH = contentH * 0.60
                if imgH > maxH { imgH = maxH; imgW = imgH * nw / nh }
            }
        }
        // Keep the badge + caption + image on one page.
        ensureRoom(headerH + (imgH > 0 ? 10 + imgH : 0))

        let headerTop = cursorY
        // Badge circle + centered number.
        let badgeRect = CGRect(x: margin, y: headerTop - badgeD, width: badgeD, height: badgeD)
        ctx.setFillColor(badgeColor.cgColor)
        ctx.fillEllipse(in: badgeRect)
        let bAttr = Ink.attr(badge, size: 12, weight: .semibold, color: .white)
        let line = CTLineCreateWithAttributedString(bAttr)
        let bw = CTLineGetTypographicBounds(line, nil, nil, nil)
        let f = Ink.font(12, .semibold, italic: false)
        ctx.textPosition = CGPoint(x: badgeRect.midX - CGFloat(bw) / 2,
                                   y: badgeRect.midY - (f.ascender + f.descender) / 2)
        CTLineDraw(line, ctx)
        // Caption next to the badge.
        if let capAttr {
            drawAt(capAttr, x: mainX, width: mainW, height: capH, top: headerTop, ctx: ctx)
        }
        cursorY = headerTop - headerH

        if let image, imgW > 0 {
            advance(10)
            let r = CGRect(x: mainX, y: cursorY - imgH, width: imgW, height: imgH)
            ctx.draw(image, in: r)
            ctx.setStrokeColor(Ink.hair.cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(r)
            cursorY -= imgH
        }
        if !body.isEmpty {
            advance(8)
            drawFlowing(Ink.attr(body, size: 11, color: Ink.body), x: mainX, width: mainW)
        }
        if !note.isEmpty {
            advance(6)
            drawFlowing(Ink.attr(note, size: 10, color: Ink.note, italic: true), x: mainX, width: mainW)
        }
        advance(22)
    }

    func drawCallout(kind: CalloutKindExport, heading: String, body: String) {
        guard let ctx else { return }
        let c = Ink.callout(kind)
        let glyph = calloutGlyphExport(kind)
        let padX: CGFloat = 12, padY: CGFloat = 10, borderW: CGFloat = 4
        let innerX = margin + borderW + padX
        let innerW = contentW - borderW - padX * 2

        let headStr = heading.isEmpty ? glyph : "\(glyph)  \(heading)"
        let headAttr = Ink.attr(headStr, size: 12, weight: .bold, color: c.text)
        let bodyAttr = body.isEmpty ? nil : Ink.attr(body, size: 11, color: c.text)
        let hH = Self.measure(headAttr, width: innerW)
        let bH = bodyAttr.map { Self.measure($0, width: innerW) } ?? 0
        let gap: CGFloat = (bH > 0) ? 4 : 0
        let boxH = padY * 2 + hH + bH + gap

        ensureRoom(boxH)
        let top = cursorY
        let box = CGRect(x: margin, y: top - boxH, width: contentW, height: boxH)
        ctx.setFillColor(c.bg.cgColor)
        ctx.fill(box)
        ctx.setFillColor(c.border.cgColor)
        ctx.fill(CGRect(x: margin, y: top - boxH, width: borderW, height: boxH))

        drawAt(headAttr, x: innerX, width: innerW, height: hH, top: top - padY, ctx: ctx)
        if let bodyAttr {
            drawAt(bodyAttr, x: innerX, width: innerW, height: bH, top: top - padY - hH - gap, ctx: ctx)
        }
        cursorY = top - boxH - 16
    }
}
