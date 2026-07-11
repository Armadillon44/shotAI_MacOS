import CoreGraphics
import Foundation
import XCTest
@testable import ExportKit
import ShotModel

final class PackageTests: XCTestCase {

    // MARK: - Fixtures

    private func tempDir() -> String {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("pkg-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: d) }
        return d
    }

    private func pngData(w: Int, h: Int) -> Data {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return encodePNG(ctx.makeImage()!)!
    }

    private func writeZip(_ entries: [(String, Data)]) -> String {
        let path = (tempDir() as NSString).appendingPathComponent("pkg.zip")
        try! zipStored(entries).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func markerData(format: String = "shotai-package", version: Int = 1) -> Data {
        try! JSONSerialization.data(withJSONObject: ["format": format, "version": version])
    }

    private func manifestData(screenshot: String) -> Data {
        let m = ProjectManifest(
            id: "src", title: "Imported SOP", createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            steps: [ProjectStep(id: "s1", order: 0, kind: .shot, screenshot: screenshot, trigger: .click, caption: "Cap")])
        return try! ProjectJSON.encodeManifest(m)
    }

    // MARK: - Zip codec

    func testZipStoredRoundTrips() throws {
        let a = pngData(w: 16, h: 16)
        let b = Data("hello \u{1F600} world".utf8)
        let zip = zipStored([("shots/a.png", a), ("project.json", b)])
        let entries = try zipRead(zip, maxEntryBytes: 1_000_000)
        XCTAssertEqual(entries.count, 2)
        let byName = Dictionary(entries.map { ($0.name, $0.data) }, uniquingKeysWith: { x, _ in x })
        XCTAssertEqual(byName["shots/a.png"], a)
        XCTAssertEqual(byName["project.json"], b)
    }

    func testZipListReportsMetadataThenExtract() throws {
        // zipList reads sizes from the directory WITHOUT decompressing; zipExtract
        // then inflates a single chosen entry on demand (the importer's zip-bomb
        // guard relies on this list-then-selective-extract split).
        let payload = Data(repeating: 0x42, count: 4096)
        let zip = zipStored([("shots/a.png", payload), ("project.json", Data("{}".utf8))])
        let items = try zipList(zip)
        XCTAssertEqual(Set(items.map(\.name)), ["shots/a.png", "project.json"])
        let shot = items.first { $0.name == "shots/a.png" }!
        XCTAssertEqual(shot.uncompressedSize, 4096)
        XCTAssertEqual(try zipExtract(zip, shot), payload)
    }

    func testZipReadsRealDeflateZip() throws {
        // A zip produced by /usr/bin/zip is DEFLATE-compressed — exercises the
        // inflate path (the format Windows' JSZip emits).
        let dir = tempDir()
        let payload = Data(repeating: 0x41, count: 5000) // compresses well
        try payload.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("data.bin")))
        let zipPath = (dir as NSString).appendingPathComponent("real.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.arguments = ["-q", "real.zip", "data.bin"]
        try p.run(); p.waitUntilExit()
        try XCTSkipUnless(p.terminationStatus == 0, "/usr/bin/zip unavailable")
        let data = try Data(contentsOf: URL(fileURLWithPath: zipPath))
        let entries = try zipRead(data, maxEntryBytes: 1_000_000)
        let match = entries.first { $0.name == "data.bin" }
        XCTAssertEqual(match?.data, payload)  // inflated back to the original
    }

    // MARK: - Package round trip

    func testSafePackageRoundTrips() async throws {
        let root = tempDir()
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let created = try await store.createProject(title: "Round Trip")
        _ = try await store.importImageStep(at: created.path, atIndex: nil, imageData: pngData(w: 40, h: 30))
        let opened = try await store.openProject(at: created.path)

        let result = try exportPackage(dir: opened.dir, manifest: opened.manifest, includeOriginals: false)
        XCTAssertTrue(result.outputPath.hasSuffix("(shotAI package).zip"))
        XCTAssertFalse(result.includeOriginals)

        let importedSummary = try await importPackage(zipPath: result.outputPath, into: store)
        let imported = try await store.openProject(at: importedSummary.path)
        XCTAssertEqual(imported.manifest.steps.count, 1)
        XCTAssertNotEqual(imported.manifest.id, opened.manifest.id) // fresh id
        let rel = imported.manifest.steps[0].screenshot
        XCTAssertTrue(rel.hasPrefix("shots/step-"))
        let abs = (imported.dir as NSString).appendingPathComponent(rel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: abs))
    }

    // MARK: - Untrusted-input rejections

    func testRejectsMissingMarker() async throws {
        let store = ProjectStore(settings: InMemorySettings(projectsDir: tempDir()))
        let zip = writeZip([("project.json", manifestData(screenshot: "shots/step-0001.png")),
                            ("shots/step-0001.png", pngData(w: 8, h: 8))])
        await assertThrows(PackageError.notAPackage) { try await importPackage(zipPath: zip, into: store) }
    }

    func testRejectsWrongFormat() async throws {
        let store = ProjectStore(settings: InMemorySettings(projectsDir: tempDir()))
        let zip = writeZip([
            ("shotai-package.json", markerData(format: "not-shotai")),
            ("project.json", manifestData(screenshot: "shots/step-0001.png")),
        ])
        await assertThrows(PackageError.unrecognizedFormat) { try await importPackage(zipPath: zip, into: store) }
    }

    func testRejectsTooNewVersion() async throws {
        let store = ProjectStore(settings: InMemorySettings(projectsDir: tempDir()))
        let zip = writeZip([
            ("shotai-package.json", markerData(version: 999)),
            ("project.json", manifestData(screenshot: "shots/step-0001.png")),
        ])
        await assertThrows(PackageError.tooNew) { try await importPackage(zipPath: zip, into: store) }
    }

    func testRejectsNonImageInShots() async throws {
        let store = ProjectStore(settings: InMemorySettings(projectsDir: tempDir()))
        let zip = writeZip([
            ("shotai-package.json", markerData()),
            ("project.json", manifestData(screenshot: "shots/step-0001.png")),
            ("shots/step-0001.png", Data("not really a png".utf8)),
        ])
        await assertThrows(PackageError.nonImage("shots/step-0001.png")) { try await importPackage(zipPath: zip, into: store) }
    }

    func testIgnoresZipSlipEntry() async throws {
        let root = tempDir()
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        // A traversal entry must be silently ignored (never extracted), while the
        // legitimate content still imports.
        let zip = writeZip([
            ("shotai-package.json", markerData()),
            ("project.json", manifestData(screenshot: "shots/step-0001.png")),
            ("shots/step-0001.png", pngData(w: 8, h: 8)),
            ("shots/../../../evil.png", pngData(w: 8, h: 8)),
        ])
        let summary = try await importPackage(zipPath: zip, into: store)
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.path)) // imported ok
        // The traversal target (outside the projects root) must not exist.
        let escaped = ((root as NSString).deletingLastPathComponent as NSString).appendingPathComponent("evil.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped))
    }

    // MARK: - helper

    private func assertThrows<T>(
        _ expected: PackageError, _ body: () async throws -> T,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let e as PackageError {
            XCTAssertEqual(e, expected, file: file, line: line)
        } catch {
            XCTFail("wrong error: \(error)", file: file, line: line)
        }
    }
}
