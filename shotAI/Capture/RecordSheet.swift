import CaptureKit
import ShotModel
import SwiftUI

/// Pre-recording target chooser: auto / window / screen / area, mirroring the
/// Windows capture modes. In the default (recording) mode the chosen target
/// persists into the manifest's captureSettings and recording starts on confirm.
/// When `onChoose` is set (the report's "insert one screenshot here" flow) it
/// instead hands the chosen target back and dismisses — no recording, no
/// persisted settings.
struct RecordSheet: View {
    let projectPath: String
    var createdThisSession = false
    let coordinator: CaptureCoordinator
    /// Single-shot mode: hand the chosen target to this closure instead of
    /// starting a full recording. nil = normal record-and-persist behavior.
    var onChoose: ((CaptureTarget) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var singleShot: Bool { onChoose != nil }

    @State private var mode: CaptureMode = .auto
    @State private var targets = CaptureTargets(windows: [], monitors: [])
    @State private var selectedWindow: CaptureKit.WindowInfo?
    @State private var selectedMonitor: MonitorInfo?
    @State private var selectedArea: ShotModel.Rect?
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(singleShot ? "Insert a screenshot" : "Record steps")
                .font(.title2.bold())
            Text(singleShot
                ? "This window hides and a floating pill appears. Your next click captures ONE screenshot, inserted here. A click that only brings a window forward won't count — click again to capture."
                : "Every click captures a screenshot step. ⌘⇧S captures without clicking. Use the floating pill to pause or stop.")
                .foregroundStyle(.secondary)

            Picker("Capture", selection: $mode) {
                Text("Auto (smart)").tag(CaptureMode.auto)
                Text("Window").tag(CaptureMode.window)
                Text("Screen").tag(CaptureMode.screen)
                Text("Area").tag(CaptureMode.area)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch mode {
                case .auto:
                    Text("Frames each click automatically: the active window, a region around shell surfaces (Dock, Spotlight…), or the full screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .window:
                    windowPicker
                case .screen:
                    monitorPicker
                case .area:
                    areaPicker
                }
            }
            .frame(minHeight: 120, alignment: .top)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(singleShot ? "Arm Capture" : "Start Recording") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart || starting)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task { targets = await coordinator.listTargets() }
    }

    private var canStart: Bool {
        switch mode {
        case .auto: true
        case .window: selectedWindow != nil
        case .screen: selectedMonitor != nil
        case .area: selectedArea != nil
        }
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
        .frame(height: 160)
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
        .frame(height: 120)
    }

    private var areaPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let area = selectedArea {
                Text("Selected: \(Int(area.width)) × \(Int(area.height)) at (\(Int(area.x)), \(Int(area.y)))")
                    .font(.callout.monospacedDigit())
            }
            Button(selectedArea == nil ? "Select Area…" : "Reselect Area…") {
                Task { selectedArea = await coordinator.selectArea() ?? selectedArea }
            }
            Text("Drag a rectangle on the screen; Esc cancels.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func start() {
        var target = CaptureTarget(mode: mode)
        switch mode {
        case .window:
            guard let w = selectedWindow else { return }
            target.window = .init(id: w.id, pid: w.pid, title: w.title)
        case .screen:
            target.monitorId = selectedMonitor?.id
        case .area:
            target.area = selectedArea
        case .auto:
            break
        }
        // Single-shot: hand the target back to the caller (which arms one capture)
        // and dismiss — no recording session, no persisted captureSettings.
        if let onChoose {
            onChoose(target)
            dismiss()
            return
        }
        starting = true
        Task {
            let started = await coordinator.record(
                projectPath: projectPath,
                target: target,
                createdThisSession: createdThisSession
            )
            starting = false
            if started { dismiss() }
        }
    }
}
