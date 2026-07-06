import AppKit
import CaptureKit
import SwiftUI

/// The floating capture pill — an NSPanel that never steals focus from the app
/// being recorded (.nonactivatingPanel: a deliberate UX improvement over the
/// Windows pill, which activates on click). Content-protected AND excluded
/// from captures via the SCK content filter; only visible while a session
/// exists (recording or paused — pause does not hide it).
@MainActor
final class CapturePillController {
    private var panel: NSPanel?
    private var docked = false
    private let onAction: (PillAction) -> Void
    private var state = CaptureState.idle

    static let pillSize = NSSize(width: 380, height: 52)

    init(onAction: @escaping (PillAction) -> Void) {
        self.onAction = onAction
    }

    func show(state: CaptureState, near mainWindow: NSWindow?) {
        self.state = state
        let panel = ensurePanel()
        if !docked {
            dock(panel, near: mainWindow)
            docked = true
        }
        render()
        panel.orderFrontRegardless()
    }

    func update(state: CaptureState) {
        self.state = state
        render()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.pillSize),
            styleMask: [.nonactivatingPanel, .borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "shotAI — Capture"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Belt-and-braces: hides the pill from legacy CGWindowList recorders
        // and other apps' pickers. SCK ignores this on macOS 15+ — the REAL
        // exclusion is the content filter in SCKScreenshotter.
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        self.panel = panel
        docked = false // a fresh pill re-docks on its next show
        return panel
    }

    /// Top-center of the main window's screen (work area), once per instance;
    /// afterwards the user's dragged position is preserved.
    private func dock(_ panel: NSPanel, near mainWindow: NSWindow?) {
        let screen = mainWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }
        let x = (area.minX + (area.width - Self.pillSize.width) / 2).rounded()
        let y = area.maxY - Self.pillSize.height - 8
        panel.setFrame(NSRect(x: x, y: y, width: Self.pillSize.width, height: Self.pillSize.height), display: false)
    }

    private func render() {
        guard let panel else { return }
        let view = PillView(state: state, onAction: onAction)
        if let hosting = panel.contentView as? FirstMouseHostingView<PillView> {
            hosting.rootView = view
        } else {
            panel.contentView = FirstMouseHostingView(rootView: view)
        }
    }
}

/// The pill is a non-activating, never-key panel, so every click on it is a
/// "first mouse" into a non-key window of an inactive app. NSHostingView does
/// not reliably forward that first click to its SwiftUI controls across macOS
/// versions — without this, Pause/Stop/Discard could be dead by mouse. Accept
/// first mouse so the very first click on a pill button registers.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum PillAction {
    case pause, resume, stop, discard
}

/// Pixel-faithful port of the Windows pill (toolbar/App.tsx + toolbar.css).
struct PillView: View {
    let state: CaptureState
    let onAction: (PillAction) -> Void
    @State private var pulsing = false

    private var active: Bool { state.status != .idle }
    private var paused: Bool { state.status == .paused }

    var body: some View {
        HStack(spacing: 8) {
            // Drag region: grip + label (the panel is movable-by-background;
            // the buttons swallow their own clicks).
            HStack(spacing: 8) {
                gripView
                label
            }
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            if active {
                controls
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 380, height: 52)
        .background(Color(hex: "#1f2330"))
        .overlay(alignment: .top) {
            if active {
                Rectangle().fill(Color(hex: "#4f46e5")).frame(height: 2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { pulsing = true }
    }

    private var gripView: some View {
        // The dotted drag grip.
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    ForEach(0..<2, id: \.self) { _ in
                        Circle().fill(Color(hex: "#6b7280")).frame(width: 2.5, height: 2.5)
                    }
                }
            }
        }
        .opacity(0.8)
    }

    private var label: some View {
        HStack(spacing: 6) {
            if active {
                Circle()
                    .fill(paused ? Color(hex: "#fcd34d") : Color(hex: "#34d399"))
                    .frame(width: 9, height: 9)
                    .opacity(paused ? 1 : (pulsing ? 0.3 : 1))
                    .animation(
                        paused ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                        value: pulsing
                    )
            }
            Text(active ? "\(paused ? "Paused" : "Capturing") · \(state.stepCount)" : "shotAI")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(paused ? Color(hex: "#fcd34d") : Color(hex: "#f4f5f7"))
                .lineLimit(1)
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if paused {
                pillButton("▶ Resume", help: "Resume") { onAction(.resume) }
            } else {
                pillButton("❚❚ Pause", help: "Pause") { onAction(.pause) }
            }
            pillButton("■ Stop", help: "Stop & finish", background: Color(hex: "#4f46e5")) {
                onAction(.stop)
            }
            Rectangle()
                .fill(Color(hex: "#3a4159"))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 1)
            pillButton("✕", help: "Discard this capture (delete this session's steps)",
                       foreground: Color(hex: "#fca5a5")) {
                onAction(.discard)
            }
        }
    }

    private func pillButton(
        _ title: String,
        help: String,
        background: Color = Color(hex: "#2c3142"),
        foreground: Color = Color(hex: "#f4f5f7"),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
