import AppKit
import CoreGraphics
import ExportKit
import Foundation
import ImageIO
import PDFKit
import ShotModel
import UniformTypeIdentifiers

// Live PDF smoke test — the macOS analog of CaptureKit's CaptureSelfTest. It
// drives the REAL WKWebView + NSPrintOperation PDF path (which `swift test` can't,
// since that needs an NSApplication run loop), and a watchdog turns a hang into a
// FAIL instead of a frozen process. Prints "[pdf-test] PASS/FAIL".
//
// Builds a throwaway project with enough steps to span multiple pages, exports
// PDF, then verifies the file is non-empty and has >1 page (proving pagination —
// the whole reason we use the print path over createPDF).

@MainActor
func writePNG(_ path: String, w: Int, h: Int) -> Bool {
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 20, y: 20, width: w - 40, height: h - 40))
    let data = NSMutableData()
    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { return false }
    return (try? (data as Data).write(to: URL(fileURLWithPath: path))) != nil
}

@MainActor
func runTest() async {
    let fm = FileManager.default
    let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("pdf-selftest-\(UUID().uuidString)")
    defer { try? fm.removeItem(atPath: dir) }
    do {
        try fm.createDirectory(atPath: (dir as NSString).appendingPathComponent("shots"),
                               withIntermediateDirectories: true)
    } catch {
        print("[pdf-test] FAIL: setup: \(error)"); exit(1)
    }
    guard writePNG((dir as NSString).appendingPathComponent("shots/a.png"), w: 600, h: 360) else {
        print("[pdf-test] FAIL: could not write fixture PNG"); exit(1)
    }

    // ~14 shot steps → comfortably more than one Letter page.
    var steps: [ProjectStep] = []
    for i in 0..<14 {
        steps.append(ProjectStep(
            id: "s\(i)", order: i, kind: .shot, screenshot: "shots/a.png",
            trigger: .click,
            caption: "Step \(i + 1): do the thing",
            body: "Detailed instructions for step \(i + 1). Lorem ipsum dolor sit amet, "
                + "consectetur adipiscing elit, sed do eiusmod tempor incididunt."))
    }
    let manifest = ProjectManifest(
        id: "selftest", title: "PDF Self Test",
        createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
        steps: steps)

    do {
        let result = try await exportProject(dir: dir, manifest: manifest, format: .pdf)
        let attrs = try? fm.attributesOfItem(atPath: result.outputPath)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let pages = PDFDocument(url: URL(fileURLWithPath: result.outputPath))?.pageCount ?? 0
        if size > 0, pages > 1 {
            print("[pdf-test] PASS bytes=\(size) pages=\(pages)")
            exit(0)
        } else {
            print("[pdf-test] FAIL: bytes=\(size) pages=\(pages) (expected non-empty, >1 page)")
            exit(1)
        }
    } catch {
        print("[pdf-test] FAIL: export threw: \(error.localizedDescription)")
        exit(1)
    }
}

// Watchdog: if the export hasn't finished in 30s, it's the hang we're guarding
// against — report it and bail rather than freeze forever.
DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    print("[pdf-test] FAIL: timed out after 30s (PDF path hung)")
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon / menu bar; still a real run loop
Task { @MainActor in await runTest() }
app.run()
