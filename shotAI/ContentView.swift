import ShotModel
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showOpenPanel = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.projects, id: \.path, selection: $model.selectedPath) { project in
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(project.stepCount) step\(project.stepCount == 1 ? "" : "s")\(Self.formatDate(project.updatedAt).map { " · \($0)" } ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(project.path)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .overlay {
                if model.projects.isEmpty {
                    ContentUnavailableView(
                        "No projects",
                        systemImage: "folder",
                        description: Text("Projects in \(model.projectsDirDisplay) appear here. Use Open Project… to browse elsewhere.")
                    )
                }
            }
        } detail: {
            if let opened = model.opened {
                ReportView(opened: opened)
                    .id(opened.dir)
            } else if let error = model.errorMessage {
                ContentUnavailableView("Could not open project", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("Select a project", systemImage: "doc.text.image", description: Text("Pick a project from the list to view its report."))
            }
        }
        .navigationTitle(model.opened?.manifest.title ?? "shotAI")
        .toolbar {
            ToolbarItem {
                Button("Open Project…", systemImage: "folder.badge.plus") {
                    showOpenPanel = true
                }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
            }
        }
        .fileImporter(isPresented: $showOpenPanel, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await model.openUserPicked(url) }
            }
        }
        .task { await model.refresh() }
        .onChange(of: model.selectedPath) {
            Task { await model.openSelected() }
        }
    }

    /// "Jul 1, 2026" from the manifest's ISO timestamp; nil for legacy blanks.
    static func formatDate(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
