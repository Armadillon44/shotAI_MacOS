import AppKit
import ShotModel
import SOPKit
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
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 460)
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

private struct AISettings: View {
    @Environment(AppModel.self) private var model
    @State private var keyInput = ""
    @State private var keyMessage: String?
    @State private var testing = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Enable AI SOP generation", isOn: $model.sopSettings.enabled)
                Text("Let Claude turn a project's screenshots into a polished step-by-step SOP. When off, no AI UI is shown and nothing is sent over the network.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Anthropic API key") {
                if model.apiKeyPresent {
                    LabeledContent("Status") {
                        Text(model.apiKeySource == .env ? "Set via ANTHROPIC_API_KEY" : "Saved in Keychain")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Test key") {
                            testing = true
                            Task { keyMessage = await model.testApiKey(); testing = false }
                        }
                        .disabled(testing || !model.sopSettings.enabled)
                        if model.apiKeySource != .env {
                            Button("Clear key", role: .destructive) {
                                keyMessage = model.clearApiKey() ?? "Key cleared."
                            }
                        }
                        if testing { ProgressView().controlSize(.small) }
                    }
                }
                HStack {
                    SecureField("sk-ant-…", text: $keyInput)
                    Button("Save") {
                        keyMessage = model.setApiKey(keyInput) ?? "Key saved."
                        keyInput = ""
                    }
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let keyMessage {
                    Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("Stored in your macOS Keychain — never shown again, never logged, and sent only to api.anthropic.com.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Generation") {
                Picker("Model", selection: $model.sopSettings.model) {
                    ForEach(SOP_MODELS, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Tone", selection: $model.sopSettings.tone) {
                    ForEach(SOP_TONES, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Effort", selection: $model.sopSettings.effort) {
                    ForEach(SOP_EFFORTS, id: \.id) { Text($0.label).tag($0.id) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom instructions (optional)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.sopSettings.customInstructions)
                        .font(.callout)
                        .frame(minHeight: 60, maxHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    Text("\(model.sopSettings.customInstructions.count)/\(SOP_CUSTOM_INSTRUCTIONS_MAX)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .disabled(!model.sopSettings.enabled)
        }
        .formStyle(.grouped)
        .onChange(of: model.sopSettings) {
            // Cap custom instructions, then persist any change.
            if model.sopSettings.customInstructions.count > SOP_CUSTOM_INSTRUCTIONS_MAX {
                model.sopSettings.customInstructions = String(model.sopSettings.customInstructions.prefix(SOP_CUSTOM_INSTRUCTIONS_MAX))
            }
            model.saveSopSettings()
        }
        .onAppear { model.refreshApiKeyStatus() }
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
