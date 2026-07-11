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

    // Create-hero state.
    @State private var title = ""
    @State private var mode: CaptureMode = .screen
    @State private var targets = CaptureTargets(windows: [], monitors: [])
    @State private var selectedWindow: CaptureKit.WindowInfo?
    @State private var selectedMonitor: MonitorInfo?
    @State private var selectedArea: ShotModel.Rect?
    @State private var busy = false

    // List state.
    @State private var sortKey: SortKey = .modified
    @State private var sortAsc = false
    @State private var renamingPath: String?
    @State private var renameValue = ""
    @State private var deleteTarget: ProjectSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brandHeader
                hero
                listHead
                if model.projects.isEmpty {
                    emptyState
                } else {
                    projectList
                }
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.ground)
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
    }

    // MARK: - Header

    private var brandHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.accent)
                .frame(width: 30, height: 30)
                .overlay(Text("s").font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.onAccent))
            Text("shotAI").font(.system(size: 17, weight: .semibold))
            Spacer()
        }
    }

    // MARK: - Create hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start a project").font(.system(size: 18, weight: .bold))
            Text("Record a process, mark it up, and let Claude turn it into a step-by-step guide you can export and share.")
                .font(.callout)
                .foregroundStyle(Palette.ink2)

            HStack(spacing: 8) {
                TextField("Name (optional — defaults to a timestamp)", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if canStart { startCapture() } }
                Button { startCapture() } label: {
                    Label("Capture", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart || busy || capture.state.status != .idle)
                Button("Empty project") { createEmpty() }
                    .disabled(busy || capture.state.status != .idle)
            }

            modeRow
            targetPicker
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface2)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var modeRow: some View {
        HStack(spacing: 8) {
            Text("MODE")
                .font(.system(size: 11, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Palette.ink3)
            ForEach([CaptureMode.auto, .screen, .window, .area], id: \.self) { m in
                Button { mode = m } label: { Text(label(for: m)) }
                    .buttonStyle(ChipStyle(on: mode == m))
            }
            if mode == .auto {
                Text("⚠ Auto is best-effort")
                    .font(.caption)
                    .foregroundStyle(Palette.draftInk)
                    .help("Auto guesses per click and may capture extra context. Pick Screen, Window, or Area for predictable results.")
            }
            Spacer()
        }
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

    // MARK: - List head (title + sort)

    private var listHead: some View {
        HStack {
            Text("Projects").font(.system(size: 15, weight: .semibold))
                + Text("  ·  \(model.projects.count)").foregroundColor(Palette.ink3)
            Spacer()
            Text("Sort").font(.caption).foregroundStyle(Palette.ink3)
            ForEach(SortKey.allCases, id: \.self) { key in
                Button { sortKey = key } label: { Text(key.rawValue) }
                    .buttonStyle(ChipStyle(on: sortKey == key))
            }
            Button {
                sortAsc.toggle()
            } label: {
                Image(systemName: sortAsc ? "arrow.up" : "arrow.down")
            }
            .help(sortAsc ? "Ascending" : "Descending")
        }
    }

    // MARK: - Project list

    private var projectList: some View {
        let groups = groupedProjects
        return VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.label) { group in
                VStack(alignment: .leading, spacing: 8) {
                    if !group.label.isEmpty {
                        Text(group.label.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .kerning(0.6)
                            .foregroundStyle(Palette.ink3)
                    }
                    ForEach(group.items, id: \.path) { card($0) }
                }
            }
        }
    }

    private func card(_ p: ProjectSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if renamingPath == p.path {
                    TextField("Name", text: $renameValue)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                        .onSubmit { commitRename(p) }
                        .onExitCommand { renamingPath = nil }
                } else {
                    HStack(spacing: 8) {
                        Text(p.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        StatusBadge(hasSop: p.hasSop)
                    }
                }
                Text("\(p.stepCount) step\(p.stepCount == 1 ? "" : "s")\(Self.metaDate(p.updatedAt).map { " · modified \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 8)
            Button("Open") { onOpen(p.path) }
                .buttonStyle(.borderedProminent)
            Menu {
                Button("Rename") { startRename(p) }
                Button("Reveal in Finder") { model.revealInFinder(path: p.path) }
                exportMenu(p)
                Divider()
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
        .background(Palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button("Open") { onOpen(p.path) }
            Button("Rename") { startRename(p) }
            Button("Reveal in Finder") { model.revealInFinder(path: p.path) }
            exportMenu(p)
            Divider()
            Button("Delete", role: .destructive) { deleteTarget = p }
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 34))
                .foregroundStyle(Palette.ink3)
            Text("No projects yet").font(.system(size: 15, weight: .semibold))
            Text("Create one above — press Capture to record a process, or Empty project to build one from images and text.")
                .font(.callout)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Sorting / grouping

    private var sortedProjects: [ProjectSummary] {
        model.projects.sorted { a, b in
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
    }
}

/// The green "SOP ready" / amber "Draft" status pill.
private struct StatusBadge: View {
    let hasSop: Bool
    var body: some View {
        Text(hasSop ? "SOP ready" : "Draft")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(hasSop ? Palette.okInk : Palette.draftInk)
            .background(hasSop ? Palette.okTint : Palette.draftTint)
            .clipShape(Capsule())
            .help(hasSop ? "Claude has written this guide" : "No SOP generated yet")
    }
}
