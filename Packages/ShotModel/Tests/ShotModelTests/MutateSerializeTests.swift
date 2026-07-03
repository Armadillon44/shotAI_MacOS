import Foundation
import Testing
@testable import ShotModel

// Ported from shotAI-original/src/main/mutate-serialize.test.ts (P6): the store
// must serialize read-modify-write so concurrent mutations can't lose updates,
// and the atomic write underneath can't tear the file or leave stray tmps.
@Suite struct MutateSerializeTests {
    let root: String
    let projectDir: String
    let store: ProjectStore
    static let initialTitle = "INIT" // non-empty so read keeps it (empty → basename)

    init() throws {
        root = NSTemporaryDirectory() + "shotai-mutate-\(UUID().uuidString)"
        projectDir = root + "/proj1"
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        let manifest = ProjectManifest(
            id: "test",
            title: Self.initialTitle,
            createdAt: "",
            updatedAt: ""
        )
        try ProjectJSON.encodeManifest(manifest)
            .write(to: URL(fileURLWithPath: projectDir + "/project.json"))
        store = ProjectStore(settings: InMemorySettings(projectsDir: root))
    }

    private func readTitle() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: projectDir + "/project.json"))
        // Throws if the atomic write ever left a torn file.
        return try ProjectJSON.decodeManifest(data).title
    }

    @Test func doesNotLoseUpdatesUnderManyConcurrentCalls() async throws {
        let n = 40
        // Fire all mutations without awaiting between them — they serialize on
        // the actor exactly as the original's writeQueue did.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<n {
                group.addTask { [store, projectDir] in
                    try await store.mutate(at: projectDir) { m in m.title += "x" }
                }
            }
            try await group.waitForAll()
        }
        #expect(try readTitle() == Self.initialTitle + String(repeating: "x", count: n))
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func leavesNoStrayTmpFilesAndValidManifestAfterConcurrency() async throws {
        let n = 25
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<n {
                group.addTask { [store, projectDir] in
                    try await store.mutate(at: projectDir) { m in m.title += "y" }
                }
            }
            try await group.waitForAll()
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: projectDir)
        #expect(entries.filter { $0.hasSuffix(".tmp") }.isEmpty)
        #expect(try readTitle() == Self.initialTitle + String(repeating: "y", count: n))
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func throwingMutationAbortsItsWriteWithoutCorruptingOrLosingOthers() async throws {
        struct Abort: Error {}
        try await store.mutate(at: projectDir) { m in m.title += "a" }
        await #expect(throws: Abort.self) {
            try await store.mutate(at: projectDir) { _ in throw Abort() }
        }
        try await store.mutate(at: projectDir) { m in m.title += "b" }
        // The two successful mutations both landed; the thrower wrote nothing.
        #expect(try readTitle() == Self.initialTitle + "ab")
        try? FileManager.default.removeItem(atPath: root)
    }

    @Test func mutateOutsideRootAndRecentsIsRejected() async throws {
        let alien = NSTemporaryDirectory() + "shotai-alien-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: alien, withIntermediateDirectories: true)
        await #expect(throws: ProjectStore.StoreError.self) {
            try await store.mutate(at: alien) { m in m.title = "pwn" }
        }
        try? FileManager.default.removeItem(atPath: alien)
        try? FileManager.default.removeItem(atPath: root)
    }
}
