import Foundation
import Testing
@testable import ShotModel

/// `ProjectManifest.searchableText` is the index Home search matches against.
/// It must cover the project's human-readable content (so search finds text
/// *inside* projects — parity with Windows) and exclude machine metadata.
@Suite struct SearchableTextTests {

    private func step(caption: String = "", note: String = "",
                      heading: String? = nil, body: String? = nil) -> ProjectStep {
        ProjectStep(id: UUID().uuidString, order: 0, screenshot: "shots/s.png",
                    trigger: .click, caption: caption, note: note,
                    heading: heading, body: body)
    }

    @Test func includesTitleIntroAndAllStepText() {
        let m = ProjectManifest(
            id: "p1", title: "Onboarding Guide",
            createdAt: "", updatedAt: "",
            steps: [
                step(caption: "Click the Firewall tab", note: "admin only"),
                step(heading: "Section: Networking", body: "Set the VLAN to 42"),
            ],
            intro: SopIntro(heading: "Overview", body: "Quarterly access review")
        )
        let t = m.searchableText
        for needle in ["Onboarding Guide", "Overview", "Quarterly access review",
                       "Firewall", "admin only", "Section: Networking", "VLAN to 42"] {
            #expect(t.localizedStandardContains(needle), "expected searchableText to contain \(needle)")
        }
    }

    @Test func matchingIsCaseAndDiacriticInsensitive() {
        let m = ProjectManifest(id: "p2", title: "Café Ünïcode",
                                createdAt: "", updatedAt: "")
        #expect(m.searchableText.localizedStandardContains("cafe unicode"))
    }

    @Test func skipsEmptyPiecesAndOmitsMetadata() {
        let m = ProjectManifest(
            id: "secret-uuid-123", title: "Doc",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-02T00:00:00Z",
            steps: [step(caption: "only caption")]
        )
        let t = m.searchableText
        #expect(t.contains("Doc"))
        #expect(t.contains("only caption"))
        // Machine metadata must not leak into the search index.
        #expect(!t.contains("secret-uuid-123"))
        #expect(!t.contains("2026-01-01"))
        // No leading/trailing/blank separators from empty note/heading/body.
        #expect(!t.contains("\n\n"))
    }

    @Test func noIntroWhenNil() {
        let m = ProjectManifest(id: "p3", title: "Just a title",
                                createdAt: "", updatedAt: "")
        #expect(m.searchableText == "Just a title")
    }
}
