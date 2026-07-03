#!/usr/bin/env swift
// Renders the fixture project's PNGs: a mock Windows-Chrome "Acme ERP" window
// sized 2176x1224 (a 2560x1440 monitor grab downscaled by the Windows app's
// CAPTURE_SCALE 0.85), plus the cropped/annotated flattened render for step 2.
// Geometry here MUST match Fixtures/<uuid>/project.json.
//
// Usage: swift Scripts/make-fixture-shots.swift Fixtures/<uuid>

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-fixture-shots.swift <project-dir>\n".utf8))
    exit(2)
}
let projectDir = URL(fileURLWithPath: args[1])

let W = 2176, H = 1224 // 2560x1440 * 0.85

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Flip so drawing uses top-left origin like the stored screenshot coordinates.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

func fill(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
    ctx.setFillColor(c)
    ctx.fill(r)
}

func stroke(_ ctx: CGContext, _ r: CGRect, _ c: CGColor, _ width: CGFloat) {
    ctx.setStrokeColor(c)
    ctx.setLineWidth(width)
    ctx.stroke(r)
}

func text(_ ctx: CGContext, _ s: String, at p: CGPoint, size: CGFloat, color c: CGColor, bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
    let attr = NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): c,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    ctx.textMatrix = .identity
    // Un-flip locally: CoreText draws in bottom-left coordinates.
    ctx.translateBy(x: p.x, y: p.y + size)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

func writePNG(_ ctx: CGContext, to url: URL) {
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG write failed: \(url.path)") }
    print("wrote \(url.path)")
}

/// The base "Acme ERP in Chrome on Windows" frame every shot shares.
func drawBrowserWindow(_ ctx: CGContext) {
    fill(ctx, CGRect(x: 0, y: 0, width: W, height: H), color(0x0d7377)) // desktop behind window
    let win = CGRect(x: 0, y: 0, width: W, height: 1190) // window.bounds 2560x1400 * 0.85
    fill(ctx, win, color(0xffffff))

    // Chrome tab strip + Windows caption buttons.
    fill(ctx, CGRect(x: 0, y: 0, width: W, height: 68), color(0xdee1e6))
    fill(ctx, CGRect(x: 20, y: 12, width: 440, height: 56), color(0xffffff))
    text(ctx, "Orders · Acme ERP", at: CGPoint(x: 44, y: 22), size: 26, color: color(0x202124))
    text(ctx, "—      ▢      ✕", at: CGPoint(x: CGFloat(W) - 210, y: 18, ), size: 28, color: color(0x5f6368))

    // Address bar.
    fill(ctx, CGRect(x: 0, y: 68, width: W, height: 76), color(0xf1f3f4))
    fill(ctx, CGRect(x: 120, y: 82, width: 1500, height: 48), color(0xffffff))
    text(ctx, "acme.example.com/reports/orders", at: CGPoint(x: 150, y: 92), size: 26, color: color(0x202124))

    // App toolbar with the Export button — element bounds (1560,450,180,56)
    // global px scale to image px (1326, 382, 153, 48).
    fill(ctx, CGRect(x: 0, y: 144, width: W, height: 100), color(0x1e293b))
    text(ctx, "Acme ERP — Orders", at: CGPoint(x: 60, y: 172), size: 34, color: color(0xffffff), bold: true)
    fill(ctx, CGRect(x: 60, y: 300, width: 2056, height: 60), color(0xf8fafc))
    text(ctx, "Monthly orders · June 2026 · 138 records", at: CGPoint(x: 80, y: 312), size: 28, color: color(0x475569))

    let export = CGRect(x: 1326, y: 382, width: 153, height: 48)
    fill(ctx, export, color(0x1a73e8))
    text(ctx, "Export", at: CGPoint(x: export.minX + 30, y: export.minY + 8), size: 26, color: color(0xffffff), bold: true)
    let refresh = CGRect(x: 1150, y: 382, width: 153, height: 48)
    fill(ctx, refresh, color(0xe2e8f0))
    text(ctx, "Refresh", at: CGPoint(x: refresh.minX + 24, y: refresh.minY + 8), size: 26, color: color(0x334155))

    // Orders table — element 'Orders table' bounds (340,320,1800,900) global px.
    let table = CGRect(x: 289, y: 460, width: 1530, height: 700)
    stroke(ctx, table, color(0xcbd5e1), 2)
    let headers = ["Order #", "Customer", "Billing contact", "Total"]
    let colX: [CGFloat] = [320, 560, 940, 1560]
    fill(ctx, CGRect(x: table.minX, y: table.minY, width: table.width, height: 56), color(0xf1f5f9))
    for (i, hdr) in headers.enumerated() {
        text(ctx, hdr, at: CGPoint(x: colX[i], y: table.minY + 12), size: 26, color: color(0x334155), bold: true)
    }
    let rows: [[String]] = [
        ["SO-10412", "Great Lakes Supply", "billing@greatlakes.example", "$12,480.00"],
        ["SO-10413", "Northfield Retail", "ap@northfield.example", "$3,215.50"],
        ["SO-10414", "Cascade Outdoor", "accounts@cascade.example", "$28,900.00"],
        ["SO-10415", "Prairie Wholesale", "finance@prairie.example", "$7,644.25"],
        ["SO-10416", "Harbor & Co", "harbor.billing@harbor.example", "$1,099.99"],
        ["SO-10417", "Summit Traders", "pay@summit.example", "$19,320.75"],
        ["SO-10418", "Lakeside Foods", "billing@lakeside.example", "$5,410.00"],
        ["SO-10419", "Redwood Partners", "ar@redwood.example", "$44,002.10"],
    ]
    for (r, row) in rows.enumerated() {
        let y = table.minY + 56 + CGFloat(r) * 74
        if r % 2 == 1 { fill(ctx, CGRect(x: table.minX, y: y, width: table.width, height: 74), color(0xf8fafc)) }
        for (i, cell) in row.enumerated() {
            text(ctx, cell, at: CGPoint(x: colX[i], y: y + 20), size: 26, color: color(0x0f172a))
        }
    }

    // Windows taskbar under the window.
    fill(ctx, CGRect(x: 0, y: 1190, width: W, height: 34), color(0x101418))
}

/// Step 2's context menu, opened at the right-click point (image px 765,510).
func drawContextMenu(_ ctx: CGContext) {
    let menu = CGRect(x: 765, y: 510, width: 330, height: 250)
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 18, color: color(0x000000, 0.35))
    fill(ctx, menu, color(0xffffff))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    stroke(ctx, menu, color(0xd0d4da), 1.5)
    let items = ["Open order", "Copy row", "Export selection…", "Column settings", "Hide row"]
    for (i, item) in items.enumerated() {
        let y = menu.minY + 14 + CGFloat(i) * 46
        if i == 2 { fill(ctx, CGRect(x: menu.minX + 4, y: y - 6, width: menu.width - 8, height: 44), color(0xe8f0fe)) }
        text(ctx, item, at: CGPoint(x: menu.minX + 22, y: y), size: 26, color: color(0x202124))
    }
}

/// Marker ring, same visual as the report/flatten: colored ring + translucent
/// fill + white halo.
func drawMarker(_ ctx: CGContext, at p: CGPoint, radius: CGFloat, hex: UInt32) {
    let r = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
    ctx.setFillColor(color(hex, 0.18))
    ctx.fillEllipse(in: r)
    ctx.setStrokeColor(color(0xffffff, 0.7))
    ctx.setLineWidth(9)
    ctx.strokeEllipse(in: r)
    ctx.setStrokeColor(color(hex))
    ctx.setLineWidth(5)
    ctx.strokeEllipse(in: r)
}

// --- step-0001.png: the Export click ---
let shotsDir = projectDir.appendingPathComponent("shots")
let renderDir = projectDir.appendingPathComponent("export/.render")
try FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: renderDir, withIntermediateDirectories: true)

let c1 = makeContext(W, H)
drawBrowserWindow(c1)
writePNG(c1, to: shotsDir.appendingPathComponent("step-0001.png"))

// --- step-0002.png: the right-click with the context menu open ---
let c2 = makeContext(W, H)
drawBrowserWindow(c2)
drawContextMenu(c2)
writePNG(c2, to: shotsDir.appendingPathComponent("step-0002.png"))

// --- step-0003.png: the hotkey full capture (menu closed) ---
let c3 = makeContext(W, H)
drawBrowserWindow(c3)
writePNG(c3, to: shotsDir.appendingPathComponent("step-0003.png"))

// --- Flattened render for step 2: crop (200,120,1200,700) with annotations
// BAKED — rect outline, pixelated redaction, stamp, and the blue right-click
// marker ring (markerBaked: true, so the viewer must NOT overlay another ring).
let crop = CGRect(x: 200, y: 120, width: 1200, height: 700)
let cf = makeContext(Int(crop.width), Int(crop.height))
cf.saveGState()
cf.translateBy(x: -crop.minX, y: -crop.minY)
drawBrowserWindow(cf)
drawContextMenu(cf)

// blur/pixelate over image-px (900,500,360,130): opaque mosaic destroys pixels.
let blur = CGRect(x: 900, y: 500, width: 360, height: 130)
let block: CGFloat = 14
var seed: UInt64 = 0x5eed
func nextGray() -> UInt32 {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    let v = UInt32(120 + (seed >> 33) % 90)
    return (v << 16) | (v << 8) | v
}
var by = blur.minY
while by < blur.maxY {
    var bx = blur.minX
    while bx < blur.maxX {
        fill(cf, CGRect(x: bx, y: by, width: min(block, blur.maxX - bx), height: min(block, blur.maxY - by)), color(nextGray()))
        bx += block
    }
    by += block
}

// rect annotation (320,260,520,180) rose outline.
stroke(cf, CGRect(x: 320, y: 260, width: 520, height: 180), color(0xe11d48), 4)

// stamp n=1 at (360,300) r=26.
let stampR: CGFloat = 26
cf.setFillColor(color(0xe11d48))
cf.fillEllipse(in: CGRect(x: 360 - stampR, y: 300 - stampR, width: stampR * 2, height: stampR * 2))
text(cf, "1", at: CGPoint(x: 360 - 8, y: 300 - 17), size: 30, color: color(0xffffff), bold: true)

// baked right-click marker at image px (765,510).
drawMarker(cf, at: CGPoint(x: 765, y: 510), radius: 30, hex: 0x2563eb)
cf.restoreGState()
writePNG(cf, to: renderDir.appendingPathComponent("9a1b3c5d-7e2f-4b8a-9c1d-2e4f6a8b0c3e.png"))
