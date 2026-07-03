import Foundation

/// The single source of truth for shotAI's path-traversal boundary, ported from
/// `shotAI-original/src/main/path-confine.ts`. Every read or write of a
/// manifest-supplied relative path (step screenshots, flattened renders, delete
/// targets) must pass through here — a hand-edited `project.json` must not be
/// able to point the app outside its own project folder.
///
/// Semantics match Node's `path.resolve` + `path.relative` (purely LEXICAL — no
/// symlink resolution, same as the original; symlink hardening would land here).

/// Confine a project-relative path to `dir`: resolve it and return nil if it
/// escapes the folder, equals the folder root, or is absolute. Otherwise return
/// the resolved absolute path.
public func confinePath(dir: String, rel: String) -> String? {
    let base = lexicallyResolve(dir)
    let abs = rel.hasPrefix("/") ? lexicallyResolve(rel) : lexicallyResolve(base + "/" + rel)
    // Inside means strictly under the folder — never the folder root itself.
    guard abs != base, abs.hasPrefix(base == "/" ? "/" : base + "/") else { return nil }
    return abs
}

/// Lexically normalize an absolute path: collapse "//", ".", and ".." segments
/// without touching the filesystem. ".." at the root stays at the root, matching
/// POSIX `path.resolve`.
func lexicallyResolve(_ path: String) -> String {
    precondition(path.hasPrefix("/"), "confinePath requires absolute paths")
    var stack: [Substring] = []
    for component in path.split(separator: "/") {
        switch component {
        case ".":
            continue
        case "..":
            if !stack.isEmpty { stack.removeLast() }
        default:
            stack.append(component)
        }
    }
    return "/" + stack.joined(separator: "/")
}
