import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ExportKit
import ShotModel

/// Exports of a framed project (Armadillon44/shotAI#160): each shot becomes the
/// region the report shows, on a transparent canvas of the frame's shape, and
/// every frame is shown at the same size.
final class FramedExportTests: XCTestCase {

    // MARK: Fixtures

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let red: [UInt8] = [220, 20, 20, 255]
    private let blue: [UInt8] = [20, 20, 220, 255]

    private func tempDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("framed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: (dir as NSString).appendingPathComponent("shots"),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// A w×h sRGB image, red left of `split` and blue from it on.
    private func twoTone(w: Int, h: Int, split: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: srgb, components: [220 / 255, 20 / 255, 20 / 255, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: split, height: h))
        ctx.setFillColor(CGColor(colorSpace: srgb, components: [20 / 255, 20 / 255, 220 / 255, 1])!)
        ctx.fill(CGRect(x: split, y: 0, width: w - split, height: h))
        return ctx.makeImage()!
    }

    @discardableResult
    private func write(_ image: CGImage, to path: String) throws -> String {
        try XCTUnwrap(encodePNG(image)).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// RGBA of every pixel, top-left first.
    private func pixels(_ png: Data) throws -> (w: Int, h: Int, rgba: [UInt8]) {
        let src = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = try XCTUnwrap(CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                                          bytesPerRow: img.width * 4, space: srgb,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return (img.width, img.height, buf)
    }

    private func at(_ p: (w: Int, h: Int, rgba: [UInt8]), _ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * p.w + x) * 4
        return Array(p.rgba[i..<i + 4])
    }

    private func shot(_ screenshot: String, zoom: Double? = nil, panX: Double? = nil, panY: Double? = nil,
                      click: (Double, Double)? = nil) -> ProjectStep {
        var s = ProjectStep(id: UUID().uuidString, order: 1, kind: .shot, screenshot: screenshot, trigger: .click)
        s.reportZoom = zoom; s.reportPanX = panX; s.reportPanY = panY
        if let c = click { s.click = StepClick(global: Point(x: 0, y: 0), image: Point(x: c.0, y: c.1), button: .left) }
        return s
    }

    private func manifest(_ steps: [ProjectStep], frame: String?) -> ProjectManifest {
        var m = ProjectManifest(id: "p", title: "Framed", createdAt: "2026-01-01T00:00:00Z",
                                updatedAt: "2026-01-01T00:00:00Z", steps: steps)
        m.shotFrame = frame
        return m
    }

    // MARK: Composition

    /// Fit: the whole image, padded above and below, the padding transparent and
    /// the image copied pixel for pixel. 99 rows in a 160 canvas pads 30 above
    /// and 31 below, so an image drawn the wrong way up would show.
    func testFitPadsWithTransparencyAndKeepsThePixels() throws {
        let dir = try tempDir()
        let path = try write(twoTone(w: 160, h: 99, split: 80), to: "\(dir)/shots/a.png")
        let box = FrameGeometry.Size(width: 60, height: 60)   // fit 0.375: canvas 160x160, origin (0, 30)
        let png = try XCTUnwrap(framedPNG(path: path, step: shot("shots/a.png"), box: box))
        let p = try pixels(png)
        XCTAssertEqual([p.w, p.h], [160, 160])
        XCTAssertEqual(at(p, 5, 29)[3], 0, "top padding is transparent")
        XCTAssertEqual(at(p, 5, 30), red, "the image starts right below the padding")
        XCTAssertEqual(at(p, 79, 128), red, "and ends 99 rows later")
        XCTAssertEqual(at(p, 79, 129)[3], 0, "bottom padding is transparent")
        XCTAssertEqual(at(p, 80, 30), blue, "copied pixel for pixel, no smoothing at the seam")
        XCTAssertEqual(at(p, 159, 128), blue)
    }

    /// Fill, centred on a click near the right edge: the view clamps to the right.
    func testFillFollowsTheClickClampedAtTheEdge() throws {
        let dir = try tempDir()
        let path = try write(twoTone(w: 160, h: 100, split: 80), to: "\(dir)/shots/a.png")
        let box = FrameGeometry.Size(width: 60, height: 60)   // fill zoom 1.6: a 100x100 view
        let png = try XCTUnwrap(framedPNG(path: path, step: shot("shots/a.png", zoom: 1.6, click: (150, 50)), box: box))
        let p = try pixels(png)
        XCTAssertEqual([p.w, p.h], [100, 100], "a plain crop: the image covers the frame")
        XCTAssertEqual(at(p, 10, 50), red, "x 70 of the render")
        XCTAssertEqual(at(p, 30, 50), blue, "x 90 of the render: the view is x 60..160")
        XCTAssertEqual(at(p, 99, 99)[3], 255)
    }

    func testASavedPanWinsOverTheClick() throws {
        let dir = try tempDir()
        let path = try write(twoTone(w: 160, h: 100, split: 80), to: "\(dir)/shots/a.png")
        let box = FrameGeometry.Size(width: 60, height: 60)
        let png = try XCTUnwrap(framedPNG(path: path, step: shot("shots/a.png", zoom: 1.6, panX: 0, panY: 0.5,
                                                                click: (150, 50)), box: box))
        let p = try pixels(png)
        XCTAssertEqual(at(p, 79, 50), red, "x 0..100 of the render")
        XCTAssertEqual(at(p, 99, 50), blue)
    }

    /// An image of the frame's shape at fit is the framed image already.
    func testARenderOfTheFramesShapeAtFitIsUsedAsIs() throws {
        let dir = try tempDir()
        let path = try write(twoTone(w: 120, h: 120, split: 60), to: "\(dir)/shots/a.png")
        XCTAssertNil(framedPNG(path: path, step: shot("shots/a.png"), box: FrameGeometry.Size(width: 60, height: 60)))
    }

    /// Ordinary captures stay pixel for pixel: a 6K display's capture (5114 px
    /// wide after the 0.85 downscale) padded to 1:1 is inside the budget. The
    /// verification finding: at 4096² a 5K or 6K shot was resampled.
    func testTheBudgetFitsA6KCaptureInASquareFrame() {
        XCTAssertGreaterThanOrEqual(framedCanvasPixelBudget, 5114 * 5114)
        XCTAssertLessThanOrEqual(framedCanvasPixelBudget, 6144 * 6144, "and stays bounded (about 150 MB)")
    }

    /// A canvas over the budget is drawn scaled down, not allocated in full.
    func testAnOversizedCanvasIsScaledDown() throws {
        let layout = try XCTUnwrap(FrameGeometry.exportLayout(imageWidth: 160, imageHeight: 100,
                                                              box: FrameGeometry.Size(width: 60, height: 60),
                                                              zoom: 1, panX: 0.5, panY: 0.5))
        let png = try XCTUnwrap(composeFramed(twoTone(w: 160, h: 100, split: 80), layout: layout, pixelBudget: 6400))
        let p = try pixels(png)
        XCTAssertEqual([p.w, p.h], [80, 80], "160x160 into 6400 px: half size, the frame's shape kept")
        XCTAssertEqual(at(p, 2, 2)[3], 0)
        XCTAssertEqual(at(p, 10, 40)[3], 255)
    }

    // MARK: The collector

    func testAFramedProjectExportsFramedImagesAtOneDisplaySize() throws {
        let dir = try tempDir()
        try write(twoTone(w: 1600, h: 1000, split: 800), to: "\(dir)/shots/big.png")
        try write(twoTone(w: 400, h: 300, split: 200), to: "\(dir)/shots/small.png")
        try write(twoTone(w: 1200, h: 1200, split: 600), to: "\(dir)/shots/square.png")
        // The last: a small image zoomed in to fill has FEWER pixels than the frame
        // (a 300x300 view) and must still be shown at the frame's size.
        let m = manifest([shot("shots/big.png"), shot("shots/small.png"), shot("shots/square.png"),
                          shot("shots/small.png", zoom: 2)], frame: "1:1")
        let items = try collectSteps(dir: dir, manifest: m)
        var images: [ExportImage] = []
        for case .shot(_, _, _, _, _, let image) in items { images.append(image) }
        XCTAssertEqual(images.count, 4)
        for image in images { XCTAssertEqual(image.frameDisplayWidth, 600, "the 1:1 project box at scale 1") }

        let big = try pixels(try XCTUnwrap(images[0].croppedBytes))
        XCTAssertEqual([big.w, big.h], [1600, 1600], "fit: padded to the frame's shape at render resolution")
        let small = try pixels(try XCTUnwrap(images[1].croppedBytes))
        XCTAssertEqual([small.w, small.h], [600, 600], "never enlarged: a 400x300 image padded to the 600 frame")
        XCTAssertEqual(at(small, 100, 75)[3], 0, "padding")
        XCTAssertEqual(at(small, 100, 150), red, "the image, centred at 100,150")
        XCTAssertNil(images[2].croppedBytes, "already the frame's shape: the render itself")
        let zoomed = try pixels(try XCTUnwrap(images[3].croppedBytes))
        XCTAssertEqual([zoomed.w, zoomed.h], [300, 300], "fill on a small image: fewer pixels than the frame")

        // HTML shows every frame at the frame's size, whatever its pixels.
        let html = try buildHtmlDoc(manifest: m, items: items, createdLine: "")
        XCTAssertEqual(html.components(separatedBy: "width=\"600\" height=\"600\"").count - 1, 4)
        let plain = try buildPlainHtmlDoc(manifest: m, items: items)
        XCTAssertEqual(plain.components(separatedBy: "width=\"600\" height=\"600\"").count - 1, 4)
        // And an image is resampled only to the frame's width, all it is shown at.
        let b64 = try XCTUnwrap(plain.components(separatedBy: "data:image/png;base64,").dropFirst().first?
            .components(separatedBy: "\"").first)
        let first = try pixels(try XCTUnwrap(Data(base64Encoded: b64)))
        XCTAssertEqual(first.w, 600, "the 1600-wide framed image, resampled to the 600 frame, not the 738 column")
    }

    /// Every format runs on a framed project, end to end through the real entry
    /// point: the framed images go to Markdown as files and into the PDF.
    func testEveryFormatExportsAFramedProject() async throws {
        let dir = try tempDir()
        try write(twoTone(w: 1600, h: 1000, split: 800), to: "\(dir)/shots/big.png")
        try write(twoTone(w: 400, h: 300, split: 200), to: "\(dir)/shots/small.png")
        let m = manifest([shot("shots/big.png", zoom: 1.6, click: (1500, 500)), shot("shots/small.png")], frame: "5:4")
        var markdown = ""
        for format in [ExportFormat.html, .htmlPlain, .markdown, .pdf] {
            let out = try await exportProject(dir: dir, manifest: m, format: format, generatedAt: Date(timeIntervalSince1970: 0))
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.outputPath), "\(format)")
            if format == .markdown { markdown = out.outputPath }
        }
        // Markdown sizes each framed image to the frame (738 wide for 5:4 at scale
        // 1), since its image syntax cannot, so the zoomed one is not drawn
        // smaller than the other.
        let md = try String(contentsOfFile: markdown, encoding: .utf8)
        XCTAssertEqual(md.components(separatedBy: "width=\"738\"").count - 1, 2, md)
        XCTAssertFalse(md.contains("![Screenshot"), "no unsized images")
        // Markdown writes <stem>/<stem>.md beside images/: the framed images, 5:4.
        let imagesDir = ((markdown as NSString).deletingLastPathComponent as NSString).appendingPathComponent("images")
        let files = try FileManager.default.contentsOfDirectory(atPath: imagesDir).sorted()
        XCTAssertEqual(files.count, 2, "\(files)")
        for f in files {
            let p = try pixels(try Data(contentsOf: URL(fileURLWithPath: (imagesDir as NSString).appendingPathComponent(f))))
            XCTAssertEqual(Double(p.w) / Double(p.h), 1.25, accuracy: 0.01, "\(f) has the frame's shape")
        }
    }

    /// Without a frame nothing changes, except that a zoom above the report's
    /// maximum is capped at it, so the export shows what the report shows.
    func testAnUnframedZoomAboveTheReportsMaximumIsCapped() throws {
        let dir = try tempDir()
        try write(twoTone(w: 800, h: 400, split: 400), to: "\(dir)/shots/a.png")
        let items = try collectSteps(dir: dir, manifest: manifest([shot("shots/a.png", zoom: 6)], frame: nil))
        guard case .shot(_, _, _, _, _, let image) = try XCTUnwrap(items.first) else { return XCTFail() }
        XCTAssertNil(image.frameDisplayWidth)
        let p = try pixels(try XCTUnwrap(image.croppedBytes))
        XCTAssertEqual([p.w, p.h], [200, 100], "zoom 4, not 6: a quarter of each side")
    }

    func testAFrameThisBuildCannotParseIsNotApplied() throws {
        let dir = try tempDir()
        try write(twoTone(w: 800, h: 400, split: 400), to: "\(dir)/shots/a.png")
        let items = try collectSteps(dir: dir, manifest: manifest([shot("shots/a.png")], frame: "golden"))
        guard case .shot(_, _, _, _, _, let image) = try XCTUnwrap(items.first) else { return XCTFail() }
        XCTAssertNil(image.croppedBytes)
        XCTAssertNil(image.frameDisplayWidth)
    }
}
