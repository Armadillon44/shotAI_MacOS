import Combine
import CaptureKit
import ExportKit
import ShotModel
import SwiftUI

/// The full-window Home surface, matching the shipped Windows app: a brand
/// header, a "Start a project" create hero (name + Capture / Empty + capture
/// mode + target), then the project list as violet cards, sortable and
/// date-grouped, each with Open + an overflow menu (rename / reveal / delete).
/// Replaces the old NavigationSplitView sidebar list.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    let capture: CaptureCoordinator
    /// Open a project into the detail view.
    let onOpen: (String) -> Void

    enum SortKey: String, CaseIterable { case name = "Name", created = "Created", modified = "Modified" }
    /// Active projects vs. the Archive shelf — mirrors the Windows 1.1.0 tabs.
    enum HomeTab: Hashable { case active, archive }

    // Create-hero state.
    @State private var title = ""
    @State private var mode: CaptureMode = .screen
    @State private var targets = CaptureTargets(windows: [], monitors: [])
    @State private var selectedWindow: CaptureKit.WindowInfo?
    @State private var selectedMonitor: MonitorInfo?
    @State private var selectedArea: ShotModel.Rect?
    @State private var busy = false

    // List state.
    @State private var tab: HomeTab = .active
    @State private var sortKey: SortKey = .modified
    @State private var sortAsc = false
    @State private var renamingPath: String?
    @State private var renameValue = ""
    @State private var deleteTarget: ProjectSummary?
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool

    // Bulk multi-select state. Checkboxes are always inline on each card (no
    // separate "select mode"); the bulk bar appears whenever something is picked.
    @State private var selection = Set<String>()
    @State private var bulkDeleteConfirm = false
    /// Path of the card the cursor is over, for the hover-lift.
    @State private var hoveredPath: String?

    // Keep the list fresh without a manual Refresh: re-list whenever Home
    // (re)appears — which also fixes opening an archived project (it auto-restores
    // on disk, so the row must move from Archive back to Projects) — plus on
    // window activation and a gentle periodic poll. The poll picks up changes made
    // outside the app (e.g. the Windows app editing the shared folder, or a cloud
    // sync landing). `@Environment(\.scenePhase)` so we only poll while frontmost.
    @Environment(\.scenePhase) private var scenePhase
    /// Honor Accessibility ▸ Reduce Motion — SwiftUI doesn't auto-suppress
    /// withAnimation/.animation/.transition, so every motion below is gated on this.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A stable timer held in @State so re-renders don't resubscribe (which would
    /// reset the countdown and it would never fire). Lives only while Home is on
    /// screen, so nothing polls while a project is open.
    @State private var pollTick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            bannerBar
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if tab == .active { hero }
                    tabsRow
                    listHead
                    // Progress takes precedence over the bulk bar, so ticking a
                    // card mid-export can't hide the "Exporting N of M…" feedback.
                    // The presence-keyed .animation gives the bar the same slide
                    // in/out the bulk bar gets (its own transition can't self-
                    // animate — the model mutations are bare assignments).
                    Group {
                        if let prog = model.bulkExportProgress {
                            bulkProgressBar(prog)
                        } else if !selection.isEmpty {
                            bulkBar
                        }
                    }
                    .animation(selectionAnim, value: model.bulkExportProgress != nil)
                    if tabProjects.isEmpty {
                        tab == .archive ? AnyView(archiveEmptyState) : AnyView(emptyState)
                    } else if filteredProjects.isEmpty {
                        noMatchesState
                    } else {
                        projectList
                    }
                }
                .padding(28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Palette.ground)
        // ⌘F focuses the project search field.
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // If a search change would filter out the row being renamed, SwiftUI
        // tears down its TextField without firing onSubmit/onExitCommand and the
        // edit is silently lost. Commit it first (same as clicking away from an
        // open rename), so narrowing the search never drops an in-progress name.
        .onChange(of: searchQuery) { _, _ in commitRenameIfEditing() }
        .confirmationDialog(
            deleteTarget.map { "Delete “\($0.title)”?" } ?? "",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let t = deleteTarget { Task { await model.deleteProject(path: t.path) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This removes the project folder and its screenshots. This can't be undone.")
        }
        .confirmationDialog(
            "Delete \(selection.count) project\(selection.count == 1 ? "" : "s")?",
            isPresented: $bulkDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete \(selection.count) Project\(selection.count == 1 ? "" : "s")", role: .destructive) {
                let paths = Array(selection)
                clearSelection()
                Task { await model.deleteProjects(paths: paths) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes each project's folder and screenshots. This can't be undone.")
        }
        // Re-list every time Home appears (covers return-from-project, so an
        // opened-then-auto-restored archive lands back under Projects).
        .task { await model.autoRefresh() }
        // Re-list when the app comes back to the foreground (e.g. after editing a
        // project in the Windows app on the shared folder).
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            autoRefreshUnlessBusy()
        }
        // Gentle periodic poll while Home is frontmost.
        .onReceive(pollTick) { _ in
            guard scenePhase == .active else { return }
            autoRefreshUnlessBusy()
        }
    }

    /// Background refresh, skipped while the user is mid-rename or has an active
    /// bulk selection so we never yank focus or reorder rows out from under them.
    private func autoRefreshUnlessBusy() {
        // If the row being renamed has vanished (e.g. it was bulk-deleted/archived
        // while its rename field was still open), its TextField tore down without
        // firing onSubmit/onExitCommand, stranding renamingPath. Reconcile it here
        // so a stale value can't starve the poll forever.
        if let rp = renamingPath, !tabProjects.contains(where: { $0.path == rp }) {
            renamingPath = nil
        }
        guard renamingPath == nil, selection.isEmpty else { return }
        Task { await model.autoRefresh() }
    }

    // MARK: - Header

    /// The Home banner — a real, full-width surface bar with a bottom hairline
    /// (restoring the Windows header chrome the port dropped). The content column
    /// is constrained to the same 760 width + 28 padding as the list beneath it,
    /// so logo and cards share a left edge; the bar itself spans the window.
    private var bannerBar: some View {
        HStack(spacing: 11) {
            Image("AppLogo")
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                (Text("shot").foregroundColor(Palette.ink)
                    + Text("AI").foregroundColor(Palette.accent))
                    .font(Typo.wordmark)
                    .kerning(-0.3)
                Text("Turn any process into a step-by-step guide")
                    .font(Typo.tagline)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 11)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Palette.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.hair).frame(height: 1)
        }
    }

    // MARK: - Create hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a project").font(Typo.heroTitle)
            Text("Record a process, mark it up, and let Claude turn it into a step-by-step guide you can export and share.")
                .font(.callout)
                .foregroundStyle(Palette.ink2)

            HStack(spacing: 8) {
                TextField("Name (optional — defaults to a timestamp)", text: $title)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(Palette.field)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.controlBd))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onSubmit { if canStart { startCapture() } }
                Button { startCapture() } label: {
                    Label("Capture", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart || busy || capture.state.status != .idle)
                .tourAnchor(.capture)
                Button("Empty project") { createEmpty() }
                    .disabled(busy || capture.state.status != .idle)
            }

            modeRow
            targetPicker
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface2)
        // Elevated above the flat list so it reads as the primary "start here":
        // soft shadow + a low-opacity accent border instead of a plain hairline.
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.accent.opacity(0.40)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cardElevation()
        .tourAnchor(.hero)
    }

    private var modeRow: some View {
        HStack(spacing: 8) {
            Text("MODE")
                .font(.system(size: 11, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Palette.ink3)
            ForEach([CaptureMode.screen, .auto, .window, .area], id: \.self) { m in
                Button { mode = m } label: { Text(label(for: m)) }
                    .buttonStyle(ChipStyle(on: mode == m, reduceMotion: reduceMotion))
            }
            if mode == .auto {
                Text("⚠ Auto is best-effort")
                    .font(.caption)
                    .foregroundStyle(Palette.draftInk)
                    .help("Auto guesses per click and may capture extra context. Pick Screen, Window, or Area for predictable results.")
            }
            Spacer()
        }
        .tourAnchor(.mode)
    }

    @ViewBuilder private var targetPicker: some View {
        switch mode {
        case .auto:
            EmptyView()
        case .screen:
            Picker("Display", selection: Binding<Int?>(
                get: { selectedMonitor?.id },
                set: { id in selectedMonitor = targets.monitors.first { $0.id == id } }
            )) {
                Text("Choose a display…").tag(Int?.none)
                ForEach(targets.monitors, id: \.id) { mon in
                    Text("\(mon.name) — \(mon.width)×\(mon.height)\(mon.isPrimary ? " (primary)" : "")")
                        .tag(Int?.some(mon.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 340, alignment: .leading)
            .task(id: mode) { await loadTargets() }
        case .window:
            Picker("Window", selection: Binding<Int?>(
                get: { selectedWindow?.id },
                set: { id in selectedWindow = targets.windows.first { $0.id == id } }
            )) {
                Text(targets.windows.isEmpty ? "No windows (grant Screen Recording)" : "Choose a window…")
                    .tag(Int?.none)
                ForEach(targets.windows, id: \.id) { w in
                    Text("\(w.app) — \(w.title)").lineLimit(1).tag(Int?.some(w.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 340, alignment: .leading)
            .task(id: mode) { await loadTargets() }
        case .area:
            HStack(spacing: 10) {
                Button(selectedArea == nil ? "Select area…" : "Reselect area…") {
                    Task { selectedArea = await capture.selectArea() ?? selectedArea }
                }
                if let a = selectedArea {
                    Text("\(Int(a.width)) × \(Int(a.height))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Palette.ink2)
                }
            }
        }
    }

    // MARK: - Tabs (Projects / Archive)

    /// Whether archive/restore is allowed right now — blocked while a capture
    /// session is live so we never repack a project mid-recording.
    private var canArchive: Bool { capture.state.status == .idle }

    private var tabsRow: some View {
        HStack(spacing: 8) {
            ForEach([HomeTab.active, .archive], id: \.self) { t in
                Button {
                    guard tab != t else { return }
                    commitRenameIfEditing()
                    clearSelection()  // scoped to one tab; animate the bar out
                    tab = t
                } label: {
                    Text(t == .active ? "Projects \(activeCount)" : "Archive \(archiveCount)")
                }
                .buttonStyle(ChipStyle(on: tab == t, reduceMotion: reduceMotion))
            }
            Spacer()
        }
    }

    // MARK: - List head (title + sort)

    private var listHead: some View {
        HStack(spacing: 10) {
            Text(tab == .archive ? "Archived" : "Projects").font(.system(size: 15, weight: .semibold))
                + Text(countSuffix).foregroundColor(Palette.ink3)
            searchField
            Spacer()
            Text("Sort").font(.caption).foregroundStyle(Palette.ink3)
            ForEach(SortKey.allCases, id: \.self) { key in
                Button { sortKey = key } label: { Text(key.rawValue) }
                    .buttonStyle(ChipStyle(on: sortKey == key, reduceMotion: reduceMotion))
            }
            Button {
                sortAsc.toggle()
            } label: {
                Image(systemName: sortAsc ? "arrow.up" : "arrow.down")
            }
            .help(sortAsc ? "Ascending" : "Descending")
        }
    }

    /// Compact, capsule-style search field matching the chip aesthetic. Filters
    /// the list by project name (case- and diacritic-insensitive).
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink3)
            TextField("Search", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .frame(width: 130)
                .onExitCommand { searchQuery = ""; searchFocused = false }
            if !searchQuery.isEmpty {
                Button { searchQuery = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink3)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Palette.surface)
        .overlay(Capsule().stroke(searchFocused ? Palette.accent : Palette.controlBd))
        .clipShape(Capsule())
        .help("Search project names and step content (⌘F)")
    }

    /// Blank normally (the tab chips carry the totals); "· 3 of 12" while a
    /// search is narrowing the current tab.
    private var countSuffix: String {
        guard isSearching else { return "" }
        let total = tabProjects.count
        let shown = filteredProjects.count
        return shown != total ? "  ·  \(shown) of \(total)" : "  ·  \(total)"
    }

    /// Totals per tab, over the full list (never narrowed by search) — shown on
    /// the tab chips so a search on one tab doesn't change the other's count.
    private var activeCount: Int { model.projects.filter { !$0.archived }.count }
    private var archiveCount: Int { model.projects.filter { $0.archived }.count }

    // MARK: - Bulk selection bar

    /// The action bar shown whenever ≥1 project is checked: count, select-all /
    /// clear, and tab-appropriate bulk actions (Archive/Restore, Export, Delete).
    private var bulkBar: some View {
        let count = selection.count
        return HStack(spacing: 10) {
            Text("\(count) selected").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            Button("Select all") { selectAllVisible() }
                .buttonStyle(.link)
                .disabled(filteredProjects.isEmpty || allVisibleSelected)
            Button("Clear") { clearSelection() }
                .buttonStyle(.link)
                .keyboardShortcut(.cancelAction)  // Esc deselects
            Spacer()
            if tab == .active {
                // Snapshot the paths, then clear the selection immediately (so the
                // poller can resume) and run the op on the captured copy — the op
                // owns its own final refresh(); it never reads the live selection.
                Button {
                    let paths = Array(selection); clearSelection()
                    Task { await model.archiveProjects(paths: paths) }
                } label: { Label("Archive", systemImage: "archivebox") }
                    .disabled(!canArchive)
                    .help(canArchive ? "Archive the selected projects" : "Can't archive while recording")
                bulkExportMenu(count: count)
            } else {
                Button {
                    let paths = Array(selection); clearSelection()
                    Task { await model.unarchiveProjects(paths: paths) }
                } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            }
            Button(role: .destructive) { bulkDeleteConfirm = true } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cardElevation()
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Shown in the bulk bar's slot while a bulk export runs (the selection is
    /// cleared the instant export starts, so the bar itself is already gone).
    /// Gives the "there should be a progress indicator until they're all done"
    /// feedback, then Finder surfaces the destination on completion.
    private func bulkProgressBar(_ p: AppModel.BulkExportProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView(value: Double(p.current), total: Double(max(p.total, 1)))
                .progressViewStyle(.linear)
                .frame(width: 150)
            Text("Exporting \(p.current) of \(p.total)…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cardElevation()
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: p.current)
    }

    /// Bulk export as a pull-down (same document formats as the per-row menu).
    /// Only offered on the Active tab — exporting an archived project would
    /// auto-restore it, which the Archive tab shouldn't do as a side effect.
    private func bulkExportMenu(count: Int) -> some View {
        Menu {
            Button("HTML Document") { runBulkExport(.html) }
            Button("PDF") { runBulkExport(.pdf) }
            Button("Markdown") { runBulkExport(.markdown) }
            Divider()
            Button("HTML for Word / Google Docs") { runBulkExport(.htmlPlain) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .fixedSize()
        .disabled(count == 0 || model.exporting)
    }

    private func runBulkExport(_ format: ExportFormat) {
        // Snapshot the paths but KEEP the checkboxes visible through the
        // destination chooser — clearing up front made the ticks vanish under the
        // dialog, reading as an accidental deselect. onConfirmed clears them the
        // moment writing begins (never on cancel, so cancel leaves them selected).
        let paths = Array(selection)
        Task { await model.exportProjects(paths: paths, format: format) { clearSelection() } }
    }

    /// True when every currently-visible (tab + search) project is selected.
    private var allVisibleSelected: Bool {
        !filteredProjects.isEmpty && filteredProjects.allSatisfy { selection.contains($0.path) }
    }

    /// Spring used for selection changes so the bulk bar slides in/out and the
    /// count rolls, instead of teleporting.
    private static let selectAnim = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// The selection spring, or no animation under Reduce Motion.
    private var selectionAnim: Animation? { reduceMotion ? nil : Self.selectAnim }

    private func toggle(_ p: ProjectSummary) {
        withAnimation(selectionAnim) {
            if selection.contains(p.path) { selection.remove(p.path) } else { selection.insert(p.path) }
        }
    }

    private func selectAllVisible() {
        withAnimation(selectionAnim) { selection = Set(filteredProjects.map(\.path)) }
    }

    /// Clear the selection (hides the bulk bar).
    private func clearSelection() {
        withAnimation(selectionAnim) { selection.removeAll() }
    }

    // MARK: - Project list

    private var projectList: some View {
        let groups = groupedProjects
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.label) { group in
                VStack(alignment: .leading, spacing: 8) {
                    if !group.label.isEmpty {
                        Text(group.label.uppercased())
                            .font(Typo.eyebrow)
                            .kerning(0.6)
                            .foregroundStyle(Palette.ink3)
                    }
                    ForEach(group.items, id: \.path) { card($0) }
                }
            }
        }
        // Animate only user-driven re-layout (sort / direction / tab / search).
        // Deliberately NOT keyed on model.projects, so the 20s background poll
        // never animates rows out from under the user.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: listAnimToken)
        // A card that scrolls/filters out of view and back can otherwise re-appear
        // "hovered" (the pointer never left it). Reset on any list re-layout.
        .onChange(of: listAnimToken) { _, _ in hoveredPath = nil }
    }

    /// Composite of the user-driven list controls — the sole trigger for list
    /// animation (see projectList).
    private var listAnimToken: String {
        "\(tab)|\(sortKey.rawValue)|\(sortAsc)|\(trimmedQuery)"
    }

    private func card(_ p: ProjectSummary) -> some View {
        let isSelected = selection.contains(p.path)
        let isHover = hoveredPath == p.path
        return HStack(spacing: 12) {
            Button { toggle(p) } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    // Muted at rest so the title wins the glance; full accent when checked.
                    .font(.system(size: isSelected ? 18 : 16))
                    .foregroundStyle(isSelected ? Palette.accent : Palette.ink3.opacity(0.55))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isSelected)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Deselect" : "Select")
            .accessibilityLabel(isSelected ? "Selected" : "Not selected")
            VStack(alignment: .leading, spacing: 3) {
                if renamingPath == p.path {
                    TextField("Name", text: $renameValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onSubmit { commitRename(p) }
                        .onExitCommand { renamingPath = nil }
                } else {
                    HStack(spacing: 8) {
                        Text(p.title).font(Typo.cardTitle).lineLimit(1)
                        StatusBadge(hasSop: p.hasSop)
                    }
                }
                Text("\(p.stepCount) step\(p.stepCount == 1 ? "" : "s")\(Self.metaDate(p.updatedAt).map { " · \(p.archived ? "archived" : "modified") \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(Palette.ink3)
            }
            Spacer(minLength: 8)
            Button("Open") { onOpen(p.path) }
                .buttonStyle(.borderedProminent)
                .help(p.archived ? "Restores this project from the Archive and opens it" : "Open this project")
            Menu {
                Button("Rename") { startRename(p) }
                Button("Reveal in Finder") { model.revealInFinder(path: p.path) }
                exportMenu(p)
                Divider()
                archiveMenuItem(p)
                Button("Delete", role: .destructive) { deleteTarget = p }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .help("More actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(isSelected ? Palette.accentTint : Palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(
            isSelected ? Palette.accent : (isHover ? Palette.accent.opacity(0.45) : Palette.hair)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .cardElevation(hover: isHover && !isSelected)
        .offset(y: isHover && !isSelected ? -1 : 0)
        .onHover { over in hoveredPath = over ? p.path : (hoveredPath == p.path ? nil : hoveredPath) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.13), value: isHover)
        .contextMenu {
            Button(isSelected ? "Deselect" : "Select") { toggle(p) }
            Divider()
            Button("Open") { onOpen(p.path) }
            Button("Rename") { startRename(p) }
            Button("Reveal in Finder") { model.revealInFinder(path: p.path) }
            exportMenu(p)
            Divider()
            archiveMenuItem(p)
            Button("Delete", role: .destructive) { deleteTarget = p }
        }
    }

    /// Archive (when live) or Restore (when archived) — shared by the ⋯ menu and
    /// the right-click menu. Archiving is blocked while a capture session runs.
    @ViewBuilder
    private func archiveMenuItem(_ p: ProjectSummary) -> some View {
        if p.archived {
            Button("Restore") { Task { await model.unarchiveProject(path: p.path) } }
        } else {
            Button("Archive") { Task { await model.archiveProject(path: p.path) } }
                .disabled(!canArchive)
        }
    }

    /// Export submenu for a project card (⋯ + right-click). Exports by path, so it
    /// works without opening the project first; disabled while an export runs.
    @ViewBuilder
    private func exportMenu(_ p: ProjectSummary) -> some View {
        Menu("Export") {
            Button("HTML Document") { Task { await model.export(projectPath: p.path, format: .html) } }
            Button("PDF") { Task { await model.export(projectPath: p.path, format: .pdf) } }
            Button("Markdown") { Task { await model.export(projectPath: p.path, format: .markdown) } }
            Divider()
            Button("HTML for Word / Google Docs") { Task { await model.export(projectPath: p.path, format: .htmlPlain) } }
            Divider()
            Menu("shotAI Package (.zip)") {
                Button("Safe — redactions permanent") {
                    model.confirmAndExportPackage(projectPath: p.path, includeOriginals: false)
                }
                Button("Full — includes editable originals…") {
                    model.confirmAndExportPackage(projectPath: p.path, includeOriginals: true)
                }
            }
        }
        .disabled(model.exporting)
    }

    /// The brand mark in a soft accent halo — first-run's warm welcome.
    private var logoHalo: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .frame(width: 50, height: 50)
            .padding(14)
            .background(Circle().fill(Palette.accentTint))
            .accessibilityHidden(true)
    }

    /// An SF Symbol in the same accent halo — for state-specific empties.
    private func iconHalo(_ system: String) -> some View {
        Image(systemName: system)
            .font(.system(size: 29))
            .foregroundStyle(Palette.accent)
            .frame(width: 78, height: 78)
            .background(Circle().fill(Palette.accentTint))
            .accessibilityHidden(true)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            logoHalo
            Text("No projects yet").font(Typo.sectionTitle)
            Text("Create one above — press Capture to record a process, or Empty project to build one from images and text.")
                .font(.callout)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    /// Shown on the Archive tab when nothing has been archived yet.
    private var archiveEmptyState: some View {
        VStack(spacing: 12) {
            iconHalo("archivebox")
            Text("No archived projects").font(Typo.sectionTitle)
            Text("Archiving compresses a project's screenshots in place to save disk. Use a project's ⋯ menu to Archive it — it restores automatically when you open it.")
                .font(.callout)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    /// Shown when a search matches none of the (non-empty) project list.
    private var noMatchesState: some View {
        VStack(spacing: 12) {
            iconHalo("magnifyingglass")
            Text("No projects match “\(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines))”")
                .font(Typo.sectionTitle)
                .multilineTextAlignment(.center)
            Button("Clear search") { searchQuery = "" }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: - Search / sorting / grouping

    /// The trimmed query, or "" when the field is blank/whitespace.
    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool { !trimmedQuery.isEmpty }

    /// The full list scoped to the selected tab (Active vs. Archive), before any
    /// search. Tabs partition on the project's `archived` flag.
    private var tabProjects: [ProjectSummary] {
        model.projects.filter { tab == .archive ? $0.archived : !$0.archived }
    }

    /// The current tab narrowed by the search query. Matches the project's full
    /// text index (title + SOP intro + every step's caption/heading/body), so
    /// searching finds content *inside* projects, not just names — parity with
    /// the Windows app. Case- and diacritic-insensitive (`localizedStandardContains`).
    /// Sorting and date grouping both build on this, so search composes with them.
    private var filteredProjects: [ProjectSummary] {
        guard isSearching else { return tabProjects }
        let q = trimmedQuery
        return tabProjects.filter { $0.searchText.localizedStandardContains(q) }
    }

    private var sortedProjects: [ProjectSummary] {
        filteredProjects.sorted { a, b in
            let asc: Bool
            switch sortKey {
            case .name: asc = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .created: asc = a.createdAt < b.createdAt
            case .modified: asc = a.updatedAt < b.updatedAt
            }
            return sortAsc ? asc : !asc
        }
    }

    /// Date grouping applies only to the date sorts; Name stays a flat list.
    private var groupedProjects: [(label: String, items: [ProjectSummary])] {
        guard sortKey != .name else { return [("", sortedProjects)] }
        let grouped = DateGroups.group(sortedProjects, now: Date()) {
            Self.isoDate(sortKey == .created ? $0.createdAt : $0.updatedAt)
        }
        return grouped.map { (label: $0.label.rawValue, items: $0.items) }
    }

    // MARK: - Actions

    private var canStart: Bool {
        switch mode {
        case .auto: true
        case .window: selectedWindow != nil
        case .screen: selectedMonitor != nil
        case .area: selectedArea != nil
        }
    }

    private func loadTargets() async {
        targets = await capture.listTargets()
        if selectedMonitor == nil { selectedMonitor = targets.monitors.first { $0.isPrimary } ?? targets.monitors.first }
    }

    private func startCapture() {
        var target = CaptureTarget(mode: mode)
        switch mode {
        case .window:
            guard let w = selectedWindow else { return }
            target.window = .init(id: w.id, pid: w.pid, title: w.title)
        case .screen: target.monitorId = selectedMonitor?.id
        case .area: target.area = selectedArea
        case .auto: break
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            guard let path = await model.createAndSelectProject(title: name.isEmpty ? nil : name) else {
                busy = false
                return
            }
            _ = await capture.record(projectPath: path, target: target, createdThisSession: true)
            busy = false
            title = ""
        }
    }

    private func createEmpty() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        Task {
            await model.createAndSelectProject(title: name.isEmpty ? nil : name)
            busy = false
            title = ""
        }
    }

    private func startRename(_ p: ProjectSummary) {
        renameValue = p.title
        renamingPath = p.path
    }

    private func commitRename(_ p: ProjectSummary) {
        let next = renameValue
        renamingPath = nil
        Task { await model.renameProject(path: p.path, to: next) }
    }

    /// Commit an in-progress inline rename (if any) by its stored path, so the
    /// edit survives the row being torn down (e.g. filtered out by a search
    /// change). No-op when nothing is being renamed.
    private func commitRenameIfEditing() {
        guard let path = renamingPath else { return }
        let next = renameValue
        renamingPath = nil
        Task { await model.renameProject(path: path, to: next) }
    }

    private func label(for m: CaptureMode) -> String {
        switch m {
        case .auto: "Auto"
        case .screen: "Screen"
        case .window: "Window"
        case .area: "Area"
        }
    }

    /// "Jul 8, 2026" from an ISO timestamp; nil for blanks/unparseable.
    static func metaDate(_ iso: String) -> String? { ContentView.formatDate(iso) }

    private static func isoDate(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }
}

/// A selectable violet chip (capture mode / sort key), matching the Windows
/// `capmode__chip` / `project__sort-chip`.
private struct ChipStyle: ButtonStyle {
    let on: Bool
    var reduceMotion = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: on ? .semibold : .regular))
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .foregroundStyle(on ? Palette.accentInk : Palette.ink2)
            .background(on ? Palette.accentTint : Palette.surface)
            .overlay(Capsule().stroke(on ? Palette.accent : Palette.controlBd))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            // Cross-fade the selected tint and give a springy press instead of snapping.
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: on)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// The green "SOP ready" / amber "Draft" status pill. On a genuine flip to
/// SOP-ready its colors and label cross-fade — a gentle reward. (Deliberately no
/// identity-swap scale-pop: that also fired on every search/sort/tab re-insertion,
/// which read as noise while typing in the search field.)
private struct StatusBadge: View {
    let hasSop: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Text(hasSop ? "SOP ready" : "Draft")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(hasSop ? Palette.okInk : Palette.draftInk)
            .background(hasSop ? Palette.okTint : Palette.draftTint)
            .clipShape(Capsule())
            .contentTransition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: hasSop)
            .help(hasSop ? "Claude has written this guide" : "No SOP generated yet")
    }
}
