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

            if model.auth.federationAvailable {
                Section("Account") {
                    AccountRows()
                }
            }

            Section("Generation") {
                VStack(alignment: .leading, spacing: 3) {
                    Picker("Model", selection: $model.sopSettings.model) {
                        ForEach(SOP_MODELS, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    if let b = SOP_MODELS.first(where: { $0.id == model.sopSettings.model })?.blurb {
                        Text(b).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Picker("Tone", selection: $model.sopSettings.tone) {
                        ForEach(SOP_TONES, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    if let b = SOP_TONES.first(where: { $0.id == model.sopSettings.tone })?.blurb {
                        Text(b).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Picker("Effort", selection: $model.sopSettings.effort) {
                        ForEach(SOP_EFFORTS, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    if let b = SOP_EFFORTS.first(where: { $0.id == model.sopSettings.effort })?.blurb {
                        Text(b).font(.caption).foregroundStyle(.secondary)
                    }
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

            Section {
                DisclosureGroup("Advanced") {
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
                    // A stored key that couldn't be read (rare Keychain state) — warn
                    // and offer to clear the broken entry so a fresh key can be saved.
                    if model.apiKeyUnreadable {
                        Label("A previously saved key couldn't be read.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(Palette.draftInk)
                        Button("Clear stored key", role: .destructive) {
                            keyMessage = model.clearApiKey() ?? "Stored key cleared."
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
                    Link("Create an API key at console.anthropic.com",
                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(.caption)
                }
                }
            } footer: {
                Text(model.auth.federationAvailable
                     ? "Signing in with your work account is the normal path. A personal API key is here for troubleshooting and testing — if one is set while you're signed in, the signed-in session is used."
                     : "shotAI needs an Anthropic API key to write SOPs.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .task { await model.refreshAuthStatus() }
    }
}

/// The Account rows — signed out, signed in, signed in without access, or a
/// broken configuration profile. Split out to keep `AISettings.body` legible.
private struct AccountRows: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.auth.state {
        case .unavailable:
            EmptyView()

        // An IT problem, not a user one. Name the fields so a ticket is actionable,
        // and never show their values.
        case .misconfigured(let fields):
            Label("shotAI's sign-in isn't configured correctly on this Mac.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(Palette.draftInk)
            Text("Ask IT to re-apply the shotAI configuration profile. Missing or invalid: \(fields.joined(separator: ", ")).")
                .font(.caption).foregroundStyle(.secondary)

        case .signedOut:
            LabeledContent("Status") { Text("Not signed in").foregroundStyle(.secondary) }
            HStack {
                Button("Sign In…") { Task { await model.auth.signIn() } }
                    .disabled(model.auth.busy)
                if model.auth.busy { ProgressView().controlSize(.small) }
            }
            Text("Sign in with your work account to write SOPs. No API key needed — shotAI gets a short-lived token that expires on its own.")
                .font(.caption).foregroundStyle(.secondary)

        case .signedIn(let account, let entitled):
            LabeledContent("Signed in as") {
                Text(account ?? "your work account").foregroundStyle(.secondary)
            }
            // Signed in fine, no app role. Say so plainly: retrying cannot fix it,
            // and it is emphatically not a failed login.
            if entitled == false {
                Label("This account doesn't have access to shotAI's AI features yet.",
                      systemImage: "person.badge.clock")
                    .font(.callout).foregroundStyle(Palette.draftInk)
                Text("Your sign-in worked. Ask IT to grant your account access, then use Check Again — signing out and back in won't change it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Check Again") { Task { await model.auth.signIn(forceLogin: true) } }
                    .disabled(model.auth.busy)
                Button("Sign Out") { Task { await model.auth.signOut() } }
                    .disabled(model.auth.busy)
                if model.auth.busy { ProgressView().controlSize(.small) }
            }
        }

        if let e = model.auth.error {
            Text(e).font(.caption).foregroundStyle(Palette.draftInk)
        }
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
    @Environment(\.openWindow) private var openWindow
    // Local mirror so the label updates immediately after Change… — reading
    // model.settings.projectsDir() directly registers no observation dependency
    // (settings is a `let`, and it reads UserDefaults), so the view wouldn't
    // otherwise re-evaluate.
    @State private var projectsDir = ""
    @State private var archiveAge = archiveAgeDefault

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("shotAI for macOS").font(.title3.bold())
                    Text("Version \(appVersion)").foregroundStyle(.secondary).font(.callout)
                }
            }

            updatesSection

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

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Auto-archive").font(.headline)
                Picker("Archive projects untouched for", selection: $archiveAge) {
                    Text("Never").tag(0)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 340, alignment: .leading)
                .onChange(of: archiveAge) { _, v in model.setArchiveAgeDays(v) }
                Text("On launch, projects you haven't touched in this long are compressed into the Archive to save disk — their screenshots are zipped in place and restore automatically when you open the project.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Getting started").font(.headline)
                Button("Show intro tour") {
                    model.replayTour()
                    // The tour renders only in the main window — bring it forward
                    // (or reopen it if the user closed it) so the tour is visible.
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
                Text("Replay the first-run walkthrough of capture, modes, the recording pill, and SOP generation.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // General's other controls persist themselves (setArchiveAgeDays /
        // setProjectsDir), so this tab had no `preferences` binding until the
        // Updates toggle arrived — without this the toggle would look like it
        // stuck and revert on the next launch. Same pattern as the Capture and
        // Appearance tabs.
        .onChange(of: model.preferences) { old, new in
            model.savePreferences()
            // Both directions: leaving the "on" transition unhandled strands the
            // status line reading "Automatic update checks are off." beside a
            // toggle that is switched ON.
            guard old.checkForUpdates != new.checkForUpdates else { return }
            if new.checkForUpdates {
                Task { await model.updates.automaticChecksEnabled() }
            } else {
                model.updates.automaticChecksDisabled()
            }
        }
        .onAppear {
            projectsDir = model.settings.projectsDir()
            archiveAge = model.settings.archiveAgeDays()
            // Show "Last checked …" even if this launch hasn't checked yet.
            Task { await model.updates.loadPersistedState() }
        }
    }

    /// Updates (#62 Phase 1 — notify only). Sits directly under the version
    /// header, which is where anyone wondering "am I current?" is already looking.
    @ViewBuilder private var updatesSection: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.updates.statusText)
                    .font(.callout)
                    .foregroundStyle(model.updates.pending != nil ? Palette.accentInk : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.updates.checking { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Button("Check Now") {
                    Task { await model.checkForUpdatesNow() }
                }
                .controlSize(.small)
                // NOT gated on the preference: that governs the automatic daily
                // check, and an explicit request deserves an answer either way.
                .disabled(model.updates.checking || model.updates.isManagedDisabled)

                if model.updates.pending != nil {
                    Button("Download…") { model.updates.openReleasePage() }
                        .controlSize(.small)
                }
                if model.updates.skippedTag != nil {
                    Button("Show Skipped Version") {
                        Task {
                            await model.updates.clearSkip()
                            await model.checkForUpdatesNow()
                        }
                    }
                    .controlSize(.small)
                }
            }

            if model.updates.isManagedDisabled {
                Label(
                    "Your organization has turned off update checks with a configuration profile.",
                    systemImage: "building.2"
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Check for updates automatically", isOn: $model.preferences.checkForUpdates)
                    .controlSize(.small)
                Text("Once a day, shotAI asks GitHub whether a newer release exists and shows a small notice on the Home screen. It never downloads or installs anything on its own — the Download button opens the release page in your browser. Turn this off and nothing is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
