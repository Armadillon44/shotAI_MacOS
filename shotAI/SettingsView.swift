import AppKit
import ShotModel
import SwiftUI

/// The app's Settings window (⌘, / shotAI ▸ Settings…). Native macOS Settings
/// scene. Permissions is the primary tab (it replaced the toolbar shield);
/// General shows version + the projects folder. AI / Appearance / Storage-editing
/// tabs land later as those features do.
struct SettingsView: View {
    var body: some View {
        TabView {
            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct PermissionsSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Capture permissions")
                .font(.title3.bold())
            Text("shotAI captures a screenshot of each step as you click. macOS requires your explicit permission for these.")
                .foregroundStyle(.secondary)

            PermissionStatusList()

            Text("If a toggle is already on but recording still fails, macOS may require relaunching the app after granting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Relaunch shotAI") { AppRelaunch.now() }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct GeneralSettings: View {
    // Reads the same UserDefaults-backed value the app's ProjectStore uses, so it
    // reflects the live projects folder without coupling to AppModel.
    private var projectsDir: String { UserDefaultsSettings().projectsDir() }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "s.square.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("shotAI for macOS").font(.title3.bold())
                    Text("Version \(appVersion)").foregroundStyle(.secondary).font(.callout)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Projects folder").font(.headline)
                Text(projectsDir)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: projectsDir)])
                    }
                    .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
