import Foundation
import Testing
@testable import ShotModel

/// The shared `project.json` conformance suite.
///
/// Cases live in `contract/conformance/manifest/` as data, and the Windows app
/// runs the same files against its own codec (`src/shared/conformance.test.ts`).
/// See `contract/conformance/README.md` for the format.
///
/// **The assertion surface is decode-then-encode**, not the store: what a
/// platform writes back for a given input IS the cross-platform contract, and
/// everything else — `updatedAt`, disk layout, ordering — is its own business.
@Suite struct ManifestConformance {
    struct Case: Decodable {
        let name: String
        let why: String
        let status: String
        var issue: String?
        var divergence: String?
        let input: JSONValue
        let expect: [String: JSONValue]
    }

    /// Located from this file rather than the working directory: `swift test`
    /// and Xcode disagree about cwd, and a suite that silently finds zero cases
    /// is worse than one that fails.
    static let dir: URL = {
        URL(fileURLWithPath: #filePath)            // …/Tests/ShotModelTests/ConformanceTests.swift
            .deletingLastPathComponent()           // …/Tests/ShotModelTests
            .deletingLastPathComponent()           // …/Tests
            .deletingLastPathComponent()           // …/ShotModel
            .deletingLastPathComponent()           // …/Packages
            .deletingLastPathComponent()           // repo root
            .appendingPathComponent("contract/conformance/manifest")
    }()

    static let cases: [Case] = {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        return files.compactMap { url in
            guard let d = try? Data(contentsOf: url) else { return nil }
            do { return try JSONDecoder().decode(Case.self, from: d) }
            catch { Issue.record("\(url.lastPathComponent): \(error)"); return nil }
        }
    }()

    /// A dotted path into a decoded JSON object. `steps.0.kind` indexes arrays.
    private static func value(_ root: Any, at path: String) -> Any?? {
        var cur: Any = root
        for part in path.split(separator: ".") {
            if let dict = cur as? [String: Any] {
                guard let next = dict[String(part)] else { return .some(nil) }  // absent
                cur = next
            } else if let arr = cur as? [Any], let i = Int(part), arr.indices.contains(i) {
                cur = arr[i]
            } else {
                return .some(nil)
            }
        }
        return .some(.some(cur))
    }

    /// Re-encode what the codec produces for this input.
    private static func roundTrip(_ input: JSONValue) throws -> [String: Any] {
        let raw = try ProjectJSON.encoder().encode(input)
        let manifest = try ProjectJSON.decoder().decode(ProjectManifest.self, from: raw)
        let out = try ProjectJSON.encoder().encode(manifest)
        return try JSONSerialization.jsonObject(with: out) as? [String: Any] ?? [:]
    }

    @Test func theSuiteIsActuallyLoaded() {
        #expect(!Self.cases.isEmpty, "no conformance cases found at \(Self.dir.path)")
    }

    @Test(arguments: Self.cases)
    func conforms(_ c: Case) throws {
        let got = try Self.roundTrip(c.input)
        var failures: [String] = []

        for (path, want) in c.expect.sorted(by: { $0.key < $1.key }) {
            let found = Self.value(got, at: path) ?? nil
            if case .object(let o) = want, o.count == 1, case .bool(true)? = o["$absent"] {
                if found != nil { failures.append("\(path): expected ABSENT, got \(found!)") }
                continue
            }
            guard let found else { failures.append("\(path): expected \(want), got ABSENT"); continue }
            let wantAny = try JSONSerialization.jsonObject(
                with: try ProjectJSON.encoder().encode(want), options: [.fragmentsAllowed])
            if !NSDictionary(dictionary: ["v": found]).isEqual(to: ["v": wantAny]) {
                failures.append("\(path): expected \(wantAny), got \(found)")
            }
        }

        guard !failures.isEmpty else { return }
        let detail = "\(c.name): \(failures.joined(separator: "; "))"
        if c.status == "open" {
            // A KNOWN divergence. Reported, never failed — see the README: the
            // point is that resolving one is a status flip, so the suite says
            // what is left instead of going quietly green.
            print("[conformance] open divergence — \(detail)\n  \(c.divergence ?? "")\n  tracked: \(c.issue ?? "untracked")")
        } else {
            Issue.record("\(detail)\n  why this matters: \(c.why)")
        }
    }
}
