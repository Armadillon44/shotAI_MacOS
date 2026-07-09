import CaptureKit
import ShotModel
import SwiftUI

/// Immediate window/screen capture picker for the report's "insert a screenshot
/// here" flow: choose a target and it's captured and inserted right away — no
/// floating pill, no click to wait for. (Area capture skips this sheet and goes
/// straight to the drag-out overlay.)
struct ImmediateCaptureSheet: View {
    let projectPath: String
    let insertAt: Int
    let mode: CaptureMode // .window or .screen
    let coordinator: CaptureCoordinator
    /// Called after a successful capture (so the caller can resort the list).
    var onCaptured: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    @State private var targets = CaptureTargets(windows: [], monitors: [])
    @State private var selectedWindow: CaptureKit.WindowInfo?
    @State private var selectedMonitor: MonitorInfo?
    @State private var capturing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .window ? "Capture a window" : "Capture the screen")
                .font(.title2.bold())
            Text(mode == .window
                ? "Pick a window to screenshot. It's captured in full even if another window is on top; the shotAI window itself is never included."
                : "Pick a screen to capture. The shotAI window is never included in the shot.")
                .foregroundStyle(.secondary)

            Group {
                if mode == .window { windowPicker } else { monitorPicker }
            }
            .frame(minHeight: 120, alignment: .top)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Capture") { capture() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCapture || capturing)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task {
            targets = await coordinator.listTargets()
            if mode == .screen {
                selectedMonitor = targets.monitors.first { $0.isPrimary } ?? targets.monitors.first
            }
        }
    }

    private var canCapture: Bool {
        mode == .window ? selectedWindow != nil : selectedMonitor != nil
    }

    private var windowPicker: some View {
        List(targets.windows, id: \.id, selection: Binding(
            get: { selectedWindow?.id },
            set: { id in selectedWindow = targets.windows.first { $0.id == id } }
        )) { window in
            VStack(alignment: .leading, spacing: 1) {
                Text(window.title).lineLimit(1)
                Text(window.app).font(.caption).foregroundStyle(.secondary)
            }
            .tag(window.id)
        }
        .frame(height: 200)
        .overlay {
            if targets.windows.isEmpty {
                Text("No windows to pick — is Screen Recording granted?")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var monitorPicker: some View {
        List(targets.monitors, id: \.id, selection: Binding(
            get: { selectedMonitor?.id },
            set: { id in selectedMonitor = targets.monitors.first { $0.id == id } }
        )) { monitor in
            Text("\(monitor.name) — \(monitor.width)×\(monitor.height)\(monitor.isPrimary ? " (primary)" : "")")
                .tag(monitor.id)
        }
        .frame(height: 140)
        .overlay {
            if targets.monitors.isEmpty {
                Text("No screens available — is Screen Recording granted?")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func capture() {
        var target = CaptureTarget(mode: mode)
        switch mode {
        case .window:
            guard let w = selectedWindow else { return }
            target.window = .init(id: w.id, pid: w.pid, title: w.title)
        case .screen:
            guard let m = selectedMonitor else { return }
            target.monitorId = m.id
        default:
            return
        }
        capturing = true
        Task {
            _ = await coordinator.captureTargetNow(
                projectPath: projectPath, insertAt: insertAt, target: target)
            capturing = false
            onCaptured()
            dismiss()
        }
    }
}
