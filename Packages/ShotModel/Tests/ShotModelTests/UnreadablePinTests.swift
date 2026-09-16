import Foundation
import Testing
@testable import ShotModel

/// #118 — the menu must not present a state the project is not in.
///
/// A project can be pinned to a brand this build cannot read. `pinnedBrand` is
/// nil for that, correctly. Binding the menu straight to it ticked "App Default",
/// so the user clicked an already-ticked row, the UI presented that as a no-op,
/// and it deleted their pin and re-dated the project.
///
/// The selection logic lives in the app target, which has no test host, so this
/// pins the SCHEMA-level facts it rests on plus the store behaviour it triggers.
@Suite struct UnreadablePinGesture {
    private func store() throws -> ProjectStore {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("i118-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return ProjectStore(settings: InMemorySettings(projectsDir: root))
    }

    /// The three facts the menu's fourth state is derived from: the raw value
    /// survives, it does not resolve, and those are distinguishable.
    @Test func anUnreadablePinIsDistinguishableFromNoPin() async throws {
        let store = try store()
        let path = try await store.createProject(title: "T").path
        _ = try await store.mutate(at: path) { $0.theme = "solarpunk" }
        let m = try await store.openProject(at: path).manifest
        #expect(m.theme == "solarpunk", "raw value must survive, or there is nothing to show")
        #expect(m.pinnedBrand == nil, "and must not resolve")

        let none = try await store.openProject(
            at: try await store.createProject(title: "U").path).manifest
        #expect(none.theme == nil)
        // The distinction the menu has to render: both have pinnedBrand == nil,
        // and they are NOT the same state.
        #expect(m.theme != none.theme)
    }

    /// Clearing an unreadable pin must stay POSSIBLE. Making the click a no-op
    /// would be the obvious fix and is wrong — it would make such a pin permanent.
    @Test func clearingAnUnreadablePinStillWorks() async throws {
        let store = try store()
        let path = try await store.createProject(title: "T").path
        _ = try await store.mutate(at: path) { $0.theme = "solarpunk" }
        #expect(try await store.setTheme(at: path, nil) != nil, "the write must go through")
        #expect(try await store.openProject(at: path).manifest.theme == nil)
    }

    /// And the no-op guard still fires where it should, so the fix has not made
    /// every menu click a write.
    @Test func aGenuineNoOpIsStillRefused() async throws {
        let store = try store()
        let path = try await store.createProject(title: "T").path
        #expect(try await store.setTheme(at: path, nil) == nil, "absent -> App Default is a no-op")
        _ = try await store.setTheme(at: path, .lfi)
        #expect(try await store.setTheme(at: path, .lfi) == nil, "lfi -> lfi is a no-op")
    }
}
