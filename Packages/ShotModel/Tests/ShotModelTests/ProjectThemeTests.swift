import Foundation
import Testing
@testable import ShotModel

/// The per-project `theme` key — the cross-platform contract (1b).
///
/// **Absent ⇒ follow the app preference. Present ⇒ pin that brand.** Those are
/// two states, not one, and nearly every test here exists to keep them apart.
/// Windows shipped a version that omitted the key whenever it matched the
/// default brand, which made "explicitly shotAI" unrepresentable: with the app
/// preference on LFI, a project pinned to shotAI silently reverted on the next
/// write. See Armadillon44/shotAI#77.
@Suite struct ProjectThemeSchema {
    private func manifest(_ theme: String?) -> ProjectManifest {
        var m = ProjectManifest(id: "p", title: "t", createdAt: "2026-01-01",
                                updatedAt: "2026-01-01", steps: [])
        m.theme = theme
        return m
    }

    @Test func absentMeansNoPin() {
        #expect(manifest(nil).pinnedBrand == nil)
    }

    @Test func knownValuesResolve() {
        #expect(manifest("shotAI").pinnedBrand == .shotAI)
        #expect(manifest("lfi").pinnedBrand == .lfi)
    }

    /// An unrecognised brand — one a NEWER build wrote — does not resolve, so
    /// rendering falls back to the app preference rather than failing.
    @Test func unknownValueDoesNotResolve() {
        #expect(manifest("solarpunk").pinnedBrand == nil)
    }

    /// …but it must SURVIVE, which is why the stored form is a raw String and
    /// not a `BrandPref`. Decoding into the enum would drop the key, and the
    /// next write from this build would delete the other build's pin.
    @Test func unknownValueRoundTrips() throws {
        let json = #"{"id":"p","title":"t","createdAt":"a","updatedAt":"b","steps":[],"theme":"solarpunk"}"#
        let m = try ProjectJSON.decoder().decode(ProjectManifest.self, from: Data(json.utf8))
        #expect(m.theme == "solarpunk")
        let out = String(decoding: try ProjectJSON.encoder().encode(m), as: UTF8.self)
        #expect(out.contains("\"theme\" : \"solarpunk\""))
    }

    /// No pin means no key: a project that never touches the setting stays
    /// byte-identical to one written before the feature existed.
    @Test func nilIsEncodedAsAbsent() throws {
        let json = String(decoding: try ProjectJSON.encoder().encode(manifest(nil)), as: UTF8.self)
        #expect(!json.contains("theme"))
    }

    /// `theme` is a KNOWN key, so it must not also land in `extra` — that would
    /// write it twice and let the two copies disagree.
    @Test func isNotAlsoCarriedAsAnUnknownKey() throws {
        let json = #"{"id":"p","title":"t","createdAt":"a","updatedAt":"b","steps":[],"theme":"lfi"}"#
        let m = try ProjectJSON.decoder().decode(ProjectManifest.self, from: Data(json.utf8))
        #expect(m.extra["theme"] == nil)
        let out = String(decoding: try ProjectJSON.encoder().encode(m), as: UTF8.self)
        #expect(out.components(separatedBy: "\"theme\"").count == 2, "written exactly once")
    }
}

@Suite struct ProjectThemeStore {
    private func store() throws -> ProjectStore {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("theme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return ProjectStore(settings: InMemorySettings(projectsDir: root))
    }

    /// The default brand is stamped as ABSENT, so the ordinary operator's
    /// projects carry no key at all.
    @Test func creationOmitsTheDefaultBrand() async throws {
        let store = try store()
        let path = try await store.createProject(title: "T", brand: .shotAI).path
        #expect(try await store.openProject(at: path).manifest.theme == nil)
    }

    /// A non-default app brand IS stamped, so the project keeps the look it was
    /// authored in when the preference later changes.
    @Test func creationStampsANonDefaultBrand() async throws {
        let store = try store()
        let path = try await store.createProject(title: "T", brand: .lfi).path
        #expect(try await store.openProject(at: path).manifest.pinnedBrand == .lfi)
    }

    /// **The correction.** An explicit choice always writes — the default brand
    /// included — because "pinned to shotAI" and "follows the preference" are
    /// different states and only the pin survives a preference change.
    @Test func pinningTheDefaultBrandStillWritesTheKey() async throws {
        let store = try store()
        let path = try await store.createProject(title: "T", brand: .lfi).path
        _ = try await store.setTheme(at: path, .shotAI)
        let m = try await store.openProject(at: path).manifest
        #expect(m.theme == "shotAI", "explicitly default is not the same as absent")
        #expect(m.pinnedBrand == .shotAI)
    }

    /// Only nil removes the key.
    @Test func clearingThePinDeletesTheKey() async throws {
        let store = try store()
        let path = try await store.createProject(title: "T", brand: .lfi).path
        _ = try await store.setTheme(at: path, nil)
        let m = try await store.openProject(at: path).manifest
        #expect(m.theme == nil)
        let json = String(decoding: try ProjectJSON.encoder().encode(m), as: UTF8.self)
        #expect(!json.contains("theme"))
    }

    /// The no-op guard compares RAW values. Coercing both sides through
    /// `BrandPref` would make `nil` and `"shotAI"` compare equal, so clearing
    /// the pin on a default-pinned project would be refused — folding the two
    /// states back together through the back door.
    @Test func noOpDoesNotWriteOrReDateTheProject() async throws {
        let store = try store()
        let path = try await store.createProject(title: "T").path
        _ = try await store.setTheme(at: path, .lfi)
        let before = try await store.openProject(at: path).manifest.updatedAt

        #expect(try await store.setTheme(at: path, .lfi) == nil, "no change, no write")

        let after = try await store.openProject(at: path).manifest.updatedAt
        #expect(after == before, "updatedAt must not move")

        // Absent vs explicitly-default are distinguishable in BOTH directions.
        #expect(try await store.setTheme(at: path, nil) != nil, "lfi -> absent is a change")
        #expect(try await store.setTheme(at: path, .shotAI) != nil, "absent -> shotAI is a change")
        #expect(try await store.setTheme(at: path, nil) != nil, "shotAI -> absent is a change")
    }

    /// Writing over an unrecognised brand replaces it — the user asked for this
    /// one. (Windows coerces-and-pins here too; the platforms must agree.)
    @Test func writingOverAnUnknownBrandReplacesIt() async throws {
        let store = try store()
        let path = try await store.createProject(title: "T").path
        _ = try await store.mutate(at: path) { $0.theme = "solarpunk" }
        #expect(try await store.setTheme(at: path, .lfi) != nil)
        #expect(try await store.openProject(at: path).manifest.theme == "lfi")
    }

    /// An imported package reproduces in the brand it was AUTHORED in, so the
    /// receiver's preference is never stamped over it.
    @Test func importKeepsTheSendersPin() async throws {
        let store = try store()
        var m = ProjectManifest(id: "sender", title: "T", createdAt: "2026-01-01",
                                updatedAt: "2026-01-01", steps: [])
        m.theme = "lfi"
        let path = try await store.createProjectFromImport(manifest: m, files: []).path
        #expect(try await store.openProject(at: path).manifest.pinnedBrand == .lfi)
    }

    /// An unpinned import stays unpinned — it follows the RECEIVER's preference,
    /// which is what "no pin" has always meant.
    @Test func unpinnedImportStaysUnpinned() async throws {
        let store = try store()
        let m = ProjectManifest(id: "sender", title: "T", createdAt: "2026-01-01",
                                updatedAt: "2026-01-01", steps: [])
        let path = try await store.createProjectFromImport(manifest: m, files: []).path
        #expect(try await store.openProject(at: path).manifest.theme == nil)
    }
}
