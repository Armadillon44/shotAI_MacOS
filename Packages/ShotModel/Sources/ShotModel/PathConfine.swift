import Foundation

/// The single source of truth for shotAI's path-traversal boundary, ported from
/// `shotAI-original/src/main/path-confine.ts`. Every read or write of a
/// manifest-supplied relative path (step screenshots, flattened renders, delete
/// targets) must pass through here — a hand-edited `project.json` must not be
/// able to point the app outside its own project folder.
///
/// Semantics match Node's `path.resolve` + `path.relative` (purely LEXICAL — no
/// symlink resolution, same as the original). For any path the app is about to
/// WRITE, CREATE, or DELETE, use `confinePathNoSymlinks` instead — the lexical
/// check alone can be defeated by a symlinked path component (see below).

/// Confine a project-relative path to `dir`: resolve it and return nil if it
/// escapes the folder, equals the folder root, or is absolute. Otherwise return
/// the resolved absolute path.
///
/// LEXICAL ONLY: a hand-edited `project.json` can't point outside the folder,
/// but a symlinked component (e.g. `shots` → ~/Documents) still resolves
/// "inside" here. Read paths use this; mutating paths must go through
/// `confinePathNoSymlinks`.
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

/// Filesystem-hardened confinement — the boundary for every project write,
/// directory creation, and delete. `confinePath` is purely lexical, so it can't
/// tell that a project's `shots` directory (or any component beneath the
/// project root) is a SYMLINK pointing outside the folder. Because the app
/// registers any user-picked folder with a valid `project.json` as a known
/// project, a hostile or shared project could plant such a symlink to redirect
/// the engine's PNG writes, the `shots/` mkdir, or `deleteSteps`' file removal
/// out of its own folder while the path still looks "inside".
///
/// This lexically confines `rel` under `dir` and then rejects if any component
/// from the project root down to the leaf is a symbolic link. Returns the same
/// resolved absolute path as `confinePath` when every existing component is a
/// real file/directory; nil when the lexical check fails OR a component is a
/// symlink. A component that doesn't exist yet — the leaf PNG about to be
/// written, the `shots/` dir about to be created — can't redirect anything, so
/// it passes; the capture path re-checks at each real write, keeping the
/// check-then-act (TOCTOU) window small. Symlinks in `dir`'s own ancestry are
/// the user's legitimate layout and intentionally not flagged.
///
/// Parity note: keep this in lockstep with the Windows app's
/// `src/main/path-confine.ts`. `confinePath` mirrors Node `path.resolve` +
/// `path.relative`; this is the `fs.lstat`-reject layer the Windows app should
/// grow when symlink hardening lands there too.
public func confinePathNoSymlinks(dir: String, rel: String) -> String? {
    guard let abs = confinePath(dir: dir, rel: rel) else { return nil }
    let base = lexicallyResolve(dir)
    // `abs` is guaranteed strictly under `base`, so this drop yields the
    // in-project tail. lstat semantics never follow the final component, so
    // walking one component at a time catches the FIRST symlink and stops
    // before the OS would resolve it.
    let tail = abs.dropFirst(base == "/" ? 1 : base.count + 1)
    var current = base
    for component in tail.split(separator: "/") {
        current += "/" + component
        if pathIsSymlink(current) { return nil }
    }
    return abs
}

/// True iff `path` is itself a symbolic link — lstat semantics, the target is
/// never followed. `FileManager.attributesOfItem`/`fileExists` resolve links
/// and so are deliberately avoided. A path that doesn't exist is not a symlink.
func pathIsSymlink(_ path: String) -> Bool {
    (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]))?
        .isSymbolicLink ?? false
}
