import CoreGraphics
import Foundation
import ShotModel

/// Coordinate convention (differs from Windows, self-consistent per project):
/// the "global" space on macOS is CG top-left-origin GLOBAL POINTS — the shared
/// space of CGEvent.location, AX hit-testing, and SCDisplay frames. Everything
/// persisted as "global" (click.global, monitor.bounds, element.bounds,
/// CaptureTarget.area) uses it, with monitor.scaleFactor carrying the
/// points→pixels bridge. click.image stays in stored-PNG pixels, and the schema
/// invariant image == round((global − origin) × imageScale) holds with
/// imageScale = pixelScale × downscale — so merge/marker math round-trips with
/// Windows projects unchanged.

/// Recording state broadcast to the UI — mirrors the Windows CaptureState shape.
public struct CaptureState: Equatable, Sendable {
    public enum Status: String, Sendable {
        case idle, recording, paused
    }

    public var status: Status
    public var projectPath: String?
    public var projectTitle: String?
    public var stepCount: Int

    public static let idle = CaptureState(status: .idle, projectPath: nil, projectTitle: nil, stepCount: 0)

    public init(status: Status, projectPath: String?, projectTitle: String?, stepCount: Int) {
        self.status = status
        self.projectPath = projectPath
        self.projectTitle = projectTitle
        self.stepCount = stepCount
    }
}

/// Events the engine emits to the UI layer — the native analog of the
/// capture:state-changed / capture:step-added / capture:error broadcasts.
public enum CaptureEvent: Sendable {
    case stateChanged(CaptureState)
    case stepAdded(ProjectStep)
    case error(String)
    /// Mirrors onRecordingChange — the host hides/shows the main window and
    /// pill around it.
    case recordingChanged(Bool)
}

/// A mouse-down delivered by the global tap. `location` is global top-left
/// points; `button` already mapped to the schema's button vocabulary.
public struct TapEvent: Sendable {
    public var location: CGPoint
    public var button: MouseButton

    public init(location: CGPoint, button: MouseButton) {
        self.location = location
        self.button = button
    }
}

/// A display, in global top-left points + its points→pixels scale.
public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32
    public var frame: CGRect
    public var pixelScale: CGFloat
    public var isPrimary: Bool
    public var name: String

    public init(id: UInt32, frame: CGRect, pixelScale: CGFloat, isPrimary: Bool, name: String) {
        self.id = id
        self.frame = frame
        self.pixelScale = pixelScale
        self.isPrimary = isPrimary
        self.name = name
    }
}

/// A captured full-display frame. CGImage is immutable and thread-safe.
public struct CapturedFrame: @unchecked Sendable {
    public var image: CGImage
    public var display: DisplayInfo

    public init(image: CGImage, display: DisplayInfo) {
        self.image = image
        self.display = display
    }
}

/// The frontmost window at capture time (get-windows analog). Bounds are
/// global top-left points.
public struct WindowSnapshot: Equatable, Sendable {
    /// Localized app name ("Google Chrome" here vs "chrome.exe" on Windows).
    public var app: String
    public var title: String
    public var pid: Int
    public var bundleID: String?
    public var bounds: CGRect?

    public init(app: String, title: String, pid: Int, bundleID: String?, bounds: CGRect?) {
        self.app = app
        self.title = title
        self.pid = pid
        self.bundleID = bundleID
        self.bounds = bounds
    }
}

// MARK: - Service protocols (hardware behind seams so the pipeline tests headless)

public protocol Screenshotter: Sendable {
    /// Current displays — re-queried per capture (displays can reconfigure
    /// mid-recording; never cache).
    func displays() async throws -> [DisplayInfo]
    /// Full-display capture at native pixel resolution, own app excluded.
    func captureDisplay(_ id: UInt32) async throws -> CapturedFrame
}

public protocol ActiveWindowProviding: Sendable {
    /// The frontmost app's front window (title needs Screen Recording). nil
    /// when nothing qualifies (e.g. our own content-protected windows).
    func activeWindow() async -> WindowSnapshot?
    /// The frontmost (top-of-z-order) non-own window CONTAINING a global
    /// top-left point. Unlike activeWindow(), this is timing-independent: a
    /// click on an INACTIVE window doesn't update the frontmost app
    /// synchronously, but the window under the cursor is already correct. nil
    /// when nothing (our own windows / the desktop) is under the point.
    func windowAt(_ point: CGPoint) async -> WindowSnapshot?
    /// Pickable windows for the 'window' chooser.
    func listWindows() async -> [WindowInfo]
    /// Re-resolve the picked window each step: by id, then pid+title, then pid.
    func resolveWindow(_ ref: CaptureTarget.WindowRef) async -> CGRect?
}

public protocol ElementLocating: Sendable {
    /// UI element at a global top-left point. MUST be started at mousedown
    /// time (before the click mutates the UI), never block > ~600 ms, and
    /// degrade to nil on any failure.
    func elementAt(_ point: CGPoint) async -> StepElement?
}

public protocol OwnWindowChecking: Sendable {
    /// Geometric hit test against every visible own window (global top-left
    /// points). Load-bearing for "pill clicks create no steps": the
    /// non-activating pill never reports as frontmost.
    func pointHitsOwnWindow(_ point: CGPoint) async -> Bool
    /// True when the frontmost application is this app.
    func frontmostIsOwnApp() async -> Bool
}

/// Attaches/detaches the global triggers (event tap + hotkey). The engine
/// controls lifecycle; the handlers must return fast (they hop straight into
/// the engine's event stream).
public protocol TriggerSource: Sendable {
    func attach(
        mouse: @escaping @Sendable (TapEvent) -> Void,
        hotkey: (@Sendable () -> Void)?
    ) throws
    func detach()
}

/// Pickable window/monitor lists for the target chooser UI.
public struct CaptureTargets: Sendable {
    public var windows: [WindowInfo]
    public var monitors: [MonitorInfo]

    public init(windows: [WindowInfo], monitors: [MonitorInfo]) {
        self.windows = windows
        self.monitors = monitors
    }
}

/// A pickable open window (for the 'window' chooser). Runtime-only — never
/// persisted (only the chosen CaptureTarget.WindowRef lands in the manifest).
public struct WindowInfo: Equatable, Sendable {
    public var id: Int
    public var pid: Int
    public var title: String
    public var app: String

    public init(id: Int, pid: Int, title: String, app: String) {
        self.id = id
        self.pid = pid
        self.title = title
        self.app = app
    }
}

/// A pickable monitor (point dimensions; cosmetic).
public struct MonitorInfo: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var width: Int
    public var height: Int
    public var isPrimary: Bool

    public init(id: Int, name: String, width: Int, height: Int, isPrimary: Bool) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.isPrimary = isPrimary
    }
}
