import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// The three TCC permissions and their mechanics. Notes that shape the wizard:
/// - Screen Recording: REQUIRED (ScreenCaptureKit). Grant usually needs an app
///   relaunch; macOS 15+ re-confirms periodically and shows a purple menu-bar
///   indicator while capturing.
/// - Accessibility: RECOMMENDED (element-at-point). Fails soft — captures work
///   without element names. Usually takes effect without relaunch.
/// - Input Monitoring: CONDITIONAL. A listen-only mouse-only tap empirically
///   needs no grant, but that's undocumented — the wizard shows this step only
///   as a remedy when the tap can't be created.
public enum CapturePermission: String, CaseIterable, Sendable {
    case screenRecording
    case accessibility
    case inputMonitoring

    public var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    public var purpose: String {
        switch self {
        case .screenRecording:
            "Required to capture screenshots of each step (and to read window titles)."
        case .accessibility:
            "Recommended: identifies the button or control you clicked, for better step captions."
        case .inputMonitoring:
            "Usually not needed — grant it only if clicks aren't being detected while recording."
        }
    }

    public var isRequired: Bool { self == .screenRecording }

    /// Non-prompting status check.
    public func isGranted() -> Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
    }

    /// Trigger the system consent prompt (shows at most once per grant state;
    /// returns the CURRENT status immediately — it does not wait for the user).
    @discardableResult
    public func request() -> Bool {
        switch self {
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        case .accessibility:
            // Literal key: the kAXTrustedCheckOptionPrompt global is a `var`
            // and trips strict-concurrency. Value verified in AXUIElement.h.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .inputMonitoring:
            return CGRequestListenEventAccess()
        }
    }

    /// Deep-link to the exact System Settings pane (reveals it; the user still
    /// flips the toggle). Verified working on macOS 13–26.
    public var settingsURL: URL {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    @MainActor
    public func openSystemSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Screen Recording (and Input Monitoring) grants generally require an app
    /// relaunch to take effect; Accessibility usually doesn't.
    public var needsRelaunchAfterGrant: Bool {
        self != .accessibility
    }
}
