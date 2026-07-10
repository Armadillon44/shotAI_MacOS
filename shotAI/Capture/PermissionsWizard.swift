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
    @State private var screenGranted = CapturePermission.screenRecording.isGranted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions for recording")
                .font(.title2.bold())
            Text("shotAI captures a screenshot of each step as you click. macOS requires your explicit permission for that.")
                .foregroundStyle(.secondary)

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
}
