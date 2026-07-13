import Foundation
import Testing
@testable import ShotModel

/// Locates the repo's Windows-created fixture project from the test source path.
enum Fixture {
    static let projectDir: String = {
        // …/Packages/ShotModel/Tests/ShotModelTests/ManifestCodecTests.swift → repo root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.deletingLastPathComponent()
            .appendingPathComponent("Fixtures/b7e2c4d1-9f3a-4e8b-a2c5-6d1f8e9a0b3c")
            .path
    }()

    static func manifestData() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: projectDir + "/project.json"))
    }
}

// The Phase A exit contract: a project.json written by the Windows app decodes
// field-for-field, and re-encoding loses nothing (semantic JSON equality).
@Suite struct ManifestCodecTests {
    @Test func decodesTheWindowsFixtureFieldForField() throws {
        let m = try ProjectJSON.decodeManifest(try Fixture.manifestData())

        #expect(m.version == 1)
        #expect(m.id == "b7e2c4d1-9f3a-4e8b-a2c5-6d1f8e9a0b3c")
        #expect(m.title == "Export the monthly orders report from Acme ERP")
        #expect(m.createdWith == "shotAI")
        #expect(m.createdAt == "2026-06-30T18:22:05.311Z")
        #expect(m.captureSettings?.mode == .auto)
        #expect(m.intro == SopIntro(heading: "Overview", body: "This SOP shows how to export the monthly orders report from Acme ERP in Google Chrome. It takes about two minutes."))
        #expect(m.sopBackup == nil)
        #expect(m.extra.isEmpty)
        #expect(m.steps.count == 5)

        // Step 1 — left click with element + downscaled click coords.
        let s1 = m.steps[0]
        #expect(s1.order == 1)
        #expect(s1.kind == nil) // absent = shot
        #expect(s1.screenshot == "shots/step-0001.png")
        #expect(s1.trigger == .click)
        #expect(s1.click?.button == .left)
        #expect(s1.click?.global == Point(x: 1650, y: 480))
        #expect(s1.click?.image == Point(x: 1403, y: 408))
        #expect(s1.click?.imageScale == 0.85)
        #expect(s1.monitor == CapturedMonitor(id: 1, bounds: Rect(x: 0, y: 0, width: 2560, height: 1440), scaleFactor: 1.25))
        #expect(s1.window?.app == "chrome.exe")
        #expect(s1.element.available)
        #expect(s1.element.name == "Export")
        #expect(s1.element.controlType == "Button")
        #expect(s1.caption == "Click 'Export' button in chrome.exe")
        #expect(s1.crop == nil)
        #expect(s1.annotations.isEmpty)

        // Step 2 — right click, crop, annotations, baked flatten, report zoom.
        let s2 = m.steps[1]
        #expect(s2.click?.button == .right)
        #expect(s2.crop == Rect(x: 200, y: 120, width: 1200, height: 700))
        #expect(s2.flattened == "export/.render/9a1b3c5d-7e2f-4b8a-9c1d-2e4f6a8b0c3e.png")
        #expect(s2.renderRev == 3)
        #expect(s2.markerBaked == true)
        #expect(s2.reportZoom == 1.5)
        #expect(s2.reportPanX == 0.5)
        #expect(s2.reportPanY == 0.4)
        #expect(s2.annotations.count == 3)
        guard case .rect(let rect) = s2.annotations[0],
              case .blur(let blur) = s2.annotations[1],
              case .stamp(let stamp) = s2.annotations[2] else {
            Issue.record("unexpected annotation shapes: \(s2.annotations)")
            return
        }
        #expect(rect.stroke == "#e11d48")
        #expect(rect.cornerRadius == 10)
        #expect(rect.fill == nil)
        #expect(blur.mode == .pixelate)
        #expect(blur.blockSize == 14)
        #expect(stamp.n == 1)
        #expect(stamp.textColor == "#ffffff")

        // Steps 3/4 — plain text step and a note callout.
        #expect(m.steps[2].kind == .text)
        #expect(m.steps[2].heading == "Before you begin")
        #expect(m.steps[2].callout == nil)
        #expect(m.steps[3].kind == .text)
        #expect(m.steps[3].callout == .note)
        #expect(m.steps[3].body == "All amounts are shown in USD.")

        // Step 5 — hotkey capture, no click, element soft-fail shape.
        let s5 = m.steps[4]
        #expect(s5.trigger == .hotkey)
        #expect(s5.click == nil)
        #expect(s5.element == .unavailable)
        #expect(s5.caption == "Capture: Orders · Acme ERP — Google Chrome")
    }

    @Test func roundTripIsLosslessAsSemanticJSON() throws {
        let original = try Fixture.manifestData()
        let decoded = try ProjectJSON.decodeManifest(original)
        let reEncoded = try ProjectJSON.encodeManifest(decoded)

        // Model-level: decode(encode(decode(x))) == decode(x).
        #expect(try ProjectJSON.decodeManifest(reEncoded) == decoded)

        // JSON-level: nothing the Windows app wrote was dropped or altered
        // (key order/whitespace aside). JSONSerialization gives order-insensitive
        // deep equality via NSDictionary.
        let a = try JSONSerialization.jsonObject(with: original) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: reEncoded) as? NSDictionary
        #expect(a == b)
    }

    @Test func unknownStepAndManifestKeysSurviveRoundTrip() throws {
        // A future Windows build adds fields this app doesn't know about — a
        // Mac-side rewrite must not destroy them (the cross-platform promise).
        let json = """
        {
          "version": 1,
          "id": "p1",
          "title": "T",
          "createdWith": "shotAI",
          "createdAt": "", "updatedAt": "",
          "captureSettings": null,
          "futureManifestField": {"nested": [1, 2, 3]},
          "steps": [{
            "id": "s1", "order": 1, "screenshot": "shots/step-0001.png",
            "trigger": "click", "click": null, "monitor": null, "window": null,
            "element": {"available": false, "name": null, "controlType": null, "bounds": null},
            "caption": "", "note": "", "crop": null,
            "annotations": [
              {"id": "a1", "type": "spotlight", "x": 5, "y": 6, "intensity": 0.9}
            ],
            "futureStepField": "keep me"
          }],
          "intro": null,
          "sopBackup": null,
          "archived": false,
          "archivedAt": null
        }
        """
        let m = try ProjectJSON.decodeManifest(Data(json.utf8))
        #expect(m.extra["futureManifestField"] == .object(["nested": .array([.number(1), .number(2), .number(3)])]))
        #expect(m.steps[0].extra["futureStepField"] == .string("keep me"))
        guard case .unknown(let raw) = m.steps[0].annotations[0] else {
            Issue.record("unknown annotation type was not preserved")
            return
        }
        if case .object(let o) = raw {
            #expect(o["type"] == .string("spotlight"))
            #expect(o["intensity"] == .number(0.9))
        } else {
            Issue.record("unknown annotation decoded to a non-object")
        }

        let a = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: ProjectJSON.encodeManifest(m)) as? NSDictionary
        #expect(a == b)
    }

    @Test func corruptFieldsDegradeInsteadOfFailingTheOpen() throws {
        // Mirrors the Windows readManifest/coerce* defensive reads.
        let json = """
        {
          "version": "not-a-number",
          "title": 42,
          "steps": [{"id": "s1", "annotations": "nope"}],
          "intro": {"heading": "", "body": ""},
          "sopBackup": {"steps": "corrupt", "title": "x"}
        }
        """
        let m = try ProjectJSON.decodeManifest(Data(json.utf8))
        #expect(m.version == projectSchemaVersion)
        #expect(m.id == "")
        #expect(m.title == "")
        #expect(m.steps.count == 1)
        #expect(m.steps[0].annotations.isEmpty) // normalizeSteps
        #expect(m.steps[0].element == .unavailable)
        #expect(m.intro == nil) // both-empty intro coerces to nil
        #expect(m.sopBackup == nil) // corrupt steps → whole backup dropped
    }

    @Test func emptyTitleFallsBackToFolderNameOnStoreRead() async throws {
        let root = NSTemporaryDirectory() + "shotai-title-\(UUID().uuidString)"
        let dir = root + "/My Legacy Project"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "steps": []}"#.utf8)
            .write(to: URL(fileURLWithPath: dir + "/project.json"))
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let opened = try await store.openProject(at: dir)
        #expect(opened.manifest.title == "My Legacy Project")
        // Missing id was back-filled and persisted, exactly once, on open.
        #expect(!opened.manifest.id.isEmpty)
        let reread = try ProjectJSON.decodeManifest(Data(contentsOf: URL(fileURLWithPath: dir + "/project.json")))
        #expect(reread.id == opened.manifest.id)
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func storeOpensAndListsTheFixtureViaRecents() async throws {
        // The app's "Open Project…" flow: a user-picked folder outside the
        // projects root becomes known via recents, then lists and opens.
        let root = NSTemporaryDirectory() + "shotai-open-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let opened = try await store.openUserSelectedProject(at: Fixture.projectDir)
        #expect(opened.manifest.steps.count == 5)
        #expect(opened.dir == Fixture.projectDir)
        let listed = await store.listProjects()
        #expect(listed.map(\.path) == [Fixture.projectDir])
        #expect(listed[0].stepCount == 5)
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func storeListsAndOpensTheFixtureUnderTheProjectsRoot() async throws {
        // The app's launch path: the fixture sits inside the projects root
        // (exactly how a Windows-created folder lands in ~/shotAI Projects).
        let root = NSTemporaryDirectory() + "shotai-root-\(UUID().uuidString)"
        let dest = root + "/b7e2c4d1-9f3a-4e8b-a2c5-6d1f8e9a0b3c"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: Fixture.projectDir, toPath: dest)
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let listed = await store.listProjects()
        #expect(listed.map(\.path) == [dest])
        #expect(listed[0].title == "Export the monthly orders report from Acme ERP")
        #expect(listed[0].stepCount == 5)
        let opened = try await store.openProject(at: dest)
        #expect(opened.manifest.steps.count == 5)
        // Opening an id-bearing project must NOT rewrite the Windows file.
        let after = try Data(contentsOf: URL(fileURLWithPath: dest + "/project.json"))
        #expect(after == (try Data(contentsOf: URL(fileURLWithPath: Fixture.projectDir + "/project.json"))))
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func fixtureImagePathsConfineAndExist() throws {
        // Every image referenced by the fixture manifest must resolve INSIDE the
        // project folder (the read-side confinement the viewer relies on) and
        // exist on disk.
        let m = try ProjectJSON.decodeManifest(try Fixture.manifestData())
        for step in m.steps {
            for rel in [step.screenshot, step.flattened ?? ""] where !rel.isEmpty {
                let abs = confinePath(dir: Fixture.projectDir, rel: rel)
                #expect(abs != nil, "path escaped confinement: \(rel)")
                if let abs {
                    #expect(FileManager.default.fileExists(atPath: abs), "missing fixture file: \(rel)")
                }
            }
        }
    }
}
