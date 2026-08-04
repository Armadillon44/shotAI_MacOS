import AppKit
import CaptureKit
import SwiftUI

/// The live-updating list of capture permissions (Screen Recording required;
/// Accessibility recommended; Input Monitoring a remedy step). Polls the
/// non-prompting preflights every second so it reflects a change made in System
/// Settings without a relaunch. Shared by the first-run wizard and the Settings
/// window so the two can't drift.
struct PermissionStatusList: View {
    @State private var granted: [CapturePermission: Bool] = [:]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            ForEach(CapturePermission.allCases, id: \.self) { permissionRow($0) }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func permissionRow(_ permission: CapturePermission) -> some View {
        let isGranted = granted[permission] ?? false
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : (permission.isRequired ? "exclamationmark.circle.fill" : "circle"))
                .foregroundStyle(isGranted ? .green : (permission.isRequired ? .orange : .secondary))
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.headline)
                    if permission.isRequired {
                        Text("Required")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                Text(permission.purpose)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isGranted {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Request…") { permission.request() }
                    Button("Open Settings") { permission.openSystemSettings() }
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func refresh() {
        for permission in CapturePermission.allCases {
            granted[permission] = permission.isGranted()
        }
    }
}

/// Relaunch the app cleanly (some TCC grants only take effect on relaunch).
enum AppRelaunch {
    static func now() {
        // Spawn a detached shell that waits for THIS instance to fully exit, then
        // opens a single fresh instance. `open -n` launched a second copy
        // immediately and raced NSApp.terminate — leaving two instances. No `-n`
        // here, so once we're gone `open` starts exactly one.
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "while /bin/kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"\(path)\"",
        ]
        try? task.run()
        NSApp.terminate(nil)
    }
}

/// First-run permissions wizard, shown as an in-window overlay (not a `.sheet` —
/// a SwiftUI sheet vetoes app termination while it's up, and this shows on every
/// launch until Screen Recording is granted, which made the app unquittable
/// except by Force Quit).
struct PermissionsWizardView: View {
    var onClose: () -> Void
    /// Non-nil when this launch found grants an app update silently orphaned
    /// (#62). Swaps the first-run framing for an explanation — the user granted
    /// these already, and being shown the new-user wizard reads as "the app is
    /// broken" rather than "macOS reset this".
    var updateReset: PermissionLedger.Verdict?
    @State private var screenGranted = CapturePermission.screenRecording.isGranted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let updateReset {
                updateResetHeader(updateReset)
            } else {
                Text("Permissions for recording")
                    .font(.title2.bold())
                Text("shotAI captures a screenshot of each step as you click. macOS requires your explicit permission for that.")
                    .foregroundStyle(.secondary)
            }

            PermissionStatusList()

            Text("If a toggle is already on but recording still fails, macOS may require relaunching the app after granting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Relaunch shotAI") { AppRelaunch.now() }
                Button(screenGranted ? "Done" : "Continue anyway") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onReceive(timer) { _ in screenGranted = CapturePermission.screenRecording.isGranted() }
    }

    /// The post-update explanation. Says what happened, that it is expected
    /// rather than a malfunction, and calls out the duplicate System Settings
    /// rows — which are the genuinely confusing part, because the dead entry and
    /// the live one look identical.
    @ViewBuilder private func updateResetHeader(_ verdict: PermissionLedger.Verdict) -> some View {
        Label {
            Text("Updating shotAI reset your permissions")
                .font(.title2.bold())
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }

        Text("\(verdict.lostList) \(verdict.lost.count == 1 ? "was" : "were") switched off when this version replaced "
            + (verdict.previousVersionLabel.map { "\($0)" } ?? "the previous build")
            + ". Please turn \(verdict.lost.count == 1 ? "it" : "them") back on below.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 6) {
            Text("Why this happens").font(.callout.bold())
            Text("macOS ties each permission to the app's code signature, not to its name. shotAI isn't notarized yet, so macOS treats every update as a brand-new app and starts its permissions over. This is expected, and it will stop once shotAI ships with a verified signature.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You may see two “shotAI” entries in System Settings. The old one no longer does anything — select it and click the “–” button to remove it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
