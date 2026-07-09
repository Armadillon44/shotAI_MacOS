import AppKit
import CoreGraphics
import Foundation
import ShotModel

/// The get-windows / node-screenshots analog: frontmost-window resolution and
/// the pickable-window list, via NSWorkspace + CGWindowListCopyWindowInfo
/// (window titles require Screen Recording — already granted for SCK).
/// kCGWindowBounds is already global TOP-LEFT points, the pipeline's space.
public final class SystemWindowProvider: ActiveWindowProviding, Sendable {
    public init() {}

    public func activeWindow() async -> WindowSnapshot? {
        guard let app = frontmostApplication() else { return nil }
        let front = windowList().first { $0.pid == app.processIdentifier && $0.layer == 0 }
        return WindowSnapshot(
            app: app.localizedName ?? "",
            title: front?.title ?? "",
            pid: Int(app.processIdentifier),
            bundleID: app.bundleIdentifier,
            bounds: front?.bounds
        )
    }

    public func windowAt(_ point: CGPoint) async -> WindowSnapshot? {
        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)
        // windowList() is front-to-back, so the first layer-0 non-own window
        // whose bounds contain the point is the one the user clicked — correct
        // even before the click has activated it (kCGWindowBounds and the click
        // point are both global top-left points).
        guard let w = windowList().first(where: { win in
            win.pid != ownPid && win.layer == 0 && (win.bounds?.contains(point) ?? false)
        }) else { return nil }
        return WindowSnapshot(
            app: w.app,
            title: w.title,
            pid: Int(w.pid),
            bundleID: NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier,
            bounds: w.bounds
        )
    }

    public func listWindows() async -> [WindowInfo] {
        let ownPid = Int32(ProcessInfo.processInfo.processIdentifier)
        var seen = Set<String>()
        var result: [WindowInfo] = []
        for w in windowList() {
            guard w.pid != ownPid, w.layer == 0 else { continue }
            let title = w.title.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            // Dedupe on pid::title, collapsing duplicate windows of one app.
            let key = "\(w.pid)::\(title)"
            guard seen.insert(key).inserted else { continue }
            result.append(WindowInfo(id: Int(w.id), pid: Int(w.pid), title: title, app: w.app))
        }
        return result
    }

    /// Re-resolve the picked window each step: by id, then pid+title, then pid
    /// (ids change across sessions; windows move/retitle). A minimized window
    /// simply isn't in the on-screen list → nil → monitor fallback.
    public func resolveWindow(_ ref: CaptureTarget.WindowRef) async -> CGRect? {
        let list = windowList().filter { $0.layer == 0 }
        if let match = list.first(where: { Int($0.id) == ref.id }) { return match.bounds }
        if let match = list.first(where: { Int($0.pid) == ref.pid && $0.title == ref.title }) {
            return match.bounds
        }
        return list.first { Int($0.pid) == ref.pid }?.bounds
    }

    private func frontmostApplication() -> NSRunningApplication? {
        // NSWorkspace is main-thread-ish but frontmostApplication is safe to
        // read; fall back to the shared workspace value.
        NSWorkspace.shared.frontmostApplication
    }

    private struct ListedWindow {
        var id: UInt32
        var pid: Int32
        var title: String
        var app: String
        var layer: Int
        var bounds: CGRect?
    }

    private func windowList() -> [ListedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32 ?? (entry[kCGWindowNumber as String] as? Int).map(UInt32.init),
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32
            else { return nil }
            var bounds: CGRect?
            if let dict = entry[kCGWindowBounds as String] as? [String: CGFloat] {
                bounds = CGRect(
                    x: dict["X"] ?? 0, y: dict["Y"] ?? 0,
                    width: dict["Width"] ?? 0, height: dict["Height"] ?? 0)
            }
            return ListedWindow(
                id: id,
                pid: pid,
                title: entry[kCGWindowName as String] as? String ?? "",
                app: entry[kCGWindowOwnerName as String] as? String ?? "",
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                bounds: bounds
            )
        }
    }
}
