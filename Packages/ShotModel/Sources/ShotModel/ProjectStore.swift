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
        case notAnImage
        case importPathRejected(String)

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
            case .notAnImage:
                "That file isn't a PNG or JPEG image."
            case .importPathRejected(let rel):
                "The package contains an unexpected file path: \(rel)"
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
        Log.store.error("resolveKnownProject denied: path is not a known project [\(projectPath, privacy: .private)]")
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
            Log.store.error("readManifest: manifest missing/unreadable at [\(projectPath, privacy: .private)]")
            throw StoreError.manifestUnreadable(projectPath)
        }
        do {
            var manifest = try ProjectJSON.decodeManifest(data)
            if manifest.title.isEmpty {
                manifest.title = (projectPath as NSString).lastPathComponent
            }
            return manifest
        } catch {
            Log.store.error("readManifest decode failed [\(String(describing: type(of: error)), privacy: .public)] at [\(projectPath, privacy: .private)]: \(error.localizedDescription, privacy: .private)")
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
            Log.store.error("SECURITY path-confinement refused render write [step \(id, privacy: .public)] rel=[\(rel, privacy: .private)]")
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
            stepCount: manifest.steps.count,
            hasSop: manifest.intro != nil || manifest.steps.contains { $0.aiInserted == true },
            searchText: manifest.searchableText,
            archived: manifest.archived
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
        // Auto-unarchive (F2): opening an archived project restores its bulk files
        // first (fail-closed), keyed on DISK truth so a half-completed archive
        // self-heals. This must NOT count as an edit — no updatedAt bump.
        if Archive.isArchivedOnDisk(resolved) {
            try Archive.unpackArchive(resolved)
        }
        var manifest = try readManifest(at: resolved)
        // Fold the archive-flag clear and the id back-fill into ONE plain write
        // (writeManifest never touches updatedAt).
        var needsWrite = false
        if manifest.archived || manifest.archivedAt != nil {
            manifest.archived = false
            manifest.archivedAt = nil
            needsWrite = true
        }
        if manifest.id.isEmpty {
            manifest.id = UUID().uuidString.lowercased()
            needsWrite = true
        }
        if needsWrite { try? writeManifest(manifest, at: resolved) }
        settings.addRecent(resolved)
        return OpenedProject(dir: resolved, manifest: manifest)
    }

    /// Restore an archived project without opening it (Home "Restore" action):
    /// unpack its files, clear the archived flag, and re-list it. Fail-closed;
    /// does NOT bump updatedAt (restoring isn't an edit). No-op if not archived.
    @discardableResult
    public func unarchiveProject(at projectPath: String) throws -> ProjectSummary {
        let resolved = try resolveKnownProject(projectPath)
        if Archive.isArchivedOnDisk(resolved) {
            try Archive.unpackArchive(resolved)
        }
        var manifest = try readManifest(at: resolved)
        if manifest.archived || manifest.archivedAt != nil {
            manifest.archived = false
            manifest.archivedAt = nil
            try writeManifest(manifest, at: resolved)
        }
        return summarize(manifest, at: resolved)
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
        // Merge in recents outside the root too, so a project opened via
        // "Open Project…" (from anywhere) still appears on Home. Recents are
        // cleared when the user changes the projects folder (AppModel.setProjectsDir),
        // so a folder switch doesn't drag the previous root's projects along.
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
        Log.store.notice("createProject: created project [id \(id, privacy: .public)]")
        return summarize(manifest, at: dir)
    }

    /// One extracted file from an imported package: a manifest-relative path plus
    /// its bytes. The bytes are already magic-byte-validated + size-capped by the
    /// caller (ExportKit's importPackage); this method adds path confinement.
    public struct ImportFile: Sendable {
        public let rel: String
        public let bytes: Data
        public init(rel: String, bytes: Data) {
            self.rel = rel
            self.bytes = bytes
        }
    }

    /// Materialize an imported package into a NEW project folder (a fresh UUID, so
    /// it never collides with the sender's). Files come from an UNTRUSTED zip, so
    /// each is WHITELISTED to `shots/` or `export/.render/` (single segment) and
    /// CONFINED (symlink-hardened) to the new folder — anything else, including a
    /// path-traversal name, is refused. The manifest is re-stamped with the new id
    /// and a cleared sopBackup (the sender's local revert history isn't shared).
    /// Ported from the Windows `createProjectFromImport`.
    public func createProjectFromImport(manifest: ProjectManifest, files: [ImportFile]) throws -> ProjectSummary {
        let root = lexicallyResolve(absolutize(settings.projectsDir()))
        let id = UUID().uuidString.lowercased()
        let dir = (root as NSString).appendingPathComponent(id)
        try fm.createDirectory(atPath: (dir as NSString).appendingPathComponent("shots"), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: (dir as NSString).appendingPathComponent("export"), withIntermediateDirectories: true)

        for f in files {
            let rel = f.rel.replacingOccurrences(of: "\\", with: "/")
            guard Self.isImportableImagePath(rel) else {
                Log.store.error("SECURITY import rejected unexpected path rel=[\(rel, privacy: .private)]")
                throw StoreError.importPathRejected(rel)
            }
            // Defense-in-depth against zip-slip / symlinked components.
            guard let abs = confinePathNoSymlinks(dir: dir, rel: rel) else {
                Log.store.error("SECURITY import path-confinement refused rel=[\(rel, privacy: .private)]")
                throw StoreError.importPathRejected(rel)
            }
            try fm.createDirectory(atPath: (abs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            // .withoutOverwriting: a duplicate entry in the zip can never clobber
            // an already-extracted file (the dir is fresh, so this only guards the
            // hostile-duplicate case).
            try f.bytes.write(to: URL(fileURLWithPath: abs), options: .withoutOverwriting)
        }

        var out = manifest
        let now = ProjectJSON.isoNow()
        out.id = id
        out.createdWith = "shotAI"
        if out.createdAt.isEmpty { out.createdAt = now }
        out.updatedAt = now
        out.sopBackup = nil
        // An imported project is materialized live (files extracted), never archived.
        out.archived = false
        out.archivedAt = nil
        try writeManifest(out, at: dir)
        settings.addRecent(dir)
        Log.store.notice("createProjectFromImport: created project [id \(id, privacy: .public)] files=\(files.count, privacy: .public)")
        return summarize(out, at: dir)
    }

    /// The only two folders a package legitimately carries images in — a single
    /// path segment deep (no traversal, no nested dirs). Shared by the importer's
    /// pre-filter and this method's extraction guard.
    public static func isImportableImagePath(_ rel: String) -> Bool {
        func oneSegment(under folder: String) -> Bool {
            guard rel.hasPrefix(folder) else { return false }
            let tail = rel.dropFirst(folder.count)
            return !tail.isEmpty && !tail.contains("/")
        }
        return oneSegment(under: "shots/") || oneSegment(under: "export/.render/")
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

    // MARK: - Report authoring (text edits — no re-flatten)

    /// Edit a step's text fields (caption / note / heading / body / callout type).
    /// Only the non-nil arguments are written. These are rendered live in the
    /// report — NOT baked into the flattened PNG — so this deliberately does NOT
    /// touch `flattened` / `renderRev` (no re-flatten, no freshness bump).
    @discardableResult
    public func editStepText(
        at projectPath: String, stepId: String,
        caption: String? = nil, note: String? = nil,
        heading: String? = nil, body: String? = nil, callout: CalloutKind? = nil
    ) throws -> ProjectManifest {
        Log.store.info("editStepText [step \(stepId, privacy: .public)]")
        return try mutate(at: projectPath) { m in
            guard let i = m.steps.firstIndex(where: { $0.id == stepId }) else {
                throw StoreError.stepNotFound(stepId)
            }
            if let caption { m.steps[i].caption = caption }
            if let note { m.steps[i].note = note }
            if let heading { m.steps[i].heading = heading }
            if let body { m.steps[i].body = body }
            if let callout { m.steps[i].callout = callout }
        }
    }

    /// Convert a text step between plain text and a callout by setting (a kind) or
    /// clearing (nil) its `callout`. Unlike `editStepText`, nil here CLEARS the
    /// callout (→ plain text). Only text steps qualify — a shot step is left
    /// untouched. Renumbers afterward so the visible 1..N sequence updates
    /// (callouts are not numbered; see ReportPresentation.displayNumbers).
    @discardableResult
    public func setStepCallout(at projectPath: String, stepId: String, callout: CalloutKind?) throws -> ProjectManifest {
        Log.store.info("setStepCallout [step \(stepId, privacy: .public)] -> \(callout?.rawValue ?? "text", privacy: .public)")
        return try mutate(at: projectPath) { m in
            guard let i = m.steps.firstIndex(where: { $0.id == stepId }) else {
                throw StoreError.stepNotFound(stepId)
            }
            guard m.steps[i].kind == .text else { return }  // only text steps can be callouts
            m.steps[i].callout = callout
            ProjectStore.renumber(&m.steps)
        }
    }

    /// Set the SOP overview preamble (stored even when empty — the editor shows
    /// an empty, editable box; use `removeIntro` to clear it).
    @discardableResult
    public func setIntro(at projectPath: String, heading: String, body: String) throws -> ProjectManifest {
        Log.store.info("setIntro")
        return try mutate(at: projectPath) { $0.intro = SopIntro(heading: heading, body: body) }
    }

    /// Remove the SOP overview preamble entirely.
    @discardableResult
    public func removeIntro(at projectPath: String) throws -> ProjectManifest {
        Log.store.info("removeIntro")
        return try mutate(at: projectPath) { $0.intro = nil }
    }

    /// Add a text step (a plain heading/body block, or a note/caution/warning
    /// callout when `callout` is set) at `atIndex` (clamped; nil → append).
    @discardableResult
    public func addTextStep(
        at projectPath: String, atIndex: Int?,
        heading: String = "", body: String = "", callout: CalloutKind? = nil
    ) throws -> ProjectManifest {
        let step = ProjectStep(
            id: UUID().uuidString.lowercased(), order: 0, kind: .text,
            screenshot: "", trigger: .hotkey,
            heading: heading, body: body, callout: callout
        )
        Log.store.info("addTextStep [step \(step.id, privacy: .public)] callout=\(String(describing: callout), privacy: .public)")
        return try mutate(at: projectPath) { m in
            let i = atIndex.map { max(0, min($0, m.steps.count)) } ?? m.steps.count
            m.steps.insert(step, at: i)
            Self.renumber(&m.steps)
        }
    }

    /// Reorder the steps to match `orderedIds` (a permutation of the current step
    /// ids), then renumber. Ids not present are ignored; any current step missing
    /// from `orderedIds` is kept, appended in its original order (defensive — a
    /// reorder must never drop a step).
    @discardableResult
    public func reorderSteps(at projectPath: String, orderedIds: [String]) throws -> ProjectManifest {
        try mutate(at: projectPath) { m in
            let byId = Dictionary(m.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var reordered: [ProjectStep] = []
            var seen = Set<String>()
            for id in orderedIds where !seen.contains(id) {
                if let step = byId[id] { reordered.append(step); seen.insert(id) }
            }
            for step in m.steps where !seen.contains(step.id) { reordered.append(step) }
            m.steps = reordered
            Self.renumber(&m.steps)
            Log.store.notice("reorderSteps: \(reordered.count, privacy: .public) step(s) reordered")
        }
    }

    /// PNG / JPEG magic-byte sniff — returns the file extension, or nil if the
    /// bytes aren't a supported image (defense-in-depth against a mis-typed or
    /// hostile file, mirroring the Windows importStep validation).
    private static func imageExtension(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
        return nil
    }

    /// Import a user-supplied image as a new (screenshot-kind) step at `atIndex`
    /// (clamped; nil → append). The bytes MUST be a real PNG/JPEG (magic-byte
    /// checked); the file is written into shots/ symlink-confined to the project.
    @discardableResult
    public func importImageStep(at projectPath: String, atIndex: Int?, imageData: Data) throws -> ProjectManifest {
        guard let ext = Self.imageExtension(imageData) else { throw StoreError.notAnImage }
        let resolved = try resolveKnownProject(projectPath)
        let id = UUID().uuidString.lowercased()
        let rel = "shots/import-\(id).\(ext)"
        guard let abs = confinePathNoSymlinks(dir: resolved, rel: rel) else {
            Log.store.error("SECURITY path-confinement refused image import rel=[\(rel, privacy: .private)]")
            throw StoreError.renderPathNotConfined(id)
        }
        try fm.createDirectory(atPath: (abs as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try imageData.write(to: URL(fileURLWithPath: abs))
        let step = ProjectStep(id: id, order: 0, screenshot: rel, trigger: .hotkey)
        Log.store.notice("importImageStep [step \(id, privacy: .public)] kind=\(ext, privacy: .public) bytes=\(imageData.count, privacy: .public)")
        return try mutate(at: projectPath) { m in
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
                guard let abs = confinePathNoSymlinks(dir: resolved, rel: rel) else {
                    Log.store.error("SECURITY path-confinement refused step-file delete rel=[\(rel, privacy: .private)]")
                    continue
                }
                try? fm.removeItem(atPath: abs)
            }
        }
        Log.store.notice("deleteSteps: removed \(removed.count, privacy: .public) step(s)")
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
        Log.store.notice("updateStep [step \(stepId, privacy: .public)] freshRender=\(hasFresh, privacy: .public) renderRev=\(manifest.steps[idx].renderRev ?? 0, privacy: .public)")
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
        Log.store.notice("mergeSteps kept=[\(keepId, privacy: .public)] dropped=[\(dropId, privacy: .public)] freshRender=\(hasFresh, privacy: .public) renderRev=\(manifest.steps[keepIdx].renderRev ?? 0, privacy: .public)")
        manifest.steps.remove(at: dropIdx)
        Self.renumber(&manifest.steps)
        manifest.updatedAt = ProjectJSON.isoNow()
        try writeManifest(manifest, at: resolved)
        return manifest
    }

    /// Undo a merge: restore the kept step to its pre-merge state, re-insert the
    /// dropped step at `dropIndex`, and (if given) rewrite the kept step's render
    /// — atomically. The dropped step's screenshot file survived the merge (which
    /// only removed it from the manifest), so re-inserting it restores the image.
    @discardableResult
    public func restoreMerge(
        at projectPath: String, keptPre: ProjectStep, dropped: ProjectStep, dropIndex: Int, keptPng: Data?
    ) throws -> ProjectManifest {
        let resolved = try resolveKnownProject(projectPath)
        var manifest = try readManifest(at: resolved)
        guard let ki = manifest.steps.firstIndex(where: { $0.id == keptPre.id }) else {
            throw StoreError.stepNotFound(keptPre.id)
        }
        var kept = keptPre
        if let png = keptPng, !png.isEmpty {
            // The merge overwrote the kept step's render; rewrite its pre-merge one.
            try writeStepRender(resolved: resolved, step: &kept, id: kept.id, png: png)
        }
        manifest.steps[ki] = kept
        let i = max(0, min(dropIndex, manifest.steps.count))
        manifest.steps.insert(dropped, at: i)
        Self.renumber(&manifest.steps)
        manifest.updatedAt = ProjectJSON.isoNow()
        try writeManifest(manifest, at: resolved)
        Log.store.notice("restoreMerge: restored kept=[\(keptPre.id, privacy: .public)], re-inserted dropped=[\(dropped.id, privacy: .public)] at \(i, privacy: .public)")
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
        let before = settings.recents()
        let pruned = before.filter { lexicallyResolve(absolutize($0)) != resolved }
        settings.setRecents(pruned)
        Log.store.notice("deleteProject: removed project, pruned \(before.count - pruned.count, privacy: .public) recent(s)")
    }

    /// "Project yyyy/MM/dd HH:mm:ss" (local time) — same default as Windows.
    private static func defaultTitle() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return "Project \(f.string(from: Date()))"
    }
}
