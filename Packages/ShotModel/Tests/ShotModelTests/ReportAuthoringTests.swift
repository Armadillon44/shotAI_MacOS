import Foundation
import Testing
@testable import ShotModel

// R1: report authoring — inline text edits, intro set/remove, add text step.
@Suite struct ReportAuthoringTests {
    let root: String
    let projectDir: String
    let store: ProjectStore

    init() throws {
        root = NSTemporaryDirectory() + "shotai-authoring-\(UUID().uuidString)"
        projectDir = root + "/proj"
        try FileManager.default.createDirectory(atPath: projectDir + "/shots", withIntermediateDirectories: true)
        var m = ProjectManifest(id: "p", title: "T", createdAt: "", updatedAt: "")
        // A shot step that already has a baked render — editing its text must NOT
        // disturb that render.
        m.steps = [ProjectStep(
            id: "s1", order: 1, screenshot: "shots/step-0001.png", trigger: .click,
            caption: "orig caption", note: "orig note",
            flattened: "export/.render/s1.png", renderRev: 3
        )]
        try ProjectJSON.encodeManifest(m).write(to: URL(fileURLWithPath: projectDir + "/project.json"))
        store = ProjectStore(settings: InMemorySettings(projectsDir: root))
    }
    private func cleanup() { try? FileManager.default.removeItem(atPath: root) }
    private func read() throws -> ProjectManifest {
        try ProjectJSON.decodeManifest(Data(contentsOf: URL(fileURLWithPath: projectDir + "/project.json")))
    }

    @Test func textEditsDoNotDisturbTheRender() async throws {
        _ = try await store.editStepText(at: projectDir, stepId: "s1", caption: "new caption", body: "an instruction")
        let s = try read().steps[0]
        #expect(s.caption == "new caption")
        #expect(s.body == "an instruction")
        #expect(s.note == "orig note") // untouched fields preserved
        // The critical invariant: text is rendered live, so the baked render and
        // its revision stay exactly as they were (no re-flatten, no freshness bump).
        #expect(s.flattened == "export/.render/s1.png")
        #expect(s.renderRev == 3)
        cleanup()
    }

    @Test func introSetAndRemove() async throws {
        // An all-empty intro coerces to nil on read (Windows-parity manifest
        // decoder), so the "add overview" placeholder is UI-local, not persisted.
        _ = try await store.setIntro(at: projectDir, heading: "", body: "")
        #expect(try read().intro == nil, "an all-empty intro coerces to nil on read")
        _ = try await store.setIntro(at: projectDir, heading: "Goal", body: "Do the thing")
        #expect(try read().intro?.heading == "Goal")
        _ = try await store.removeIntro(at: projectDir)
        #expect(try read().intro == nil)
        cleanup()
    }

    @Test func addTextStepAppendsCalloutAndRenumbers() async throws {
        _ = try await store.addTextStep(at: projectDir, atIndex: nil, heading: "Heads up", body: "Careful here", callout: .caution)
        let steps = try read().steps
        #expect(steps.count == 2)
        #expect(steps[1].kind == .text)
        #expect(steps[1].callout == .caution)
        #expect(steps[1].screenshot.isEmpty)
        #expect(steps.map(\.order) == [1, 2]) // renumbered
        cleanup()
    }

    @Test func addTextStepInsertsAtIndex() async throws {
        _ = try await store.addTextStep(at: projectDir, atIndex: 0, heading: "Intro block", body: "", callout: nil)
        let steps = try read().steps
        #expect(steps.count == 2)
        #expect(steps[0].kind == .text)          // inserted before the shot
        #expect(steps[1].id == "s1")
        #expect(steps.map(\.order) == [1, 2])
        cleanup()
    }

    @Test func editingCalloutTypeSwitchesStyle() async throws {
        _ = try await store.addTextStep(at: projectDir, atIndex: nil, heading: "H", body: "B", callout: .note)
        let id = try read().steps[1].id
        _ = try await store.editStepText(at: projectDir, stepId: id, callout: .warning)
        #expect(try read().steps[1].callout == .warning)
        cleanup()
    }

    @Test func reorderStepsPermutesAndRenumbers() async throws {
        _ = try await store.addTextStep(at: projectDir, atIndex: nil, heading: "A", body: "")
        _ = try await store.addTextStep(at: projectDir, atIndex: nil, heading: "B", body: "")
        let ids = try read().steps.map(\.id) // [s1, A, B]
        _ = try await store.reorderSteps(at: projectDir, orderedIds: ids.reversed())
        let after = try read().steps
        #expect(after.map(\.id) == Array(ids.reversed()))
        #expect(after.map(\.order) == [1, 2, 3]) // renumbered to new order
        cleanup()
    }

    @Test func reorderKeepsUnmentionedStepsAppended() async throws {
        _ = try await store.addTextStep(at: projectDir, atIndex: nil, heading: "A", body: "")
        let ids = try read().steps.map(\.id) // [s1, A]
        // Mention only A → A moves first, the unmentioned s1 is kept (appended).
        _ = try await store.reorderSteps(at: projectDir, orderedIds: [ids[1]])
        #expect(try read().steps.map(\.id) == [ids[1], ids[0]])
        cleanup()
    }

    @Test func importImageStepWritesFileAndInsertsShotStep() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) // PNG signature
        _ = try await store.importImageStep(at: projectDir, atIndex: 0, imageData: png)
        let steps = try read().steps
        #expect(steps.count == 2)
        #expect(steps[0].kind != .text)                       // a screenshot-kind step
        #expect(steps[0].screenshot.hasPrefix("shots/import-"))
        #expect(steps[0].screenshot.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: projectDir + "/" + steps[0].screenshot))
        #expect(steps[1].id == "s1")                          // inserted before the original
        #expect(steps.map(\.order) == [1, 2])
        cleanup()
    }

    @Test func importImageStepRejectsNonImage() async throws {
        await #expect(throws: ProjectStore.StoreError.notAnImage) {
            _ = try await store.importImageStep(at: projectDir, atIndex: nil, imageData: Data([0, 1, 2, 3]))
        }
        #expect(try read().steps.count == 1) // unchanged
        cleanup()
    }
}
