import Testing
@testable import ShotModel

// Ported from shotAI-original/src/main/path-confine.test.ts — these encode the
// path-traversal security boundary and must stay in lockstep with the original.
@Suite struct PathConfineTests {
    let dir = "/projects/abc"

    @Test func acceptsInFolderRelativePath() {
        #expect(confinePath(dir: dir, rel: "shots/step-0001.png") == "/projects/abc/shots/step-0001.png")
    }

    @Test func acceptsNestedInFolderPath() {
        #expect(confinePath(dir: dir, rel: "export/.render/x.png") == "/projects/abc/export/.render/x.png")
    }

    @Test(arguments: [
        "../evil.png", // parent escape
        "../../../../etc/passwd", // deep parent escape
        "shots/../../evil.png", // dot-dot mid-path
        ".", // the folder root itself
    ])
    func rejectsEscapes(_ rel: String) {
        #expect(confinePath(dir: dir, rel: rel) == nil)
    }

    @Test func rejectsAbsolutePath() {
        #expect(confinePath(dir: dir, rel: "/etc/passwd") == nil)
    }

    @Test func rejectsTraversalIdUsedAsRenderFilename() {
        // updateStep/mergeSteps build `export/.render/<id>.png`; a hand-edited
        // manifest id with traversal segments must not escape the project folder.
        let stepId = "../../../evil"
        #expect(confinePath(dir: dir, rel: "export/.render/\(stepId).png") == nil)
    }

    @Test func rejectsSiblingPrefixFolder() {
        // "/projects/abcd" starts with "/projects/abc" as a *string* but is not
        // inside it — the boundary must compare path components, not prefixes.
        #expect(confinePath(dir: dir, rel: "../abcd/x.png") == nil)
    }
}
