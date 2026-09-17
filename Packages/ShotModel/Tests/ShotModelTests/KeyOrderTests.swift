import Foundation
import Testing
@testable import ShotModel

/// #110. A `JSONEncoder` keyed container emits in its backing dictionary's hash
/// order, and Swift seeds that per process — so the same unmodified manifest
/// encoded in two app launches produced two different key orders, at every
/// nesting level, and the first save after each launch rewrote the whole file.
///
/// The property is asserted GENERICALLY rather than against a fixed key list.
/// A literal expected sequence would have to be edited every time the schema
/// gains a field, and the thing under test is not which keys exist — it is that
/// whatever keys exist come out in an order that does not depend on the process.
struct KeyOrderTests {

    /// Every object in `json`, as its keys in emitted order. Walks the text
    /// because that is the only place emission order survives; re-parsing into a
    /// dictionary would discard exactly the thing being measured.
    private func objectsKeys(_ json: String) -> [[String]] {
        var out: [[String]] = []
        var stack: [[String]] = []
        var chars = Array(json), i = 0
        var inString = false, escaped = false, current = ""
        var pendingKey: String?
        while i < chars.count {
            let c = chars[i]; i += 1
            if inString {
                if escaped { escaped = false; current.append(c); continue }
                if c == "\\" { escaped = true; current.append(c); continue }
                if c == "\"" { inString = false; pendingKey = current; continue }
                current.append(c); continue
            }
            switch c {
            case "\"": inString = true; current = ""
            case ":": if let k = pendingKey, !stack.isEmpty { stack[stack.count - 1].append(k) }; pendingKey = nil
            case "{": stack.append([])
            case "}": if let top = stack.popLast() { out.append(top) }; pendingKey = nil
            case ",": pendingKey = nil
            default: break
            }
        }
        return out
    }

    private func fullManifest() -> ProjectManifest {
        var m = ProjectManifest(id: "p", title: "T", createdAt: "2026-01-01T00:00:00.000Z",
                                updatedAt: "2026-01-01T00:00:00.000Z")
        m.theme = "lfi"
        m.displayScale = 0.8
        m.introEditedByUser = true
        m.intro = SopIntro(heading: "H", body: "B")
        m.extra = ["zzFutureKey": .string("v"), "aaFutureKey": .string("w")]
        m.steps = [ProjectStep(id: "s1", order: 1, kind: .shot,
                               screenshot: "shots/1.png", trigger: .hotkey)]
        return m
    }

    @Test func everyObjectEmitsItsKeysInSortedOrder() throws {
        let json = String(decoding: try ProjectJSON.encodeManifest(fullManifest()), as: UTF8.self)
        let objects = objectsKeys(json)
        #expect(objects.count >= 3, "expected the manifest, its step and its intro at minimum")
        for keys in objects where keys.count > 1 {
            #expect(keys == keys.sorted(),
                    "an object emitted keys out of order, so the file is not reproducible: \(keys)")
        }
    }

    /// Unknown keys preserved by the `extra` bag must sort in with everything
    /// else rather than being appended, or a project carrying one churns on the
    /// save after any build that does not know it.
    @Test func preservedUnknownKeysSortInWithTheRest() throws {
        let json = String(decoding: try ProjectJSON.encodeManifest(fullManifest()), as: UTF8.self)
        let root = objectsKeys(json).last ?? []
        #expect(root.contains("aaFutureKey") && root.contains("zzFutureKey"))
        #expect(root == root.sorted(), "unknown keys must not be appended after the known ones")
        #expect(root.firstIndex(of: "aaFutureKey")! < root.firstIndex(of: "archived")!,
                "an unknown key sorting before a known one must actually land there")
    }

    /// Determinism is the point, and encoding twice in ONE process would not
    /// show it — the hash seed is fixed per process, so the old code was already
    /// stable within a launch. Sortedness is the process-independent property
    /// that stands in for it, and this pins that the two encodes agree at all.
    @Test func twoEncodesOfTheSameManifestAreByteIdentical() throws {
        let m = fullManifest()
        #expect(try ProjectJSON.encodeManifest(m) == (try ProjectJSON.encodeManifest(m)))
    }

    /// The null-vs-absent shape is the half of the Windows contract macOS DOES
    /// reproduce, and `.sortedKeys` must not disturb it.
    @Test func nullVersusAbsentStillMatchesWindows() throws {
        let bare = ProjectManifest(id: "p", title: "T", createdAt: "a", updatedAt: "b")
        let json = String(decoding: try ProjectJSON.encodeManifest(bare), as: UTF8.self)
        for k in ["captureSettings", "intro", "sopBackup", "archivedAt"] {
            #expect(json.contains("\"\(k)\" : null"), "\(k) is written as null on Windows")
        }
        for k in ["displayScale", "theme", "introEditedByUser"] {
            #expect(!json.contains(k), "\(k) is omitted when unset on Windows")
        }
    }
}
