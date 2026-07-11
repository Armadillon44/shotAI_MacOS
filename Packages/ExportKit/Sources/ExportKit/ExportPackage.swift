import Foundation
import ShotModel

// Shareable project package (.zip) that round-trips with the Windows app: export
// it, send it to a colleague, they import + edit it in shotAI. Two modes (chosen
// at export):
//   - safe (default): only the redaction-baked renders travel — redactions are
//     permanent, un-redacted originals never leave the machine.
//   - full: the un-redacted originals travel too, for complete re-editing (an
//     explicit opt-in the UI warns about).
// Import treats the zip as UNTRUSTED: size caps, a folder whitelist, image
// magic-byte checks, and per-file symlink-confinement (in createProjectFromImport).
// Ported from shotAI-original/src/main/export-package.ts.

private let PKG_MARKER = "shotai-package.json"
private let PKG_FORMAT = "shotai-package"
private let PKG_VERSION = 1
private let MAX_PKG_BYTES = 600 * 1024 * 1024   // whole .zip and total extracted
private let MAX_FILE_BYTES = 80 * 1024 * 1024   // any single extracted image

public struct PackageResult: Sendable {
    public let outputPath: String
    public let includeOriginals: Bool
}

public enum PackageError: Error, LocalizedError, Equatable {
    case nothingToExport
    case notAPackage
    case markerCorrupt
    case unrecognizedFormat
    case tooNew
    case missingManifest
    case manifestCorrupt
    case nonImage(String)
    case tooLarge
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToExport: "This project has nothing to export yet — add a step first."
        case .notAPackage: "This file is not a shotAI project package."
        case .markerCorrupt: "The package marker is corrupt."
        case .unrecognizedFormat: "Unrecognized package format."
        case .tooNew: "This package was created by a newer version of shotAI. Update to import it."
        case .missingManifest: "The package is missing its project.json."
        case .manifestCorrupt: "The package project.json is corrupt."
        case .nonImage(let rel): "The package contains a non-image file where an image was expected: \(rel)"
        case .tooLarge: "This package is too large to import."
        case .writeFailed(let m): "Could not write the package: \(m)"
        }
    }
}

private func isPngOrJpeg(_ b: Data) -> Bool {
    let a = [UInt8](b.prefix(4))
    if a.count >= 4, a[0] == 0x89, a[1] == 0x50, a[2] == 0x4E, a[3] == 0x47 { return true } // PNG
    if a.count >= 3, a[0] == 0xFF, a[1] == 0xD8, a[2] == 0xFF { return true }               // JPEG
    return false
}

// MARK: - Export

/// Assemble a shareable package for the project at `dir`. The caller is expected
/// to have flattened all shot steps first (so every shot has a current redaction-
/// and marker-baked render), same as the other exports. Returns the written path.
public func exportPackage(dir: String, manifest: ProjectManifest, includeOriginals: Bool) throws -> PackageResult {
    guard !manifest.steps.isEmpty else { throw PackageError.nothingToExport }

    var entries: [(name: String, data: Data)] = []
    // Work on a clone; never share the sender's local revert history.
    var out = manifest
    out.sopBackup = nil

    if includeOriginals {
        // Full fidelity: ship exactly the files the manifest references.
        for step in out.steps where step.kind != .text {
            addFileRef(&entries, dir: dir, rel: step.screenshot)
            if let f = step.flattened, !f.isEmpty { addFileRef(&entries, dir: dir, rel: f) }
        }
    } else {
        // Safe: collapse each shot to its SENDABLE (redaction-baked) render, which
        // becomes the new base image. Fail-closed via resolveSendableRender.
        var n = 0
        for i in out.steps.indices where out.steps[i].kind != .text {
            n += 1
            let render = try resolveSendableRender(dir: dir, step: out.steps[i], stepLabel: "Step \(n)", verb: "export")
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: render.abs)) else {
                throw PackageError.writeFailed("Step \(n)'s render could not be read.")
            }
            let name = "shots/step-\(String(format: "%04d", n)).\(render.ext)"
            entries.append((name, bytes))
            out.steps[i].screenshot = name
            out.steps[i].annotations = []
            out.steps[i].crop = nil
            out.steps[i].click = nil          // the click ring is baked into the render
            out.steps[i].flattened = nil
            out.steps[i].renderRev = 0
            out.steps[i].markerBaked = false
        }
    }

    // project.json (the mutated clone) + the package marker.
    guard let projectJSON = try? ProjectJSON.encodeManifest(out) else {
        throw PackageError.writeFailed("Could not encode project.json.")
    }
    entries.append(("project.json", projectJSON))
    entries.append((PKG_MARKER, try markerJSON(includeOriginals: includeOriginals)))

    let zip = zipStored(entries)

    let exportDir = (dir as NSString).appendingPathComponent("export")
    do {
        try FileManager.default.createDirectory(atPath: exportDir, withIntermediateDirectories: true)
    } catch {
        throw PackageError.writeFailed(error.localizedDescription)
    }
    let base = safeFileBase(manifest.title)
    let stem = nextAvailableStem(exportDir: exportDir, stem: "\(base) (shotAI package)", ext: ".zip")
    let outputPath = (exportDir as NSString).appendingPathComponent("\(stem).zip")
    do {
        try zip.write(to: URL(fileURLWithPath: outputPath))
    } catch {
        throw PackageError.writeFailed(error.localizedDescription)
    }
    return PackageResult(outputPath: outputPath, includeOriginals: includeOriginals)
}

/// Add a manifest-relative file to `entries` at the same relative path (confined,
/// best-effort: a missing referenced file is skipped, matching the Windows app).
private func addFileRef(_ entries: inout [(name: String, data: Data)], dir: String, rel: String) {
    guard !rel.isEmpty, let abs = confinePath(dir: dir, rel: rel),
          let bytes = try? Data(contentsOf: URL(fileURLWithPath: abs)) else { return }
    entries.append((rel.replacingOccurrences(of: "\\", with: "/"), bytes))
}

private func markerJSON(includeOriginals: Bool) throws -> Data {
    struct Marker: Encodable {
        let format: String, version: Int, app: String, includeOriginals: Bool, exportedAt: String
    }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try enc.encode(Marker(
        format: PKG_FORMAT, version: PKG_VERSION, app: "shotAI",
        includeOriginals: includeOriginals, exportedAt: ProjectJSON.isoNow()))
}

// MARK: - Import

/// Import a project package from an absolute .zip path (the caller picked it). The
/// zip is UNTRUSTED: enforce size caps, validate the marker + manifest, whitelist
/// image entries by folder + magic bytes, and let `createProjectFromImport` confine
/// every extracted path into the fresh project folder. Returns the new project.
public func importPackage(zipPath: String, into store: ProjectStore) async throws -> ProjectSummary {
    let attrs = try? FileManager.default.attributesOfItem(atPath: zipPath)
    let zipSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
    guard zipSize > 0, zipSize <= MAX_PKG_BYTES else { throw PackageError.tooLarge }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: zipPath)) else {
        throw PackageError.notAPackage
    }

    // List metadata only — nothing is decompressed yet. We then inflate ONLY the
    // entries we keep (marker, project.json, whitelisted images), capping the
    // running total FIRST, so a zip bomb of junk/non-whitelisted entries can't
    // exhaust memory (parity with the Windows streaming extraction).
    let items: [ZipItem]
    do {
        items = try zipList(data)
    } catch {
        throw PackageError.notAPackage
    }

    func extract(_ name: String, cap: Int) throws -> Data? {
        guard let it = items.first(where: { $0.name == name }) else { return nil }
        guard it.uncompressedSize <= cap else { throw PackageError.tooLarge }
        do { return try zipExtract(data, it) } catch { throw PackageError.notAPackage }
    }

    // Marker: must be present, well-formed, our format, not from the future.
    guard let markerData = try extract(PKG_MARKER, cap: MAX_FILE_BYTES) else { throw PackageError.notAPackage }
    guard let markerObj = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any] else {
        throw PackageError.markerCorrupt
    }
    guard (markerObj["format"] as? String) == PKG_FORMAT else { throw PackageError.unrecognizedFormat }
    if let v = markerObj["version"] as? Int, v > PKG_VERSION { throw PackageError.tooNew }

    // Manifest.
    guard let manifestData = try extract("project.json", cap: MAX_FILE_BYTES) else { throw PackageError.missingManifest }
    guard let manifest = try? ProjectJSON.decodeManifest(manifestData) else { throw PackageError.manifestCorrupt }

    // Collect image files: whitelist folder + running total cap (checked on the
    // DECLARED size before inflating) + per-file cap + magic bytes.
    var files: [ProjectStore.ImportFile] = []
    var total = 0
    for it in items {
        let rel = it.name.replacingOccurrences(of: "\\", with: "/")
        if rel == PKG_MARKER || rel == "project.json" { continue }
        guard ProjectStore.isImportableImagePath(rel) else { continue } // ignore anything unexpected
        guard it.uncompressedSize <= MAX_FILE_BYTES else { throw PackageError.tooLarge }
        total += it.uncompressedSize
        guard total <= MAX_PKG_BYTES else { throw PackageError.tooLarge }
        let bytes: Data
        do { bytes = try zipExtract(data, it) } catch { throw PackageError.notAPackage }
        guard isPngOrJpeg(bytes) else { throw PackageError.nonImage(rel) }
        files.append(ProjectStore.ImportFile(rel: rel, bytes: bytes))
    }

    return try await store.createProjectFromImport(manifest: manifest, files: files)
}
