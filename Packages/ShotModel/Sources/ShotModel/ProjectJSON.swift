import Foundation

/// Encoder/decoder configuration for `project.json`, shared by the store and
/// tests so the on-disk format can't drift between call sites.
public enum ProjectJSON {
    /// Mirrors the Windows writer: `JSON.stringify(manifest, null, 2)` — pretty
    /// two-space indent, "/" not escaped, keys in writer order (not sorted).
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func decodeManifest(_ data: Data) throws -> ProjectManifest {
        try decoder().decode(ProjectManifest.self, from: data)
    }

    public static func encodeManifest(_ manifest: ProjectManifest) throws -> Data {
        try encoder().encode(manifest)
    }

    /// "2026-07-02T12:34:56.789Z" — the exact shape JS `Date.toISOString()` writes.
    public static func isoNow(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
