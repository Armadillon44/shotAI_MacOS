import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ExportKit
import ShotModel

final class ExportKitTests: XCTestCase {

    // MARK: - Fixtures

    /// A fresh temp project dir (with a shots/ subfolder), auto-cleaned.
    private func makeProjectDir() throws -> String {
        let base = NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("exportkit-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (dir as NSString).appendingPathComponent("shots"),
            withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// Write a solid-color PNG of the given pixel size (uses ExportKit's own PNG
    /// encoder, so this exercises the same ImageIO path exports use).
    @discardableResult
    private func writePNG(_ path: String, w: Int, h: Int) -> Bool {
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage(), let data = encodePNG(img) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    private func shotStep(
        id: String, order: Int, screenshot: String,
        caption: String = "", body: String? = nil, note: String = "",
        crop: Rect? = nil, flattened: String? = nil,
        reportZoom: Double? = nil, reportPanX: Double? = nil, reportPanY: Double? = nil
    ) -> ProjectStep {
        ProjectStep(
            id: id, order: order, kind: .shot, screenshot: screenshot,
            trigger: .click, caption: caption, note: note, body: body,
            crop: crop, flattened: flattened,
            reportZoom: reportZoom, reportPanX: reportPanX, reportPanY: reportPanY)
    }

    private func textStep(
        id: String, order: Int, heading: String?, body: String?, callout: CalloutKind? = nil
    ) -> ProjectStep {
        ProjectStep(
            id: id, order: order, kind: .text, screenshot: "",
            trigger: .click, heading: heading, body: body, callout: callout)
    }

    private func manifest(_ steps: [ProjectStep], title: String = "My SOP", intro: SopIntro? = nil) -> ProjectManifest {
        ProjectManifest(
            id: "proj-1", title: title, createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z", steps: steps, intro: intro)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Pure geometry

    func testZoomCropRectNoCropCases() {
        XCTAssertNil(zoomCropRect(width: 100, height: 100, zoom: 1, panX: 0.5, panY: 0.5))
        XCTAssertNil(zoomCropRect(width: 100, height: 100, zoom: 0.5, panX: 0.5, panY: 0.5))
        XCTAssertNil(zoomCropRect(width: 1, height: 1, zoom: 2, panX: 0.5, panY: 0.5))
    }

    func testZoomCropRectCentered() {
        // zoom 2 → half-size window, centered by pan 0.5.
        let r = zoomCropRect(width: 100, height: 80, zoom: 2, panX: 0.5, panY: 0.5)
        XCTAssertEqual(r, CGRect(x: 25, y: 20, width: 50, height: 40))
    }

    func testZoomCropRectPanClampsAndDefaults() {
        // pan past the edges clamps to [0,1]; NaN defaults to centered.
        let full = zoomCropRect(width: 100, height: 100, zoom: 2, panX: 5, panY: -3)
        XCTAssertEqual(full, CGRect(x: 50, y: 0, width: 50, height: 50))
        let nan = zoomCropRect(width: 100, height: 100, zoom: 2, panX: .nan, panY: .nan)
        XCTAssertEqual(nan, CGRect(x: 25, y: 25, width: 50, height: 50))
    }

    // MARK: - Text helpers

    func testSafeFileBase() {
        XCTAssertEqual(safeFileBase("Hello / World: <x>"), "Hello World x")
        XCTAssertEqual(safeFileBase("   "), "shotAI SOP")
        XCTAssertEqual(safeFileBase("con"), "_con")
        XCTAssertEqual(safeFileBase("CON"), "_CON")
        XCTAssertEqual(safeFileBase(".hidden"), "_.hidden")
        XCTAssertEqual(safeFileBase("trailing..."), "trailing")
        XCTAssertEqual(safeFileBase(String(repeating: "a", count: 200)).count, 120)
    }

    func testEscapeHtml() {
        XCTAssertEqual(escapeHTML("a & b < c > d \" e"), "a &amp; b &lt; c &gt; d &quot; e")
        // Ampersand first: a literal entity is double-escaped, never mangled.
        XCTAssertEqual(escapeHTML("&lt;"), "&amp;lt;")
    }

    func testEscapeMarkdown() {
        XCTAssertEqual(escapeMarkdown("a*b_c[d]#e`f\\g<h>"), "a\\*b\\_c\\[d\\]\\#e\\`f\\\\g\\<h\\>")
    }

    func testNextAvailableStem() throws {
        let dir = try makeProjectDir()
        XCTAssertEqual(nextAvailableStem(exportDir: dir, stem: "Doc", ext: ".html"), "Doc")
        try "x".write(toFile: (dir as NSString).appendingPathComponent("Doc.html"), atomically: true, encoding: .utf8)
        XCTAssertEqual(nextAvailableStem(exportDir: dir, stem: "Doc", ext: ".html"), "Doc (1)")
        try "x".write(toFile: (dir as NSString).appendingPathComponent("Doc (1).html"), atomically: true, encoding: .utf8)
        XCTAssertEqual(nextAvailableStem(exportDir: dir, stem: "Doc", ext: ".html"), "Doc (2)")
    }

    // MARK: - HTML export (numbering + escaping + skips)

    func testHtmlExportNumberingAndEscaping() async throws {
        let dir = try makeProjectDir()
        XCTAssertTrue(writePNG((dir as NSString).appendingPathComponent("shots/a.png"), w: 40, h: 30))
        let m = manifest([
            shotStep(id: "s1", order: 0, screenshot: "shots/a.png",
                     caption: "Click <b>Save</b>", body: "Line1\nLine2", note: "careful"),
            textStep(id: "t1", order: 1, heading: "Do the thing", body: "details"),
            textStep(id: "c1", order: 2, heading: "Danger", body: "watch out", callout: .warning),
            textStep(id: "t2", order: 3, heading: "", body: "  "),  // empty → skipped
        ], intro: SopIntro(heading: "Overview", body: "first\nsecond"))

        let res = try await exportProject(dir: dir, manifest: m, format: .html, generatedAt: fixedDate)
        XCTAssertTrue(res.outputPath.hasSuffix("/export/My SOP.html"))
        let html = try String(contentsOfFile: res.outputPath, encoding: .utf8)

        XCTAssertTrue(html.contains("<div class=\"step__num\">1</div>"))  // shot = 1
        XCTAssertTrue(html.contains("<div class=\"step__num\">2</div>"))  // text = 2
        XCTAssertFalse(html.contains("<div class=\"step__num\">3</div>")) // no 3rd number
        XCTAssertTrue(html.contains("step__num--warning"))               // callout badge
        XCTAssertTrue(html.contains("Click &lt;b&gt;Save&lt;/b&gt;"))    // caption escaped
        XCTAssertTrue(html.contains("data:image/png;base64,"))           // inlined image
        XCTAssertTrue(html.contains("class=\"doc__intro-b\">first<br>second<")) // intro br
        XCTAssertTrue(html.contains(DOC_CSS))
    }

    func testPlainHtmlIsSemanticWithArialCss() async throws {
        let dir = try makeProjectDir()
        XCTAssertTrue(writePNG((dir as NSString).appendingPathComponent("shots/a.png"), w: 20, h: 20))
        let m = manifest([
            shotStep(id: "s1", order: 0, screenshot: "shots/a.png", caption: "Cap", body: "b"),
            textStep(id: "c1", order: 1, heading: "Note", body: "n", callout: .note),
        ])
        let res = try await exportProject(dir: dir, manifest: m, format: .htmlPlain, generatedAt: fixedDate)
        XCTAssertTrue(res.outputPath.hasSuffix("/export/My SOP-plain.html"))
        let html = try String(contentsOfFile: res.outputPath, encoding: .utf8)
        // Now carries the minimal Arial stylesheet (parity with Windows PLAIN_CSS)…
        XCTAssertTrue(html.contains("<style>"))
        XCTAssertTrue(html.contains("font-family:Arial"))
        // …but the markup stays class/inline-style-free so it still pastes cleanly.
        XCTAssertFalse(html.contains("class="))
        XCTAssertFalse(html.contains("style=\""))
        XCTAssertTrue(html.contains("<h1>My SOP</h1>"))
        XCTAssertTrue(html.contains("<blockquote><p><strong>ℹ Note</strong>"))
        XCTAssertTrue(html.contains("<h2>1. Cap</h2>"))
    }

    // MARK: - Markdown export

    func testMarkdownExportWritesImages() async throws {
        let dir = try makeProjectDir()
        XCTAssertTrue(writePNG((dir as NSString).appendingPathComponent("shots/a.png"), w: 20, h: 20))
        let m = manifest([
            shotStep(id: "abc", order: 0, screenshot: "shots/a.png", caption: "Cap*ital", body: "raw *body*"),
        ])
        let res = try await exportProject(dir: dir, manifest: m, format: .markdown, generatedAt: fixedDate)
        XCTAssertTrue(res.outputPath.hasSuffix("/export/My SOP.md"))
        let md = try String(contentsOfFile: res.outputPath, encoding: .utf8)
        XCTAssertTrue(md.contains("## 1. Cap\\*ital"))         // heading escaped
        XCTAssertTrue(md.contains("raw *body*"))               // body raw
        XCTAssertTrue(md.contains("(<My SOP-images/step-01-abc.png>)"))
        let imgPath = (dir as NSString)
            .appendingPathComponent("export/My SOP-images/step-01-abc.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imgPath))
    }

    // MARK: - Fail-closed gate

    func testUnbakedRedactionRefused() async throws {
        let dir = try makeProjectDir()
        XCTAssertTrue(writePNG((dir as NSString).appendingPathComponent("shots/a.png"), w: 20, h: 20))
        // A crop with no flattened render must be refused (never read the raw shot).
        let m = manifest([
            shotStep(id: "s1", order: 0, screenshot: "shots/a.png",
                     caption: "secret", crop: Rect(x: 0, y: 0, width: 5, height: 5)),
        ])
        do {
            _ = try await exportProject(dir: dir, manifest: m, format: .html, generatedAt: fixedDate)
            XCTFail("expected unbakedRedaction to be thrown")
        } catch let e as RenderGateError {
            guard case .unbakedRedaction = e else { return XCTFail("wrong gate error: \(e)") }
        }
    }

    func testNothingToExport() async throws {
        let dir = try makeProjectDir()
        let m = manifest([textStep(id: "t", order: 0, heading: "", body: "")])
        do {
            _ = try await exportProject(dir: dir, manifest: m, format: .markdown, generatedAt: fixedDate)
            XCTFail("expected nothingToExport")
        } catch let e as ExportError {
            XCTAssertEqual(e, .nothingToExport)
        }
    }
}
