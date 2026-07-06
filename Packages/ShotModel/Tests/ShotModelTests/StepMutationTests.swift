import Foundation
import Testing
@testable import ShotModel

// The Phase B store surface: addStep / insertStep / deleteSteps, ported from
// project-store.ts (addStep renumbering, deleteSteps' confined file cleanup).
@Suite struct StepMutationTests {
    let root: String
    let projectDir: String
    let store: ProjectStore

    init() throws {
        root = NSTemporaryDirectory() + "shotai-steps-\(UUID().uuidString)"
        projectDir = root + "/proj"
        try FileManager.default.createDirectory(atPath: projectDir + "/shots", withIntermediateDirectories: true)
        let manifest = ProjectManifest(id: "p", title: "T", createdAt: "", updatedAt: "")
        try ProjectJSON.encodeManifest(manifest)
            .write(to: URL(fileURLWithPath: projectDir + "/project.json"))
        store = ProjectStore(settings: InMemorySettings(projectsDir: root))
    }

    private func step(_ id: String, screenshot: String = "") -> ProjectStep {
        ProjectStep(id: id, order: 0, screenshot: screenshot, trigger: .click)
    }

    private func readSteps() throws -> [ProjectStep] {
        let data = try Data(contentsOf: URL(fileURLWithPath: projectDir + "/project.json"))
        return try ProjectJSON.decodeManifest(data).steps
    }

    private func cleanup() {
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func addStepRenumbersToArrayPosition() async throws {
        // Filename counters climb past deletes; order must track array position.
        try await store.addStep(at: projectDir, step("a"))
        try await store.addStep(at: projectDir, step("b"))
        var s = step("c")
        s.order = 99 // capture counters drift; renumber must fix
        try await store.addStep(at: projectDir, s)
        #expect(try readSteps().map(\.order) == [1, 2, 3])
        cleanup()
    }

    @Test func insertStepClampsAndAppendsWhenNil() async throws {
        try await store.addStep(at: projectDir, step("a"))
        try await store.addStep(at: projectDir, step("b"))
        try await store.insertStep(at: projectDir, step("mid"), atIndex: 1)
        try await store.insertStep(at: projectDir, step("end"), atIndex: nil)
        try await store.insertStep(at: projectDir, step("clamped"), atIndex: 999)
        try await store.insertStep(at: projectDir, step("front"), atIndex: -5)
        let steps = try readSteps()
        #expect(steps.map(\.id) == ["front", "a", "mid", "b", "end", "clamped"])
        #expect(steps.map(\.order) == [1, 2, 3, 4, 5, 6])
        cleanup()
    }

    @Test func deleteStepsRemovesFilesButOnlyInsideTheProject() async throws {
        // A discard must delete the session's screenshots — but a hand-edited
        // traversal path in the manifest must NOT escape the project folder.
        let inside = projectDir + "/shots/step-0001.png"
        let outside = root + "/victim.png"
        FileManager.default.createFile(atPath: inside, contents: Data([0x89]))
        FileManager.default.createFile(atPath: outside, contents: Data([0x89]))

        try await store.addStep(at: projectDir, step("keep"))
        try await store.addStep(at: projectDir, step("s1", screenshot: "shots/step-0001.png"))
        try await store.addStep(at: projectDir, step("evil", screenshot: "../victim.png"))

        let manifest = try await store.deleteSteps(at: projectDir, ids: ["s1", "evil"])
        #expect(manifest.steps.map(\.id) == ["keep"])
        #expect(manifest.steps.map(\.order) == [1])
        #expect(!FileManager.default.fileExists(atPath: inside), "in-project shot should be deleted")
        #expect(FileManager.default.fileExists(atPath: outside), "confinement must block the traversal delete")
        cleanup()
    }

    @Test func setCaptureSettingsPersistsTheTarget() async throws {
        try await store.setCaptureSettings(
            at: projectDir,
            CaptureTarget(mode: .area, area: Rect(x: 10, y: 20, width: 300, height: 200))
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: projectDir + "/project.json"))
        let m = try ProjectJSON.decodeManifest(data)
        #expect(m.captureSettings?.mode == .area)
        #expect(m.captureSettings?.area == Rect(x: 10, y: 20, width: 300, height: 200))
        cleanup()
    }

    // A folder removed out from under us (Finder/cloud sync) must be tolerated
    // so recents is still pruned — parity with the Windows force:true delete.
    @Test func deleteProjectToleratesAnAlreadyMissingFolder() async throws {
        let settings = InMemorySettings(projectsDir: root)
        let store = ProjectStore(settings: settings)
        let summary = try await store.createProject(title: "Gone")
        #expect(settings.recents().contains(summary.path))
        // Remove the folder behind the store's back.
        try FileManager.default.removeItem(atPath: summary.path)
        // Must not throw, and must still prune recents.
        try await store.deleteProject(at: summary.path)
        #expect(!settings.recents().contains(summary.path))
        cleanup()
    }
}
