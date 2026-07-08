import Foundation

/// ProjectStore — creates, opens, and lists shotAI projects on disk. Port of
/// `shotAI-original/src/main/project-store.ts` (Phase A surface: read, list,
/// create, rename, and the serialized `mutate` primitive; step/capture mutations
/// arrive with Phase B).
///
/// Being an actor replaces the original's `writeQueue` promise chain: every
/// read-modify-write runs isolated, so concurrent mutations can't interleave or
/// lose updates (see MutateSerializeTests).
public actor ProjectStore {
    public enum StoreError: Error, LocalizedError, Equatable {
        case notAKnownProject(String)
        case manifestUnreadable(String)
        case stepNotFound(String)
        case cannotMergeIntoSelf
        case renderPathNotConfined(String)

        public var errorDescription: String? {
            switch self {
            case .notAKnownProject(let p):
                "Project path is not within the projects directory: \(p)"
            case .manifestUnreadable(let p):
                "Could not read \(projectManifestFilename) in \(p)"
            case .stepNotFound(let id):
                "Step \(id) not found"
            case .cannotMergeIntoSelf:
                "Cannot merge a step into itself"
            case .renderPathNotConfined(let id):
                "Refusing to write render for step \"\(id)\" — path escapes the project folder"
            }
        }
    }

    private let settings: any SettingsStore
    private let fm = FileManager.default

    public init(settings: any SettingsStore) {
        self.settings = settings
    }

    public func projectsDir() -> String {
        settings.projectsDir()
    }

    // MARK: - Confinement

    /// Allow opening a project only if its path is inside the current projects
    /// root OR is a path the app itself recorded in recents (e.g. under a
    /// previous root, or explicitly picked by the user in the open panel).
    private func resolveKnownProject(_ projectPath: String) throws -> String {
        let resolved = lexicallyResolve(absolutize(projectPath))
        let root = lexicallyResolve(absolutize(settings.projectsDir()))
        if resolved != root, resolved.hasPrefix(root == "/" ? "/" : root + "/") {
            return resolved
        }
        if settings.recents().contains(where: { lexicallyResolve(absolutize($0)) == resolved }) {
            return resolved
        }
        throw StoreError.notAKnownProject(projectPath)
    }

    private func absolutize(_ path: String) -> String {
        path.hasPrefix("/") ? path : fm.currentDirectoryPath + "/" + path
    }

    // MARK: - Manifest IO

    /// Read + validate a project manifest, defaulting missing/corrupt fields
    /// (the decoders carry the Windows readManifest coercions; the title
    /// fallback to the folder name lives here because it needs the path).
    private func readManifest(at projectPath: String) throws -> ProjectManifest {
        let file = (projectPath as NSString).appendingPathComponent(projectManifestFilename)
        guard let data = fm.contents(atPath: file) else {
            throw StoreError.manifestUnreadable(projectPath)
        }
        do {
            var manifest = try ProjectJSON.decodeManifest(data)
            if manifest.title.isEmpty {
                manifest.title = (projectPath as NSString).lastPathComponent
            }
            return manifest
        } catch {
            throw StoreError.manifestUnreadable(projectPath)
        }
    }

    private func writeManifest(_ manifest: ProjectManifest, at projectPath: String) throws {
        let file = (projectPath as NSString).appendingPathComponent(projectManifestFilename)
        try writeFileAtomic(ProjectJSON.encodeManifest(manifest), to: file)
    }

    /// Write a step's re-baked render under export/.render and point the step at
    /// it (symlink-confined: a hand-edited manifest id with traversal segments,
    /// or a symlinked export/, can't escape the project). Bumps renderRev so the
    /// report cache-busts the image.
    private func writeStepRender(resolved: String, step: inout ProjectStep, id: String, png: Data) throws {
        let rel = "export/.render/\(id).png"
        guard let abs = confinePathNoSymlinks(dir: resolved, rel: rel) else {
            throw StoreError.renderPathNotConfined(id)
        }
        try fm.createDirectory(atPath: (abs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try png.write(to: URL(fileURLWithPath: abs))
        step.flattened = rel
        step.renderRev = (step.renderRev ?? 0) + 1
    }

    private func summarize(_ manifest: ProjectManifest, at projectPath: String) -> ProjectSummary {
        ProjectSummary(
            id: manifest.id,
            title: manifest.title,
            path: projectPath,
            createdAt: manifest.createdAt,
            updatedAt: manifest.updatedAt,
            stepCount: manifest.steps.count
        )
    }

    // MARK: - Open / list

    public struct OpenedProject: Sendable {
        /// Resolved absolute project folder — the confinement root for every
        /// image read inside it.
        public let dir: String
        public let manifest: ProjectManifest
    }

    /// Read an existing project's manifest and mark it recently opened.
    /// Back-fills a stable id for older projects, persisted once on open
    /// (best-effort, as in the original).
    public func openProject(at projectPath: String) throws -> OpenedProject {
        let resolved = try resolveKnownProject(projectPath)
        var manifest = try readManifest(at: resolved)
        if manifest.id.isEmpty {
            manifest.id = UUID().uuidString.lowercased()
            try? writeManifest(manifest, at: resolved)
        }
        settings.addRecent(resolved)
        return OpenedProject(dir: resolved, manifest: manifest)
    }

    /// Register a folder the user explicitly picked (open panel) so it becomes a
    /// "known" project, then open it. Validates the manifest BEFORE recording it.
    public func openUserSelectedProject(at projectPath: String) throws -> OpenedProject {
        let resolved = lexicallyResolve(absolutize(projectPath))
        _ = try readManifest(at: resolved) // must be a real project before we trust it
        settings.addRecent(resolved)
        return try openProject(at: resolved)
    }

    /// All projects for the home screen: every subfolder of the projects root
    /// with a valid manifest, PLUS any still-valid recents outside that root.
    /// Deduped by resolved path; sorted most-recently-updated first.
    public func listProjects() -> [ProjectSummary] {
        let root = lexicallyResolve(absolutize(settings.projectsDir()))
        var summaries: [ProjectSummary] = []
        var seen = Set<String>()

        let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        for name in names.sorted() {
            let dir = (root as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let manifest = try? readManifest(at: dir) else { continue }
            summaries.append(summarize(manifest, at: dir))
            seen.insert(dir)
        }
        for recent in settings.recents() {
            let abs = lexicallyResolve(absolutize(recent))
            guard !seen.contains(abs) else { continue }
            guard let manifest = try? readManifest(at: abs) else { continue }
            summaries.append(summarize(manifest, at: abs))
            seen.insert(abs)
        }
        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Create / mutate

    /// Create a new, empty project folder (named by uuid — the human title lives
    /// only in the manifest) and write its v1 manifest.
    public func createProject(title: String? = nil) throws -> ProjectSummary {
        let root = lexicallyResolve(absolutize(settings.projectsDir()))
        let id = UUID().uuidString.lowercased()
        let dir = (root as NSString).appendingPathComponent(id)
        try fm.createDirectory(atPath: (dir as NSString).appendingPathComponent("shots"), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (dir as NSString).appendingPathComponent("export"), withIntermediateDirectories: true)

        let now = ProjectJSON.isoNow()
        let name = (title ?? "").trimmingCharacters(in: .whitespaces)
        let manifest = ProjectManifest(
            id: id,
            title: name.isEmpty ? Self.defaultTitle() : name,
            createdAt: now,
            updatedAt: now
        )
        try writeManifest(manifest, at: dir)
        settings.addRecent(dir)
        return summarize(manifest, at: dir)
    }

    /// Run a read-modify-write against a project's manifest, actor-serialized.
    /// `fn` mutates in place and may throw to abort without writing; on success
    /// updatedAt is bumped and the manifest written atomically.
    @discardableResult
    public func mutate(
        at projectPath: String,
        _ fn: @Sendable (inout ProjectManifest) throws -> Void
    ) throws -> ProjectManifest {
        let resolved = try resolveKnownProject(projectPath)
        var manifest = try readManifest(at: resolved)
        try fn(&manifest)
        manifest.updatedAt = ProjectJSON.isoNow()
        try writeManifest(manifest, at: resolved)
        return manifest
    }

    /// Rename a project (title only — the folder stays in place so the path and
    /// recents stay valid).
    @discardableResult
    public func renameProject(at projectPath: String, title: String) throws -> ProjectSummary {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? Self.defaultTitle() : trimmed
        let manifest = try mutate(at: projectPath) { m in
            if m.id.isEmpty { m.id = UUID().uuidString.lowercased() }
            m.title = name
        }
        return summarize(manifest, at: try resolveKnownProject(projectPath))
    }

    // MARK: - Step mutations (Phase B capture surface)

    /// Reassign step.order to 1..N in array order. step.order tracks array
    /// position, not the capture filename counter (which climbs past orphaned
    /// step-NNNN.png files left by deletes).
    public static func renumber(_ steps: inout [ProjectStep]) {
        for i in steps.indices {
            steps[i].order = i + 1
        }
    }

    /// Append a captured step to a project's manifest (serialized, atomic).
    public func addStep(at projectPath: String, _ step: ProjectStep) throws {
        try mutate(at: projectPath) { m in
            m.steps.append(step)
            Self.renumber(&m.steps)
        }
    }

    /// Insert an already-built step at `atIndex` (clamped; nil → append), then
    /// renumber. Used by the single-shot capture path to drop a recorded
    /// screenshot at a chosen position.
    public func insertStep(at projectPath: String, _ step: ProjectStep, atIndex: Int?) throws {
        try mutate(at: projectPath) { m in
            let i = atIndex.map { max(0, min($0, m.steps.count)) } ?? m.steps.count
            m.steps.insert(step, at: i)
            Self.renumber(&m.steps)
        }
    }

    /// Delete multiple steps by id (e.g. discarding a capture session's
    /// additions): removes them from the manifest, renumbers, and best-effort
    /// deletes each one's screenshot + flattened render from disk. Every
    /// manifest-sourced path is CONFINED to the project folder before the rm
    /// (defends against a hand-edited traversal path).
    @discardableResult
    public func deleteSteps(at projectPath: String, ids: [String]) throws -> ProjectManifest {
        // Read-modify-write inline (not via mutate) because we need the removed
        // steps afterwards; actor isolation provides the same serialization.
        let resolved = try resolveKnownProject(projectPath)
        var manifest = try readManifest(at: resolved)
        let idSet = Set(ids)
        let removed = manifest.steps.filter { idSet.contains($0.id) }
        manifest.steps.removeAll { idSet.contains($0.id) }
        Self.renumber(&manifest.steps)
        manifest.updatedAt = ProjectJSON.isoNow()
        try writeManifest(manifest, at: resolved)
        for step in removed {
            for rel in [step.screenshot, step.flattened ?? ""] where !rel.isEmpty {
                // Symlink-hardened: a manifest path through a symlinked `shots`
                // (or any component) would let removeItem delete OUTSIDE the
                // project — skip it, same as any other confinement failure.
                guard let abs = confinePathNoSymlinks(dir: resolved, rel: rel) else { continue }
                try? fm.removeItem(atPath: abs)
            }
        }
        return manifest
    }

    /// Persist the project's capture target (chosen before recording).
    public func setCaptureSettings(at projectPath: String, _ target: CaptureTarget?) throws {
        try mutate(at: projectPath) { m in
            m.captureSettings = target
        }
    }

    /// Apply an editor patch to one step. If `flattenedPng` is given, write it
    /// into the render cache and point step.flattened at it; otherwise a patch
    /// that changed redaction/crop invalidates the stale render (freshness). The
    /// render write is symlink-confined. Returns the updated manifest.
    @discardableResult
    public func updateStep(
        at projectPath: String, stepId: String, patch: StepPatch, flattenedPng: Data? = nil
    ) throws -> ProjectManifest {
        let resolved = try resolveKnownProject(projectPath)
        var manifest = try readManifest(at: resolved)
        guard let idx = manifest.steps.firstIndex(where: { $0.id == stepId }) else {
            throw StoreError.stepNotFound(stepId)
        }
        let hasFresh = (flattenedPng?.isEmpty == false)
        applyPatchAndInvalidate(&manifest.steps[idx], patch, hasFreshPng: hasFresh)
        if let png = flattenedPng, !png.isEmpty {
            try writeStepRender(resolved: resolved, step: &manifest.steps[idx], id: stepId, png: png)
        }
        manifest.updatedAt = ProjectJSON.isoNow()
        try writeManifest(manifest, at: resolved)
        return manifest
    }

    /// Merge two steps into one: apply `patch` (+ optional re-baked render) to
    /// the KEPT step, delete the DROPPED step, then renumber — atomically. Used
    /// by the report to fold a right-click step into its menu-selection step
    /// (the discarded click is carried onto the kept screenshot as a marker
    /// baked into `flattenedPng`). The merged step stays at the DROPPED step's
    /// position so the flow reads in the original order.
    @discardableResult
    public func mergeSteps(
        at projectPath: String, keepId: String, dropId: String,
        patch: StepPatch, flattenedPng: Data? = nil
    ) throws -> ProjectManifest {
        guard keepId != dropId else { throw StoreError.cannotMergeIntoSelf }
        let resolved = try resolveKnownProject(projectPath)
        var manifest = try readManifest(at: resolved)
        guard let keepIdx = manifest.steps.firstIndex(where: { $0.id == keepId }) else {
            throw StoreError.stepNotFound(keepId)
        }
        guard let dropIdx = manifest.steps.firstIndex(where: { $0.id == dropId }) else {
            throw StoreError.stepNotFound(dropId)
        }
        let hasFresh = (flattenedPng?.isEmpty == false)
        applyPatchAndInvalidate(&manifest.steps[keepIdx], patch, hasFreshPng: hasFresh)
        if let png = flattenedPng, !png.isEmpty {
            try writeStepRender(resolved: resolved, step: &manifest.steps[keepIdx], id: keepId, png: png)
        }
        manifest.steps.remove(at: dropIdx)
        Self.renumber(&manifest.steps)
        manifest.updatedAt = ProjectJSON.isoNow()
        try writeManifest(manifest, at: resolved)
        return manifest
    }

    /// Delete a project: remove its folder (originals included) and drop it
    /// from recents. Confined to a known project. A folder already gone from
    /// disk (moved/cloud-synced away) is tolerated so recents is still pruned
    /// — mirrors the Windows `fs.rm(..., { force: true })`.
    public func deleteProject(at projectPath: String) throws {
        let resolved = try resolveKnownProject(projectPath)
        if fm.fileExists(atPath: resolved) {
            try fm.removeItem(atPath: resolved)
        }
        let pruned = settings.recents().filter { lexicallyResolve(absolutize($0)) != resolved }
        settings.setRecents(pruned)
    }

    /// "Project yyyy/MM/dd HH:mm:ss" (local time) — same default as Windows.
    private static func defaultTitle() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return "Project \(f.string(from: Date()))"
    }
}
