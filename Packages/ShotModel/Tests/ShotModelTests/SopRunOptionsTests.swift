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

    /// Capped where typed or used, never on read: a later build with a higher cap
    /// may have written more, and reading must not shorten it.
    @Test func instructionsAreCappedWhenSetButReadAsStored() throws {
        let long = String(repeating: "x", count: SOP_RUN_INSTRUCTIONS_MAX + 900)
        #expect(SopRunOptions(instructions: long).instructions.count == SOP_RUN_INSTRUCTIONS_MAX)
        let m = try decoded("{\(base),\"sopRunOptions\":{\"instructions\":\"\(long)\"}}")
        #expect(m.sopRunOptions?.instructions == long)
        let reencoded = String(decoding: try ProjectJSON.encodeManifest(m), as: UTF8.self)
        #expect(reencoded.contains(long), "and written back as it was")
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

    private func raw(_ path: String) throws -> String {
        try String(contentsOfFile: (path as NSString).appendingPathComponent("project.json"), encoding: .utf8)
    }

    @Test func emptyOptionsRemoveTheKey() async throws {
        let (store, path) = try await project()
        #expect(try await store.setSopRunOptions(at: path, SopRunOptions(wording: .general)) != nil)
        #expect(try raw(path).contains("sopRunOptions"), "a wording alone is worth a key")
        #expect(try await store.setSopRunOptions(at: path, SopRunOptions()) != nil)
        #expect(!(try raw(path).contains("sopRunOptions")))
    }

    /// The common case: General chosen, nothing typed. And a change of wording
    /// alone, with the same (empty) instructions, is a change.
    @Test func aWordingAloneIsSavedAndAChangeOfWordingIsWritten() async throws {
        let (store, path) = try await project()
        #expect(try await store.setSopRunOptions(at: path, SopRunOptions(wording: .general)) != nil)
        #expect(try await store.openProject(at: path).manifest.sopRunOptions?.wordingChoice == .general)
        #expect(try await store.setSopRunOptions(at: path, SopRunOptions(wording: .specific)) != nil)
        #expect(try await store.openProject(at: path).manifest.sopRunOptions?.wordingChoice == .specific)
    }

    /// An unrelated write (a rename) keeps over-cap instructions byte for byte.
    @Test func anUnrelatedWriteKeepsTheInstructionsAsStored() async throws {
        let (store, path) = try await project()
        let long = String(repeating: "y", count: SOP_RUN_INSTRUCTIONS_MAX + 500)
        let file = (path as NSString).appendingPathComponent("project.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any])
        json["sopRunOptions"] = ["wording": "general", "instructions": long]
        try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: file))
        _ = try await store.renameProject(at: path, title: "Renamed")
        #expect(try await store.openProject(at: path).manifest.sopRunOptions?.instructions == long)
    }
}

/// The cap on a text field cuts what was typed or pasted, never what was there.
@Suite struct TextEditCap {
    private let full = String(repeating: "a", count: 10) + " Never name the customer."  // 35

    @Test func anEditInBoundsIsUnchanged() {
        #expect(capTextEdit(old: "abc", new: "abXc", limit: 10) == "abXc")
        #expect(capTextEdit(old: full, new: String(full.dropLast(5)), limit: 35) == String(full.dropLast(5)))
    }

    /// The finding: a paste at the start of a full field kept the paste and cut the
    /// end of the author's text, so a constraint ended "Never nam".
    @Test func aPasteIntoAFullFieldKeepsWhatWasThere() {
        #expect(capTextEdit(old: full, new: "Use 'portal'. " + full, limit: 35) == full)
        #expect(capTextEdit(old: full, new: "X" + full, limit: 35) == full, "typing in the middle of a full field")
    }

    @Test func aPasteIsKeptAsFarAsItFits() {
        #expect(capTextEdit(old: "start end", new: "start 0123456789 end", limit: 14) == "start 01234end", "the first five pasted characters fit")
        #expect(capTextEdit(old: "", new: "0123456789", limit: 4) == "0123")
    }

    @Test func aFieldAlreadyOverTheLimitIsCutToIt() {
        #expect(capTextEdit(old: "0123456789", new: "01234567890", limit: 5) == "01234")
    }

    @Test func repeatedCharactersAtTheSeamStayWithinTheLimit() {
        let r = capTextEdit(old: "aaaa", new: "aaaaaaa", limit: 5)
        #expect(r == "aaaaa")
    }
}
