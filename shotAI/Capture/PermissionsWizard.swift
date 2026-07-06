import CaptureKit
import SwiftUI

/// First-run permissions wizard. Polls the non-prompting preflights every
/// second so the list auto-updates when the user flips a toggle in System
/// Settings. Screen Recording is the only hard requirement; Accessibility is
/// recommended (element captions fail soft); Input Monitoring is a remedy
/// step (a listen-only mouse tap usually needs no grant).
struct PermissionsWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var granted: [CapturePermission: Bool] = [:]
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var screenRecordingGranted: Bool {
        granted[.screenRecording] ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions for recording")
                .font(.title2.bold())
            Text("shotAI captures a screenshot of each step as you click. macOS requires your explicit permission for that.")
                .foregroundStyle(.secondary)

            ForEach(CapturePermission.allCases, id: \.self) { permission in
                permissionRow(permission)
            }

            Text("If a toggle is already on but recording still fails, macOS may require relaunching the app after granting.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Relaunch shotAI") { relaunch() }
                Button(screenRecordingGranted ? "Done" : "Continue anyway") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
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

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
