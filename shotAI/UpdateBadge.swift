import SwiftUI
import UpdateKit

/// The "Update available" pill in the Home banner bar.
///
/// Intentionally the quietest thing that still gets noticed: an inline capsule in
/// space that was already empty. No modal, no dock badge, no notification, no
/// sound, and it never appears over a report or during a recording. Clicking it
/// opens the release page in the browser — shotAI downloads nothing itself.
struct UpdateBadge: View {
    @Environment(AppModel.self) private var model
    let release: ReleaseInfo

    @State private var hovering = false
    @State private var showingDetails = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showingDetails = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Update to \(release.version.description)")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Palette.accentInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Palette.accentTint, in: Capsule())
                .overlay(Capsule().stroke(Palette.accent.opacity(hovering ? 0.55 : 0.28)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("shotAI \(release.version.description) is available. Click for the release notes and download.")

            Button {
                model.updates.badgeDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Palette.ink3)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide until the next launch")
            .accessibilityLabel("Dismiss update notice")
        }
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            UpdateDetailsPopover(release: release, dismiss: { showingDetails = false })
        }
    }
}

/// Release notes + the two actions. Kept to a popover so it can't block the app.
private struct UpdateDetailsPopover: View {
    @Environment(AppModel.self) private var model
    let release: ReleaseInfo
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(release.name).font(.headline)
                if let summary = release.assetSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }

            if release.notes.isEmpty {
                Text("No release notes were published for this version.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    // Release notes are markdown authored by us in the GitHub
                    // release. Rendered as plain selectable text rather than
                    // parsed markup — it's remote content, and the notes are
                    // short bullet lists that read fine as-is.
                    Text(release.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }

            Divider()

            Text("shotAI doesn't install updates itself — this opens the release page in your browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Skip This Version") {
                    Task { await model.updates.skipPending() }
                    dismiss()
                }
                .controlSize(.small)
                Spacer()
                Button("Later") { dismiss() }
                    .controlSize(.small)
                Button("Download…") {
                    model.updates.openReleasePage()
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }
}
