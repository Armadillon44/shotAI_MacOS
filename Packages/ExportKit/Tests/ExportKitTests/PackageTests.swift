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

    /// The screenshot frame is an ordinary project setting, not private author
    /// data: a recipient sees the project framed as the sender did.
    func testAPackageKeepsTheProjectsFrame() async throws {
        let root = tempDir()
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let created = try await store.createProject(title: "Framed")
        _ = try await store.importImageStep(at: created.path, atIndex: nil, imageData: pngData(w: 40, h: 30))
        _ = try await store.setShotFrame(at: created.path, ShotFrame(rawValue: "5:4"))
        let opened = try await store.openProject(at: created.path)
        let result = try exportPackage(dir: opened.dir, manifest: opened.manifest, includeOriginals: false)
        let entries = try zipRead(Data(contentsOf: URL(fileURLWithPath: result.outputPath)), maxEntryBytes: 10_000_000)
        let manifestJSON = String(decoding: try XCTUnwrap(entries.first { $0.name == "project.json" }?.data), as: UTF8.self)
        XCTAssertTrue(manifestJSON.contains("\"shotFrame\":\"5:4\"") || manifestJSON.contains("\"shotFrame\" : \"5:4\""))

        let summary = try await store.createProjectFromImport(manifest: opened.manifest, files: [])
        let imported = try await store.openProject(at: summary.path)
        XCTAssertEqual(imported.manifest.shotFrame, "5:4", "and an import keeps it")
    }

    /// A safe package drops the click (its ring is baked into the image), but a
    /// framed step with no saved pan is positioned on that click. The package
    /// writes the pan the click gives, so the recipient sees the same framing.
    func testASafePackageKeepsAFramedStepCentredOnItsClick() throws {
        // A 1600x1000 render, 1:1 frame at docScale 1 (box 600x600): fill is 1.6.
        let render = pngData(w: 1600, h: 1000)
        var step = ProjectStep(id: "s", order: 1, kind: .shot, screenshot: "shots/1.png", trigger: .hotkey)
        step.click = StepClick(global: Point(x: 0, y: 0), image: Point(x: 1500, y: 500), button: .left)
        step.reportZoom = 1.6
        let frame = try XCTUnwrap(ShotFrame(rawValue: "1:1"))

        var zoomed = step
        keepClickCentredPan(&zoomed, render: render, frame: frame, docScale: nil)
        XCTAssertEqual(zoomed.reportPanX, 1, "the click is near the right edge: clamped there")
        XCTAssertEqual(zoomed.reportPanY, 0.5)

        var atFit = step
        atFit.reportZoom = nil
        keepClickCentredPan(&atFit, render: render, frame: frame, docScale: nil)
        XCTAssertEqual(atFit.reportPanX, 1, "at fit, the pan the first zoom-in (fill) will use")

        var saved = step
        saved.reportPanX = 0.2; saved.reportPanY = 0.3
        keepClickCentredPan(&saved, render: render, frame: frame, docScale: nil)
        XCTAssertEqual([saved.reportPanX, saved.reportPanY], [0.2, 0.3], "a saved pan is the author's")
        // Between fit and fill (a zoom kept when the frame changed): the pan at
        // the step's own zoom, the one the sender's exports use, not the fill
        // zoom's. The verification finding: the recipient framed it 47 px off.
        var between = step
        between.reportZoom = 1.25
        between.click = StepClick(global: Point(x: 0, y: 0), image: Point(x: 900, y: 500), button: .left)
        let box = try XCTUnwrap(FrameGeometry.projectBox(frame: frame, docScale: nil))
        let sender = FrameGeometry.pan(for: between, imageWidth: 1600, imageHeight: 1000, box: box)
        keepClickCentredPan(&between, render: render, frame: frame, docScale: nil)
        XCTAssertEqual(between.reportPanX, 0.8125)
        XCTAssertEqual(between.reportPanX, sender.x)
        let sent = FrameGeometry.exportLayout(imageWidth: 1600, imageHeight: 1000, box: box, zoom: 1.25,
                                              panX: sender.x, panY: sender.y)
        let received = FrameGeometry.exportLayout(imageWidth: 1600, imageHeight: 1000, box: box, zoom: 1.25,
                                                  panX: between.reportPanX!, panY: between.reportPanY!)
        XCTAssertEqual(sent, received, "the recipient exports what the sender did")

        var half = step
        half.reportPanX = 0.2   // one axis saved (a hand edit, or another build)
        keepClickCentredPan(&half, render: render, frame: frame, docScale: nil)
        XCTAssertEqual([half.reportPanX, half.reportPanY], [0.2, 0.5], "only the missing axis is filled in")

        var unframed = step
        keepClickCentredPan(&unframed, render: render, frame: nil, docScale: nil)
        XCTAssertNil(unframed.reportPanX, "an unframed project's packages are unchanged")

        var cropped = step
        cropped.crop = Rect(x: 1000, y: 0, width: 600, height: 600)   // render is the crop
        cropped.reportZoom = 1
        keepClickCentredPan(&cropped, render: pngData(w: 600, h: 600), frame: frame, docScale: nil)
        XCTAssertEqual(cropped.reportPanX, 0.5, "a crop of the frame's shape has nothing to pan: centred")
    }

    func testTheWholePackageCarriesThePan() async throws {
        let root = tempDir()
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let created = try await store.createProject(title: "Framed click")
        _ = try await store.importImageStep(at: created.path, atIndex: nil, imageData: pngData(w: 1600, h: 1000))
        _ = try await store.setShotFrame(at: created.path, ShotFrame(rawValue: "1:1"))
        var opened = try await store.openProject(at: created.path)
        var manifest = opened.manifest
        manifest.steps[0].click = StepClick(global: Point(x: 0, y: 0), image: Point(x: 100, y: 900), button: .left)
        manifest.steps[0].reportZoom = 1.6
        let result = try exportPackage(dir: opened.dir, manifest: manifest, includeOriginals: false)
        let entries = try zipRead(Data(contentsOf: URL(fileURLWithPath: result.outputPath)), maxEntryBytes: 10_000_000)
        let json = try XCTUnwrap(entries.first { $0.name == "project.json" }?.data)
        let shipped = try JSONDecoder().decode(ProjectManifest.self, from: json)
        XCTAssertNil(shipped.steps[0].click)
        XCTAssertEqual(shipped.steps[0].reportPanX, 0, "a click at the left edge")
        XCTAssertEqual(shipped.steps[0].reportPanY, 0.5)
        opened = try await store.openProject(at: created.path)
        XCTAssertNil(opened.manifest.steps[0].reportPanX, "the sender's project is not touched")
    }

    /// The per-block record of what generation wrote, and the words it wrote from, is
    /// the sender's local history like sopBackup. It can hold wording the sender has
    /// since changed or deleted, so it never leaves in a package — and is dropped on
    /// import too, for packages built by something that did not strip it.
    func testAPackageCarriesNoRecordOfWhatGenerationWrote() async throws {
        let root = tempDir()
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let created = try await store.createProject(title: "Records")
        _ = try await store.importImageStep(at: created.path, atIndex: nil, imageData: pngData(w: 40, h: 30))
        _ = try await store.addTextStep(at: created.path, atIndex: 0, heading: "Key", body: "Polished.", callout: .warning)
        _ = try await store.mutate(at: created.path) { m in
            m.steps[0].sopRewrite = SopTextRewrite(heading: "Key", body: "Polished.",
                                                   sourceHeading: "Key", sourceBody: "Call Bob on 555-0100.")
        }
        let opened = try await store.openProject(at: created.path)
        let result = try exportPackage(dir: opened.dir, manifest: opened.manifest, includeOriginals: false)
        let entries = try zipRead(Data(contentsOf: URL(fileURLWithPath: result.outputPath)), maxEntryBytes: 10_000_000)
        let manifestJSON = String(decoding: try XCTUnwrap(entries.first { $0.name == "project.json" }?.data), as: UTF8.self)
        XCTAssertFalse(manifestJSON.contains("sopRewrite"))
        XCTAssertFalse(manifestJSON.contains("555-0100"), "the sender's pre-generation wording does not ship")

        var crafted = opened.manifest
        crafted.steps[0].sopRewrite = SopTextRewrite(heading: "Key", body: "Polished.", sourceHeading: nil, sourceBody: "hidden")
        let summary = try await store.createProjectFromImport(manifest: crafted, files: [])
        let imported = try await store.openProject(at: summary.path)
        XCTAssertNil(imported.manifest.steps[0].sopRewrite, "and an import drops one that arrives anyway")
    }

    /// The Generate dialog's remembered instructions are notes to Claude that appear
    /// nowhere in the SOP, so a sender checking what they share never sees them.
    /// They do not ship, and an import drops any that arrive anyway.
    func testAPackageCarriesNoRememberedGenerateInstructions() async throws {
        let root = tempDir()
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let created = try await store.createProject(title: "Instructions")
        _ = try await store.importImageStep(at: created.path, atIndex: nil, imageData: pngData(w: 40, h: 30))
        try await store.setSopRunOptions(at: created.path,
                                         SopRunOptions(wording: .general, instructions: "Never name Contoso."))
        let opened = try await store.openProject(at: created.path)
        XCTAssertNotNil(opened.manifest.sopRunOptions)
        let result = try exportPackage(dir: opened.dir, manifest: opened.manifest, includeOriginals: false)
        let entries = try zipRead(Data(contentsOf: URL(fileURLWithPath: result.outputPath)), maxEntryBytes: 10_000_000)
        let manifestJSON = String(decoding: try XCTUnwrap(entries.first { $0.name == "project.json" }?.data), as: UTF8.self)
        XCTAssertFalse(manifestJSON.contains("sopRunOptions"))
        XCTAssertFalse(manifestJSON.contains("Contoso"))

        let summary = try await store.createProjectFromImport(manifest: opened.manifest, files: [])
        let imported = try await store.openProject(at: summary.path)
        XCTAssertNil(imported.manifest.sopRunOptions, "and an import drops them if they arrive anyway")
    }

    /// The record of the title generation wrote is local history, like sopBackup:
    /// neither shipped nor kept on import.
    func testAPackageCarriesNoRecordOfTheGeneratedTitle() async throws {
        let root = tempDir()
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let created = try await store.createProject(title: "Record")
        _ = try await store.importImageStep(at: created.path, atIndex: nil, imageData: pngData(w: 40, h: 30))
        let opened = try await store.openProject(at: created.path)
        var manifest = opened.manifest
        manifest.sopTitleRewrite = "Generated title"
        let result = try exportPackage(dir: opened.dir, manifest: manifest, includeOriginals: false)
        let entries = try zipRead(Data(contentsOf: URL(fileURLWithPath: result.outputPath)), maxEntryBytes: 10_000_000)
        let manifestJSON = String(decoding: try XCTUnwrap(entries.first { $0.name == "project.json" }?.data), as: UTF8.self)
        XCTAssertFalse(manifestJSON.contains("sopTitleRewrite"))

        let summary = try await store.createProjectFromImport(manifest: manifest, files: [])
        let imported = try await store.openProject(at: summary.path)
        XCTAssertNil(imported.manifest.sopTitleRewrite)
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
