import ApplicationServices
import CoreGraphics
import Foundation
import ShotModel

/// Element-at-point via the Accessibility API — the port of the Windows UIA
/// Rust addon. Contract (must match exactly):
/// - Query starts at MOUSEDOWN; hard 600 ms wait cap; late results discarded,
///   never applied; every failure degrades to nil (capture proceeds with
///   window-only captions). Best-effort, crash-proof, hang-proof.
/// - Climb: self + up to 5 ancestors; the NEAREST element that is BOTH named
///   and on the actionable allowlist wins; else report the raw hit element
///   with available=false (its controlType/bounds still real data).
/// - controlType is persisted in the WINDOWS UIA vocabulary ("Button",
///   "TabItem"…) so captions, controlWord(), and the Claude prompt stay
///   byte-identical across platforms.
/// - PRIVACY: names come from title/label attributes only — NEVER
///   kAXValueAttribute (field contents), and secure fields never yield names.
public final class AXElementLocator: ElementLocating, @unchecked Sendable {
    /// CONCURRENT so a hung app's query doesn't block subsequent queries'
    /// execution — the AX call is a synchronous mach IPC into the target, and
    /// on a serial queue one beach-balling app would back up every following
    /// step's element lookup (Windows runs each query on the libuv pool).
    private let queue = DispatchQueue(
        label: "shotAI.elementLocator", qos: .userInitiated, attributes: .concurrent)
    private let disabledLogged = NSLock()
    private var loggedDisabled = false

    public init() {
        // Lower the process-global AX messaging timeout so an unresponsive app
        // can't hold a query for the ~6 s default.
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.5)
    }

    public func elementAt(_ point: CGPoint) async -> StepElement? {
        // Same lifecycle as the DLL-load failure on Windows: no grant → the
        // feature is disabled (logged once), captures fall back soft.
        guard AXIsProcessTrusted() else {
            logDisabledOnce()
            return nil
        }
        return await withCheckedContinuation { continuation in
            let settled = SettleOnce(continuation: continuation)
            queue.async {
                let result = Self.query(point: point)
                settled.resolve(result)
            }
            // Hard cap on a DIFFERENT queue: scheduled on the same work queue
            // it could not preempt a running query, so the 600 ms deadline
            // would never actually fire. The query keeps running; its late
            // result is discarded, not canceled — the Windows semantics.
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + CaptureConstants.elementQueryTimeout
            ) {
                settled.resolve(nil)
            }
        }
    }

    /// First-resolution-wins guard for the timeout race.
    private final class SettleOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<StepElement?, Never>?

        init(continuation: CheckedContinuation<StepElement?, Never>) {
            self.continuation = continuation
        }

        func resolve(_ value: StepElement?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    private func logDisabledOnce() {
        disabledLogged.lock()
        defer { disabledLogged.unlock() }
        if !loggedDisabled {
            loggedDisabled = true
            NSLog("element-locator: Accessibility not granted — element names disabled")
        }
    }

    // MARK: - The hit + climb algorithm (mirrors lib.rs)

    private static func query(point: CGPoint) -> StepElement? {
        // DEFENSE-IN-DEPTH: never hit-test a point over our OWN window.
        // AXUIElementCopyElementAtPosition recurses into the target window's
        // accessibility IN-PROCESS when that window is ours; our SwiftUI AX is
        // main-thread-only and traps (SIGTRAP) off this background queue. The
        // engine already gates own-window clicks, but a crash here kills the
        // whole app + the in-progress recording, so guard the AX call directly.
        if pointOverOwnProcessWindow(point) { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        var hitRef: AXUIElement?
        // AXUIElementCopyElementAtPosition takes global TOP-LEFT points — the
        // exact space CGEvent.location reports; no conversion.
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hitRef) == .success,
              let hit = hitRef
        else { return nil }

        var chosen: AXUIElement?
        var cursor: AXUIElement? = hit
        var depth = 0
        // At most 6 elements examined: self + 5 ancestors; nearest wins.
        while let el = cursor, depth < 6 {
            let type = controlType(of: el)
            if isActionable(type), let n = name(of: el, controlType: type), !n.isEmpty {
                chosen = el
                break
            }
            cursor = parent(of: el)
            depth += 1
        }

        let el = chosen ?? hit // fall back to the RAW HIT element
        let type = controlType(of: el)
        let resolvedName: String? = chosen != nil ? name(of: el, controlType: type) : nil
        return StepElement(
            available: resolvedName != nil && !(resolvedName ?? "").isEmpty,
            name: (resolvedName?.isEmpty ?? true) ? nil : resolvedName,
            controlType: type,
            bounds: bounds(of: el)
        )
    }

    /// True iff the topmost on-screen window at `point` belongs to our process.
    /// Uses CGWindowList (bounds + owner pid + z-order — no AX, no Screen
    /// Recording needed), so it can't itself trigger the recursion it guards
    /// against. Fails safe: on any doubt it returns false (query proceeds).
    private static func pointOverOwnProcessWindow(_ point: CGPoint) -> Bool {
        let ownPID = getpid()
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Front-to-back order; the first window whose bounds contain the point
        // is the topmost there — the one the AX hit test would descend into.
        for info in infos {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard rect.contains(point) else { continue }
            let pid = (info[kCGWindowOwnerPID as String] as? pid_t) ?? -1
            return pid == ownPID
        }
        return false
    }

    // MARK: - Attribute helpers

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        attribute(el, name) as? String
    }

    private static func parent(of el: AXUIElement) -> AXUIElement? {
        guard let ref = attribute(el, kAXParentAttribute as String) else { return nil }
        guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    /// Label-only name extraction. NEVER kAXValueAttribute — a field's
    /// contents must never end up in a caption or reach Claude. Secure fields
    /// yield nothing at all.
    private static func name(of el: AXUIElement, controlType: String?) -> String? {
        let subrole = string(el, kAXSubroleAttribute as String)
        if subrole == "AXSecureTextField" { return nil }
        let role = string(el, kAXRoleAttribute as String)
        // An AXPopUpButton/AXComboBox's AXTitle is the SELECTED VALUE, not a
        // label (e.g. the chosen account email/amount) — surfacing it would
        // leak content the pixel redaction can't reach. Fall through to the
        // description / labeledBy element instead; if neither exists, no name.
        let titleIsValue = role == "AXPopUpButton" || role == "AXComboBox"
        if !titleIsValue, let title = string(el, kAXTitleAttribute as String), !title.isEmpty { return title }
        if let desc = string(el, kAXDescriptionAttribute as String), !desc.isEmpty { return desc }
        // The label element NEXT TO a field (the UIA "Edit Name = label" analog).
        if let ref = attribute(el, "AXTitleUIElement"),
           CFGetTypeID(ref) == AXUIElementGetTypeID() {
            let labelEl = ref as! AXUIElement
            if let label = string(labelEl, kAXTitleAttribute as String), !label.isEmpty { return label }
            // A static-text label's text lives in AXValue — reading it from a
            // STATIC TEXT label (not from the field itself) stays label-only.
            if string(labelEl, kAXRoleAttribute as String) == "AXStaticText",
               let label = attribute(labelEl, kAXValueAttribute as String) as? String, !label.isEmpty {
                return label
            }
        }
        return nil
    }

    private static func bounds(of el: AXUIElement) -> ShotModel.Rect? {
        guard let posRef = attribute(el, kAXPositionAttribute as String),
              let sizeRef = attribute(el, kAXSizeAttribute as String),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        else { return nil }
        // Global top-left points — the same space as click.global.
        return ShotModel.Rect(x: pos.x, y: pos.y, width: size.width, height: size.height)
    }

    // MARK: - AX role → Windows UIA controlType vocabulary

    /// Persisted controlType for an element. Some roles need PARENT context
    /// (Windows got distinct UIA ids for free): AXRadioButton inside an
    /// AXTabGroup is a tab; AXRow depends on its container kind.
    private static func controlType(of el: AXUIElement) -> String? {
        guard let role = string(el, kAXRoleAttribute as String) else { return nil }
        let subrole = string(el, kAXSubroleAttribute as String)
        switch role {
        case "AXButton":
            return "Button"
        case "AXMenuButton":
            return "SplitButton"
        case "AXCheckBox":
            return "CheckBox" // includes AXSwitch/AXToggle subroles
        case "AXRadioButton":
            return ancestorRole(of: el, is: "AXTabGroup") ? "TabItem" : "RadioButton"
        case "AXLink":
            return "Hyperlink"
        case "AXTextField", "AXSearchField":
            return "Edit"
        case "AXTextArea":
            return "Document"
        case "AXComboBox", "AXPopUpButton":
            return "ComboBox" // macOS dropdowns are usually AXPopUpButton
        case "AXMenuItem", "AXMenuBarItem":
            return "MenuItem"
        case "AXSlider":
            return "Slider"
        case "AXIncrementor":
            return "Spinner"
        case "AXRow":
            if subrole == "AXOutlineRow" || ancestorRole(of: el, is: "AXOutline") { return "TreeItem" }
            if ancestorRole(of: el, is: "AXTable") { return "DataItem" }
            return "ListItem"
        case "AXCell":
            return ancestorRole(of: el, is: "AXTable") ? "DataItem" : "ListItem"
        case "AXStaticText":
            return "Text"
        case "AXImage":
            return "Image"
        case "AXWindow":
            return "Window"
        case "AXGroup":
            return "Group"
        case "AXScrollArea", "AXSplitGroup":
            return "Pane"
        case "AXWebArea":
            return "Document"
        case "AXToolbar":
            return "ToolBar"
        case "AXMenu":
            return "Menu"
        case "AXMenuBar":
            return "MenuBar"
        case "AXList":
            return "List"
        case "AXOutline":
            return "Tree"
        case "AXTable":
            return "Table"
        case "AXProgressIndicator":
            return "ProgressBar"
        case "AXScrollBar":
            return "ScrollBar"
        case "AXTabGroup":
            return "Tab"
        default:
            if subrole == "AXTabButton" { return "TabItem" } // browser tabs
            return "Unknown"
        }
    }

    /// The actionable allowlist — exactly the 15 UIA types whose Name is a
    /// stable LABEL (privacy invariant: content-bearing types are excluded).
    private static let actionableTypes: Set<String> = [
        "Button", "CheckBox", "ComboBox", "Edit", "Hyperlink", "ListItem",
        "MenuItem", "RadioButton", "Slider", "Spinner", "Tab", "TabItem",
        "TreeItem", "DataItem", "SplitButton",
    ]

    private static func isActionable(_ type: String?) -> Bool {
        guard let type else { return false }
        return actionableTypes.contains(type)
    }

    /// Cheap bounded look-up the parent chain for a container role (one extra
    /// role read per candidate, bounded so a cyclic tree can't spin).
    private static func ancestorRole(of el: AXUIElement, is target: String, maxHops: Int = 5) -> Bool {
        var cursor = parent(of: el)
        var hops = 0
        while let el = cursor, hops < maxHops {
            if string(el, kAXRoleAttribute as String) == target { return true }
            cursor = parent(of: el)
            hops += 1
        }
        return false
    }
}
