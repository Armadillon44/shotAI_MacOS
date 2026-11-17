import Foundation
import Testing
@testable import ShotModel

/// The per-project `sopRunOptions` key: what the author chose in the Generate
/// dialog last time. macOS-only and additive — Windows keeps it through its
/// unknown-key passthrough (v1.3.0, #95) and ignores it — so the rules below are
/// about never disturbing a project that does not use it, and never erasing what a
/// newer build stored in it.
@Suite struct SopRunOptionsSchema {
    private func manifest(_ o: SopRunOptions?) -> ProjectManifest {
        var m = ProjectManifest(id: "p", title: "t", createdAt: "2026-01-01", updatedAt: "2026-01-01", steps: [])
        m.sopRunOptions = o
        return m
    }

    private func encoded(_ m: ProjectManifest) throws -> String {
        String(decoding: try ProjectJSON.encoder().encode(m), as: UTF8.self)
    }

    private func decoded(_ json: String) throws -> ProjectManifest {
        try ProjectJSON.decoder().decode(ProjectManifest.self, from: Data(json.utf8))
    }

    private let base = #""id":"p","title":"t","createdAt":"a","updatedAt":"b","steps":[]"#

    /// A project that never generated stays byte-identical to one written before
    /// the feature: no key at all.
    @Test func unusedMeansNoKey() throws {
        #expect(!(try encoded(manifest(nil))).contains("sopRunOptions"))
        #expect(!(try encoded(manifest(SopRunOptions()))).contains("sopRunOptions"),
                "empty options are not worth a key")
    }

    @Test func choicesRoundTrip() throws {
        let m = manifest(SopRunOptions(wording: .general, instructions: "Say \"the portal\", not its URL."))
        let back = try decoded(try encoded(m))
        #expect(back.sopRunOptions == m.sopRunOptions)
        #expect(back.sopRunOptions?.wordingChoice == .general)
    }

    /// The explicit default is stored, not folded into "absent": a project held at
    /// Specific must stay Specific when the Settings default later moves to General.
    @Test func theDefaultIsStoredWhenChosen() throws {
        let out = try encoded(manifest(SopRunOptions(wording: .specific)))
        #expect(out.contains(#""wording" : "specific""#))
    }

    /// A wording a NEWER build wrote does not resolve here, so the dialog falls back
    /// to Settings — but it must survive this build's next write.
    @Test func anUnknownWordingSurvives() throws {
        let m = try decoded("{\(base),\"sopRunOptions\":{\"wording\":\"brief\",\"instructions\":\"x\"}}")
        #expect(m.sopRunOptions?.wordingChoice == nil)
        #expect(try encoded(m).contains(#""wording" : "brief""#))
    }

    @Test func anUnknownFieldSurvives() throws {
        let m = try decoded("{\(base),\"sopRunOptions\":{\"wording\":\"general\",\"audience\":\"new hires\"}}")
        #expect(m.sopRunOptions?.extra["audience"] == .string("new hires"))
        #expect(try encoded(m).contains(#""audience" : "new hires""#))
    }

    /// A known key, so never also carried as an unknown root key (written twice,
    /// the two copies could disagree).
    @Test func isNotAlsoAnUnknownRootKey() throws {
        let m = try decoded("{\(base),\"sopRunOptions\":{\"wording\":\"general\"}}")
        #expect(m.extra["sopRunOptions"] == nil)
        let out = try encoded(m)
        #expect(out.components(separatedBy: "sopRunOptions").count == 2, "exactly one occurrence")
    }

    /// A malformed value costs only itself; the project still opens.
    @Test func aMalformedValueIsDroppedAlone() throws {
        let m = try decoded("{\(base),\"sopRunOptions\":\"general\"}")
        #expect(m.sopRunOptions == nil)
        #expect(m.title == "t")
        let n = try decoded("{\(base),\"sopRunOptions\":{\"wording\":7,\"instructions\":[1]}}")
        #expect(n.sopRunOptions?.wording == nil)
        #expect(n.sopRunOptions?.instructions == "")
    }

    @Test func instructionsAreCapped() throws {
        let long = String(repeating: "x", count: SOP_RUN_INSTRUCTIONS_MAX + 900)
        #expect(SopRunOptions(instructions: long).instructions.count == SOP_RUN_INSTRUCTIONS_MAX)
        let m = try decoded("{\(base),\"sopRunOptions\":{\"instructions\":\"\(long)\"}}")
        #expect(m.sopRunOptions?.instructions.count == SOP_RUN_INSTRUCTIONS_MAX)
    }
}

/// Saving through the store: an unchanged choice must not re-date the project
/// (which would jump it to the top of Home), and empty options remove the key.
@Suite struct SopRunOptionsStore {
    private func project() async throws -> (ProjectStore, String) {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("runopts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let store = ProjectStore(settings: InMemorySettings(projectsDir: root))
        let summary = try await store.createProject(title: "Run options")
        return (store, summary.path)
    }

    @Test func savesReadsBackAndSkipsAnUnchangedWrite() async throws {
        let (store, path) = try await project()
        let opts = SopRunOptions(wording: .general, instructions: "Keep it short.")
        let first = try await store.setSopRunOptions(at: path, opts)
        #expect(first?.sopRunOptions == opts)
        let reopened = try await store.openProject(at: path).manifest
        #expect(reopened.sopRunOptions == opts)

        let again = try await store.setSopRunOptions(at: path, opts)
        #expect(again == nil, "the same choice writes nothing")
        #expect(try await store.openProject(at: path).manifest.updatedAt == reopened.updatedAt)
    }

    @Test func emptyOptionsRemoveTheKey() async throws {
        let (store, path) = try await project()
        try await store.setSopRunOptions(at: path, SopRunOptions(wording: .general))
        try await store.setSopRunOptions(at: path, SopRunOptions())
        let raw = try String(contentsOfFile: (path as NSString).appendingPathComponent("project.json"), encoding: .utf8)
        #expect(!raw.contains("sopRunOptions"))
    }
}
