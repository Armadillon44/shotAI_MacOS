import Foundation

/// Turn a project title into a safe filename base (no extension). Ported from
/// export.ts safeFileBase — keeps the Windows device-name reservation so exported
/// filenames stay cross-platform-safe.
func safeFileBase(_ title: String) -> String {
    let reserved: Set<Unicode.Scalar> = Set("<>:\"/\\|?*".unicodeScalars)
    var s = String(String.UnicodeScalarView(
        title.unicodeScalars.filter { $0.value > 0x1f && !reserved.contains($0) }))
    s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    if s.count > 120 { s = String(s.prefix(120)).trimmingCharacters(in: .whitespaces) }
    s = s.replacingOccurrences(of: "[.\\s]+$", with: "", options: .regularExpression)
    if s.isEmpty { return "shotAI SOP" }
    let reservedName = "^(con|prn|aux|nul|com[1-9]|lpt[1-9])$"
    if s.range(of: reservedName, options: [.regularExpression, .caseInsensitive]) != nil || s.hasPrefix(".") {
        return "_" + s
    }
    return s
}

/// First non-existent `<stem><ext>` in `exportDir`, appending ` (1)`, ` (2)`, …
/// on collision (note the leading space). Returns the stem WITHOUT the extension.
func nextAvailableStem(exportDir: String, stem: String, ext: String) -> String {
    var n = 0
    while true {
        let candidate = n == 0 ? stem : "\(stem) (\(n))"
        let path = (exportDir as NSString).appendingPathComponent(candidate + ext)
        if !FileManager.default.fileExists(atPath: path) { return candidate }
        n += 1
    }
}

/// HTML-escape text for the templates. Order matters (ampersand first). Single
/// quotes are intentionally NOT escaped — every attribute in the templates uses
/// double quotes (keep that invariant if you touch them).
func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Backslash-escape the Markdown metacharacters. Applied ONLY to title /
/// created-line / headings / captions / callout-heading — body & note text is
/// emitted RAW so authored Markdown renders.
func escapeMarkdown(_ s: String) -> String {
    let specials: Set<Character> = ["\\", "`", "*", "_", "[", "]", "#", "<", ">"]
    var out = ""
    out.reserveCapacity(s.count)
    for c in s {
        if specials.contains(c) { out.append("\\") }
        out.append(c)
    }
    return out
}
