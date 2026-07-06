import Foundation
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

// `confinePathNoSymlinks` closes the documented lexical gap: a symlinked path
// component (a hostile/shared project's `shots` → ~/Documents) resolves
// "inside" lexically but redirects the real write/delete out of the folder.
// These need a real filesystem, so each runs against a fresh temp project.
@Suite struct PathConfineSymlinkTests {
    let fm = FileManager.default
    let root: String
    let proj: String
    let outside: String

    init() throws {
        root = NSTemporaryDirectory() + "shotai-symlink-\(UUID().uuidString)"
        proj = root + "/proj"
        outside = root + "/outside"
        try fm.createDirectory(atPath: proj, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
    }

    private func cleanup() { try? fm.removeItem(atPath: root) }

    @Test func acceptsRealInProjectPath() throws {
        // A real `shots` directory with a real file passes and returns the same
        // resolved path as the lexical confiner.
        try fm.createDirectory(atPath: proj + "/shots", withIntermediateDirectories: true)
        fm.createFile(atPath: proj + "/shots/x.png", contents: Data([0x89]))
        #expect(confinePathNoSymlinks(dir: proj, rel: "shots/x.png") == proj + "/shots/x.png")
        cleanup()
    }

    @Test func acceptsNotYetCreatedComponents() throws {
        // The `shots/` dir about to be created and the PNG about to be written
        // don't exist yet — a non-existent component can't be a redirect, so it
        // must pass (mkdir/write then create real files).
        #expect(confinePathNoSymlinks(dir: proj, rel: "shots") == proj + "/shots")
        #expect(confinePathNoSymlinks(dir: proj, rel: "shots/step-0001.png") == proj + "/shots/step-0001.png")
        cleanup()
    }

    @Test func rejectsSymlinkedShotsComponent() throws {
        // `shots` is a symlink OUT of the project. Lexically it still looks
        // inside (documenting exactly what the hardening adds over confinePath).
        try fm.createSymbolicLink(atPath: proj + "/shots", withDestinationPath: outside)
        #expect(confinePath(dir: proj, rel: "shots/x.png") == proj + "/shots/x.png") // lexical: accepts
        #expect(confinePathNoSymlinks(dir: proj, rel: "shots/x.png") == nil)         // hardened: rejects
        cleanup()
    }

    @Test func rejectsSymlinkedLeaf() throws {
        // The final component itself being a symlink is refused too.
        fm.createFile(atPath: outside + "/secret.png", contents: Data([0x89]))
        try fm.createSymbolicLink(atPath: proj + "/secret.png", withDestinationPath: outside + "/secret.png")
        #expect(confinePathNoSymlinks(dir: proj, rel: "secret.png") == nil)
        cleanup()
    }

    @Test func rejectsSymlinkedIntermediateComponent() throws {
        // A symlink deeper than the first level (export/.render lives under a
        // symlinked `export`) is caught by the component-by-component walk.
        try fm.createSymbolicLink(atPath: proj + "/export", withDestinationPath: outside)
        #expect(confinePathNoSymlinks(dir: proj, rel: "export/.render/x.png") == nil)
        cleanup()
    }

    @Test func stillRejectsLexicalEscapes() throws {
        // Delegates to confinePath first, so `..`/absolute escapes stay blocked.
        #expect(confinePathNoSymlinks(dir: proj, rel: "../evil.png") == nil)
        #expect(confinePathNoSymlinks(dir: proj, rel: "/etc/passwd") == nil)
        cleanup()
    }
}
