import Foundation

/// Encoder/decoder configuration for `project.json`, shared by the store and
/// tests so the on-disk format can't drift between call sites.
public enum ProjectJSON {
    /// Two-space pretty indent and unescaped "/", matching
    /// `JSON.stringify(manifest, null, 2)`, plus **sorted keys**.
    ///
    /// `.sortedKeys` is the fix for #110 and is load-bearing. Without it a
    /// `JSONEncoder` keyed container emits in the underlying dictionary's hash
    /// order, which Swift seeds per process — so the SAME unmodified manifest
    /// encoded in two app launches produced two different key orders, at every
    /// nesting level. The first save after each launch rewrote the whole file,
    /// which is a whole-file diff in git, Dropbox or OneDrive for a one-character
    /// caption edit.
    ///
    /// Note what this does NOT fix: `encode(to:)` lists the keys in the Windows
    /// writer's order, and `JSONEncoder` ignores call order for a keyed
    /// container entirely. That list is therefore not an ordering mechanism and
    /// never was. It still decides null-vs-omitted, which IS part of the
    /// contract, so do not collapse it into a synthesised dictionary.
    ///
    /// Alphabetical rather than Windows' order because matching Windows byte for
    /// byte is not reachable from this side alone: its step entries inherit
    /// their key order from the input file via a spread, its unknown keys are
    /// written FIRST for a safety property it should not trade away, and it has
    /// its own once-per-conditional-key reordering (Armadillon44/shotAI#117).
    /// Its own source says key order is not part of the cross-platform contract.
    /// Determinism is what this repo can deliver alone, and it is the half that
    /// actually stops the churn.
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
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
