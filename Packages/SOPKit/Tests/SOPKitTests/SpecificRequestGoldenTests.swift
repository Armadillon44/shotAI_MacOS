import CryptoKit
import Foundation
import ShotModel
import XCTest
@testable import SOPKit

/// The whole Specific request, pinned. `WordingTests` pins the system prompt and
/// the title line; this pins everything else a Specific request carries (every
/// author-block kind and its guidance, both overview branches, each metadata line,
/// the block-count and closing sentences) plus the repair turn, so a General-only
/// change that leaks into Specific fails here. Taken from the code at 61a53a5,
/// before any General fix touched the assembler.
final class SpecificRequestGoldenTests: XCTestCase {

    static let golden = "d315920fee345c83db7d2f4e6f5ff49abcc80659d1a2fb05930971a404a163c8"

    /// Three screenshots and one block of each author kind, with every metadata
    /// field a screenshot step can carry.
    private func fixture() async throws -> (manifest: ProjectManifest, dir: String) {
        let (store, path, dir) = try await makeProject(shots: 3)
        _ = try await store.addTextStep(at: path, atIndex: 0, heading: "Before you start", body: "Have the badge ready.", callout: nil)
        _ = try await store.addTextStep(at: path, atIndex: 2, heading: "", body: "The menu may take a moment.", callout: .note)
        _ = try await store.addTextStep(at: path, atIndex: 3, heading: "Careful", body: "Changes apply at once.", callout: .caution)
        _ = try await store.addTextStep(at: path, atIndex: 5, heading: "Stop", body: "Never share the code.", callout: .warning)
        _ = try await store.addTextStep(at: path, atIndex: 6, heading: "Finishing up", body: "", callout: .section)
        let m = try await store.openProject(at: path).manifest
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        var steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
        var shot = 0
        for i in steps.indices where (steps[i]["kind"] as? String) != "text" {
            shot += 1
            steps[i]["caption"] = "Click Save \(shot)"
            steps[i]["note"] = shot == 2 ? "Wait for the green tick." : ""
            steps[i]["window"] = ["app": "Badge Admin", "title": "People \(shot) - Badge Admin", "pid": 42]
            steps[i]["element"] = shot == 3 ? ["available": false]
                : ["available": true, "name": "Save \(shot)", "controlType": "AXButton"]
            steps[i]["click"] = ["global": ["x": 100 * shot, "y": 40], "image": ["x": 90 * shot, "y": 30], "button": "left"]
        }
        json["steps"] = steps
        let manifest = try JSONDecoder().decode(ProjectManifest.self, from: JSONSerialization.data(withJSONObject: json))
        return (manifest, dir)
    }

    private func variants(_ base: ProjectManifest) -> [ProjectManifest] {
        var auto = base
        auto.title = "Project 2026/11/17 09:00:00"
        auto.intro = nil
        var person = base
        person.title = "Badge printer setup"
        person.intro = SopIntro(heading: "Overview", body: "Front desk adds visitor badges.")
        person.introEditedByUser = nil
        var edited = person
        edited.introEditedByUser = true
        var regenerated = person
        regenerated.title = "Printing a visitor badge"
        regenerated.intro = SopIntro(heading: "Overview", body: "Claude's earlier overview.")
        regenerated.sopBackup = SopBackup(steps: base.steps, title: "Badge printer setup",
                                          intro: SopIntro(heading: "About", body: "The author's first overview."),
                                          model: "claude-sonnet-5-5", tone: .professional, at: "2026-11-17T09:00:00Z")
        return [auto, person, edited, regenerated]
    }

    /// Every text the request carries, in order; images are skipped so the PNG
    /// bytes of the fixture do not matter.
    private func texts(_ r: AssembledRequest) -> [String] {
        let system = r.system.compactMap { $0["text"] as? String }
        let user = r.messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
        return system + user
    }

    private func fingerprint() async throws -> String {
        let (base, dir) = try await fixture()
        var all: [String] = []
        for m in variants(base) {
            for run in [nil, SopRun(wording: .specific)] {
                all += texts(try assembleRequest(dir: dir, manifest: m, settings: SopSettings(), run: run))
            }
        }
        let plan = SopEditPlan(title: "T", intro: nil, steps: [])
        let repaired = SopService.repairBody(["messages": []], previous: plan, steps: [2, 4])
        all += ((repaired["messages"] as? [[String: Any]]) ?? []).flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["text"] as? String }
        return SHA256.hash(data: Data(all.joined(separator: "\u{0}").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func testTheWholeSpecificRequestIsByteIdenticalToBefore() async throws {
        let f = try await fingerprint()
        XCTAssertEqual(f, Self.golden, "Specific request changed; fingerprint now \(f)")
    }
}
