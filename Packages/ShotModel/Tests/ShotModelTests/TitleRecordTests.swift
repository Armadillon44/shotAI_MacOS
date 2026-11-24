import Foundation
import Testing
@testable import ShotModel

/// `sopTitleRewrite`: the title the last generation wrote. Additive and macOS-only,
/// so it must be absent until used and survive a read/write cycle.
@Suite struct TitleRecordSchema {
    private let base = #""id":"p","title":"t","createdAt":"a","updatedAt":"b","steps":[]"#

    private func decoded(_ json: String) throws -> ProjectManifest {
        try JSONDecoder().decode(ProjectManifest.self, from: Data(json.utf8))
    }

    @Test func absentUntilUsedAndRoundTrips() throws {
        let plain = try decoded("{\(base)}")
        #expect(plain.sopTitleRewrite == nil)
        #expect(!String(decoding: try ProjectJSON.encodeManifest(plain), as: UTF8.self).contains("sopTitleRewrite"))
        var m = plain
        m.sopTitleRewrite = "Resetting MFA"
        let again = try JSONDecoder().decode(ProjectManifest.self, from: ProjectJSON.encodeManifest(m))
        #expect(again.sopTitleRewrite == "Resetting MFA")
        #expect(again.extra["sopTitleRewrite"] == nil, "a known key, not an unknown one")
    }

    @Test func aMalformedValueIsDroppedAlone() throws {
        let m = try decoded("{\(base),\"sopTitleRewrite\":7}")
        #expect(m.sopTitleRewrite == nil)
        #expect(m.title == "t")
    }
}
