import AppKit
import CaptureKit
import ShotModel
import SOPKit
import SwiftUI

/// The app's Settings window (⌘, / shotAI ▸ Settings…). Native macOS Settings
/// scene. Permissions is macOS-specific (TCC grants); AI / Appearance / Capture /
/// General mirror the Windows settings surface.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettings()
                .tabItem { Label("AI", systemImage: "sparkles") }
            CaptureSettings()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            PermissionsSettings()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 480)
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

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Theme") {
                Picker("Theme", selection: $model.preferences.theme) {
                    ForEach(ThemePref.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(model.preferences.theme.blurb)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Your name") {
                TextField("Name", text: $model.preferences.userName, prompt: Text("e.g. Jane Doe"))
                Toggle("Include my name in exported documents", isOn: $model.preferences.includeNameInReports)
                    .disabled(model.preferences.userName.trimmingCharacters(in: .whitespaces).isEmpty)
                Text("When on, exports show \u{201C}Created on … by <name>\u{201D} in the footer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.preferences) { model.savePreferences() }
    }
}

private struct CaptureSettings: View {
    @Environment(AppModel.self) private var model

    private var qualityPercent: Int { Int((model.preferences.captureScale * 100).rounded()) }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Screenshot quality") {
                Slider(
                    value: $model.preferences.captureScale,
                    in: Double(CaptureConstants.captureScaleMin)...Double(CaptureConstants.captureScaleMax),
                    step: 0.05
                ) {
                    Text("Quality")
                } minimumValueLabel: {
                    Text("Smaller")
                } maximumValueLabel: {
                    Text("Sharper")
                }
                LabeledContent("Scale", value: "\(qualityPercent)%")
                Text("Each captured screenshot is downscaled to this factor. Lower = smaller files and cheaper AI, but softer text. Applies to new captures.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("While recording") {
                Toggle("Keep the shotAI window visible during capture", isOn: $model.preferences.captureNoHide)
                Text("Off (default) hides the window so it isn't in the shot. Turn on if you need to see shotAI while you record.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.preferences) { model.savePreferences() }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    // Local mirror so the label updates immediately after Change… — reading
    // model.settings.projectsDir() directly registers no observation dependency
    // (settings is a `let`, and it reads UserDefaults), so the view wouldn't
    // otherwise re-evaluate.
    @State private var projectsDir = ""

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
                    Button("Change…") { chooseProjectsFolder(current: projectsDir) }
                        .controlSize(.small)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: projectsDir)])
                    }
                    .controlSize(.small)
                }
                Text("Projects are stored here (the same default as the Windows app: ~/shotAI Projects). Changing this re-lists from the new location; existing projects aren't moved.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { projectsDir = model.settings.projectsDir() }
    }

    private func chooseProjectsFolder(current: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder to store shotAI projects."
        panel.directoryURL = URL(fileURLWithPath: current)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projectsDir = url.path  // reflect immediately
        Task { await model.setProjectsDir(url.path) }
    }
}
