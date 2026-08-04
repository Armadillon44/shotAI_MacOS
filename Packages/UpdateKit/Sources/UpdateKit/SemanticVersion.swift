import Foundation

/// A parsed `MAJOR.MINOR.PATCH[-PRERELEASE]` version.
///
/// Built for one job: deciding whether a GitHub release tag is newer than the
/// running `CFBundleShortVersionString`. It is deliberately FAIL-CLOSED — any
/// input this can't parse returns nil, and a nil on either side means "no update
/// available". A missed notification is a nuisance; a false one sends the user to
/// download a build older than the one they're running.
///
/// Both of the obvious one-liners are measurably wrong for our tags:
/// - lexicographic: `"1.9.0" < "1.10.0"` is **false** (`'9' > '1'`).
/// - `.compare(options: .numeric)`: ranks `1.0.0-rc1` **newer** than `1.0.0`.
///
/// ## Deliberate divergence from SemVer 2.0.0
/// Strict SemVer compares a prerelease identifier containing letters ASCII-
/// lexically, which orders `rc10 < rc2`. Our tags are `-rc1 … -rc4` (the
/// hyphenated prerelease form matches the Windows app's version strings), so
/// identifiers are compared in NATURAL order instead: each identifier is
/// split into digit and non-digit runs and the digit runs compare numerically, so
/// `rc2 < rc10`. Purely numeric identifiers still compare numerically, matching
/// SemVer. We author every tag this compares, so the friendlier ordering is safe
/// and it's the behaviour issue #62's acceptance table asks for.
public struct SemanticVersion: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The `-…` suffix (`"rc1"`), or nil for a final release. Never empty:
    /// a trailing bare hyphen fails the parse rather than becoming `""`.
    public let prerelease: String?

    public var isPrerelease: Bool { prerelease != nil }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.map { "\(core)-\($0)" } ?? core
    }

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parse a version string or a release tag. Accepts an optional leading `v`
    /// and surrounding whitespace; everything else must be exact.
    ///
    /// Rejected (→ nil): empty, fewer or more than three numeric components, a
    /// non-numeric or negative component, a leading `+` build-metadata-only
    /// string, an empty prerelease, and anything with characters we don't expect.
    /// Build metadata (`+sha`) is stripped and IGNORED, as SemVer requires — it
    /// never affects precedence.
    public init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }

        // Build metadata is not part of precedence — drop it before anything else.
        if let plus = s.firstIndex(of: "+") { s = String(s[s.startIndex..<plus]) }

        // Split core from prerelease on the FIRST hyphen: "1.0.0-rc1" and also
        // "1.0.0-beta-2" (prerelease "beta-2") parse the way you'd expect.
        let core: Substring
        var pre: String?
        if let dash = s.firstIndex(of: "-") {
            core = s[s.startIndex..<dash]
            let tail = String(s[s.index(after: dash)...])
            guard !tail.isEmpty else { return nil }   // "1.0.0-" is malformed
            pre = tail
        } else {
            core = s[...]
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var nums: [Int] = []
        for p in parts {
            // `Int(_:)` accepts a leading "+"/"-" and Unicode digits; require
            // plain ASCII digits so "1.-2.0" and "1.٣.0" are both rejected.
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            nums.append(n)
        }
        self.init(major: nums[0], minor: nums[1], patch: nums[2], prerelease: pre)
    }

    public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (nil, .some): return false   // 1.0.0 > 1.0.0-rc1
        case (.some, nil): return true    // 1.0.0-rc1 < 1.0.0
        case let (.some(x), .some(y)): return comparePrerelease(x, y) == .orderedAscending
        }
    }

    /// Dot-separated identifiers, compared left to right; a shorter run of equal
    /// identifiers sorts lower (`1.0.0-rc < 1.0.0-rc.1`), as SemVer specifies.
    static func comparePrerelease(_ x: String, _ y: String) -> ComparisonResult {
        let xs = x.split(separator: ".", omittingEmptySubsequences: false)
        let ys = y.split(separator: ".", omittingEmptySubsequences: false)
        for i in 0..<min(xs.count, ys.count) {
            let r = compareIdentifier(String(xs[i]), String(ys[i]))
            if r != .orderedSame { return r }
        }
        if xs.count == ys.count { return .orderedSame }
        return xs.count < ys.count ? .orderedAscending : .orderedDescending
    }

    /// Natural order within one identifier: split into digit / non-digit runs and
    /// compare digit runs numerically. This is what makes `rc2 < rc10`.
    private static func compareIdentifier(_ x: String, _ y: String) -> ComparisonResult {
        let xr = runs(x), yr = runs(y)
        for i in 0..<min(xr.count, yr.count) {
            let a = xr[i], b = yr[i]
            switch (a.isDigits, b.isDigits) {
            case (true, true):
                // Compare as integers; fall back to length+lexical for runs too
                // long for Int (a pathological tag, but it must not trap).
                if let ai = Int(a.text), let bi = Int(b.text) {
                    if ai != bi { return ai < bi ? .orderedAscending : .orderedDescending }
                } else {
                    let at = a.text.drop(while: { $0 == "0" }), bt = b.text.drop(while: { $0 == "0" })
                    if at.count != bt.count { return at.count < bt.count ? .orderedAscending : .orderedDescending }
                    if at != bt { return at < bt ? .orderedAscending : .orderedDescending }
                }
            case (true, false):
                return .orderedAscending   // numeric identifiers rank below alphanumeric (SemVer)
            case (false, true):
                return .orderedDescending
            case (false, false):
                if a.text != b.text { return a.text < b.text ? .orderedAscending : .orderedDescending }
            }
        }
        if xr.count == yr.count { return .orderedSame }
        return xr.count < yr.count ? .orderedAscending : .orderedDescending
    }

    private struct Run { let text: String; let isDigits: Bool }

    private static func runs(_ s: String) -> [Run] {
        var out: [Run] = []
        var buf = ""
        var digits = false
        for ch in s {
            let d = ch.isASCII && ch.isNumber
            if buf.isEmpty || d == digits {
                buf.append(ch)
                digits = d
            } else {
                out.append(Run(text: buf, isDigits: digits))
                buf = String(ch)
                digits = d
            }
        }
        if !buf.isEmpty { out.append(Run(text: buf, isDigits: digits)) }
        return out
    }
}
