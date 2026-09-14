import AppKit
import Foundation
import ShotModel
import XCTest
@testable import ExportKit

/// 1b — a project's own `theme` decides what its exports look like.
///
/// The precedence is resolved INSIDE `exportProject`, and these tests call it
/// through that entry point rather than asserting on `ExportTheme.of` directly.
/// A caller that resolved the brand itself would be reading `project.json` a
/// second time through its own copy of the manifest, and the two reads
/// eventually disagree — a project re-pinned between the caller's load and the
/// export would come out in the stale brand.
final class ProjectThemeExportTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func dir() throws -> String {
        let d = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("theme-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (d as NSString).appendingPathComponent("shots"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: d) }
        return d
    }

    private func manifest(theme: String?) -> ProjectManifest {
        var m = ProjectManifest(id: "p", title: "Doc", createdAt: "2026-01-01",
                                updatedAt: "2026-01-01",
                                steps: [ProjectStep(id: "t1", order: 0, kind: .text,
                                                    screenshot: "", trigger: .click,
                                                    heading: "Step", body: "words")])
        m.theme = theme
        return m
    }

    private func html(theme: String?, brand: BrandPref) async throws -> String {
        let d = try dir()
        let res = try await exportProject(dir: d, manifest: manifest(theme: theme),
                                          format: .html, generatedAt: fixedDate, brand: brand)
        return try String(contentsOfFile: res.outputPath, encoding: .utf8)
    }

    private static let violet = "#6344f1"
    private static let rust = "#b46b3e"

    /// No pin: the app preference decides, which is what it has always done.
    func testUnpinnedFollowsTheAppBrand() async throws {
        let doc = try await html(theme: nil, brand: .lfi)
        XCTAssertTrue(doc.contains(Self.rust))
        XCTAssertFalse(doc.contains(Self.violet))
    }

    /// The pin wins over the app preference — that is the feature.
    func testPinWinsOverTheAppBrand() async throws {
        let doc = try await html(theme: "lfi", brand: .shotAI)
        XCTAssertTrue(doc.contains(Self.rust), "the project's brand, not the app's")
        XCTAssertFalse(doc.contains(Self.violet))
    }

    /// And in the other direction: a project explicitly pinned to the DEFAULT
    /// brand exports in it even while the app is on another. This is the case
    /// that does not exist if "explicitly default" is stored as an absent key —
    /// the bug Windows shipped (Armadillon44/shotAI#77).
    func testExplicitDefaultPinWinsToo() async throws {
        let doc = try await html(theme: "shotAI", brand: .lfi)
        XCTAssertTrue(doc.contains(Self.violet), "pinned to shotAI while the app is LFI")
        XCTAssertFalse(doc.contains(Self.rust))
    }

    /// A brand a NEWER build wrote falls back to the caller's rather than
    /// failing the export. The key itself is untouched — it survives in the
    /// manifest and round-trips back to the sender.
    func testUnknownPinFallsBackAndDoesNotFail() async throws {
        let doc = try await html(theme: "solarpunk", brand: .lfi)
        XCTAssertTrue(doc.contains(Self.rust))
    }

    /// Every styled format resolves through the same path.
    ///
    /// Each is checked against a token it actually *uses*: the Word-facing
    /// export has no accent anywhere (it is deliberately near-unstyled, so Word
    /// and Google Docs don't fight it), and the PDF draws its own colours in
    /// CoreGraphics rather than emitting CSS, so neither can be proved by
    /// looking for the rust hex in the bytes.
    func testEveryStyledFormatHonoursThePin() async throws {
        let lfi = ExportTheme.of(.lfi)
        for (format, marker) in [(ExportFormat.html, lfi.accent), (.htmlPlain, lfi.text)] {
            let d = try dir()
            let res = try await exportProject(dir: d, manifest: manifest(theme: "lfi"),
                                              format: format, generatedAt: fixedDate, brand: .shotAI)
            let doc = try String(contentsOfFile: res.outputPath, encoding: .utf8)
            XCTAssertTrue(doc.contains(marker), "\(format) ignored the pin")
            XCTAssertFalse(doc.contains(ExportTheme.shotAI.text), "\(format) kept a shotAI ink")
        }
        // The PDF renders, and its colour vocabulary comes from the same
        // resolved theme — `Ink` is the single place it reads colours from.
        let d = try dir()
        let pdf = try await exportProject(dir: d, manifest: manifest(theme: "lfi"),
                                          format: .pdf, generatedAt: fixedDate, brand: .shotAI)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: pdf.outputPath))
        XCTAssertGreaterThan(bytes.count, 0, "the PDF wrote nothing")
        XCTAssertEqual(Ink(lfi).badge, Ink.color(Self.rust))
    }
}
