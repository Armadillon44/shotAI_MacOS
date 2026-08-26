import CoreGraphics
import Foundation
import ShotModel
import XCTest
@testable import ExportKit

/// #83 — the per-project document scale, as the exports see it.
///
/// The invariant that matters most is "the image is never wider than its
/// container, at EVERY detent". On Windows the equivalent bug was invisible at
/// 100% (where the base image sat inside every candidate ceiling) and only
/// appeared at 125%, so a visual check at the default scale proves nothing.
final class DocScaleExportTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func dir() throws -> String {
        let d = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("docscale-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (d as NSString).appendingPathComponent("shots"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: d) }
        return d
    }

    /// A WIDE capture, so the ceiling actually binds at every scale.
    @discardableResult
    private func png(_ path: String, w: Int = 2400, h: Int = 1400) -> Bool {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage(), let d = encodePNG(img) else { return false }
        return (try? d.write(to: URL(fileURLWithPath: path))) != nil
    }

    private func project(scale: Double?) throws -> (String, ProjectManifest) {
        let d = try dir()
        XCTAssertTrue(png((d as NSString).appendingPathComponent("shots/a.png")))
        var m = ProjectManifest(id: "p", title: "T", createdAt: "2026-01-01T00:00:00Z",
                                updatedAt: "2026-01-01T00:00:00Z",
                                steps: [ProjectStep(id: "a", order: 0, kind: .shot,
                                                    screenshot: "shots/a.png", trigger: .click)])
        m.displayScale = scale
        return (d, m)
    }

    private func widthAttr(_ html: String) -> Int? {
        guard let r = html.range(of: #"width="(\d+)""#, options: .regularExpression) else { return nil }
        return Int(html[r].dropFirst(7).dropLast(1))
    }

    /// THE invariant. Every detent, styled export.
    func testImageNeverExceedsItsColumnAtAnyDetent() async throws {
        for s in DocScale.detents {
            let (d, m) = try project(scale: s)
            let html = try String(contentsOfFile:
                try await exportProject(dir: d, manifest: m, format: .html, generatedAt: fixedDate).outputPath,
                encoding: .utf8)
            let ceiling = DocScale.htmlImageMax(s)
            XCTAssertTrue(html.contains("max-width:\(DocScale.htmlColumn(s))px"),
                          "column must carry the scaled width at \(s)")
            let w = try XCTUnwrap(widthAttr(html), "no width attribute at \(s)")
            XCTAssertLessThanOrEqual(w, ceiling, "image \(w) exceeds its \(ceiling) container at \(s)")
        }
    }

    func testPlainExportScalesBodyAndImageAttributes() async throws {
        for s in [0.65, 1.0, 1.25] {
            let (d, m) = try project(scale: s)
            let html = try String(contentsOfFile:
                try await exportProject(dir: d, manifest: m, format: .htmlPlain, generatedAt: fixedDate).outputPath,
                encoding: .utf8)
            XCTAssertTrue(html.contains("max-width:\(DocScale.plainBody(s))px"))
            let w = try XCTUnwrap(widthAttr(html))
            XCTAssertLessThanOrEqual(w, DocScale.htmlImageMax(s))
        }
    }

    /// The compatibility promise: absent and an explicit 1.0 must be identical,
    /// and identical to the pre-feature output.
    func testUnityIsIndistinguishableFromAbsent() async throws {
        func html(_ scale: Double?) async throws -> String {
            let (d, m) = try project(scale: scale)
            return try String(contentsOfFile:
                try await exportProject(dir: d, manifest: m, format: .html, generatedAt: fixedDate).outputPath,
                encoding: .utf8)
        }
        let absent = try await html(nil), unity = try await html(1.0)
        XCTAssertEqual(absent, unity)
        XCTAssertTrue(absent.contains("max-width:816px"), "the pre-feature column, unchanged")
        XCTAssertTrue(absent.contains("width=\"738\""), "the pre-feature image ceiling")
    }

    /// Every column-carrying block must move together — including under
    /// `@media print`. Miss one and a printed page renders at the screen column.
    func testEveryColumnBlockMovesTogether() async throws {
        let css = docCSS(scale: 1.25)
        let col = DocScale.htmlColumn(1.25)
        for sel in [".doc__col{", ".doc__title{", ".doc__meta{", ".doc__intro{", ".step{", ".section{"] {
            let line = try XCTUnwrap(css.split(separator: "\n").first { $0.hasPrefix(sel) }, "missing \(sel)")
            XCTAssertTrue(line.contains("max-width:\(col)px"), "\(sel) did not scale")
        }
        let printRule = try XCTUnwrap(css.split(separator: "\n").first { $0.hasPrefix("@media print") })
        for sel in ["doc__col", "doc__title", "doc__meta", "doc__intro", ".step", ".section"] {
            XCTAssertTrue(printRule.contains(sel), "print reset misses \(sel)")
        }
    }

    /// macOS embeds at 1x by decision (#64) — resampling to 2x was measured to
    /// save nothing, because interpolation blurs the flat colour runs screenshots
    /// are made of. Pinned so nobody "fixes" it toward the Windows @2x contract
    /// without redoing that measurement.
    func testEmbedsAtOneXNotTwo() async throws {
        let (d, m) = try project(scale: 1.0)
        let html = try String(contentsOfFile:
            try await exportProject(dir: d, manifest: m, format: .html, generatedAt: fixedDate).outputPath,
            encoding: .utf8)
        XCTAssertEqual(widthAttr(html), 738)
        XCTAssertNotEqual(widthAttr(html), DocScale.embedTarget(1.0))
    }
}
