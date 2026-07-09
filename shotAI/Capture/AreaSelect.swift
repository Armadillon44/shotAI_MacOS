import AppKit
import Foundation

/// Area-select overlay: one transparent borderless window per screen at
/// screen-saver level. Drag ≥ 4×4 pt confirms on MOUSE-UP; Esc, a sub-4pt
/// click, a right/middle mousedown, or any overlay closing cancels. The
/// result is a GLOBAL TOP-LEFT POINT rect (the pipeline's space). Selection
/// happens strictly BEFORE recording starts, so overlay and capture never
/// coexist. Single resolution guaranteed.
@MainActor
final class AreaSelectController {
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?

    func selectArea() async -> CGRect? {
        finish(nil) // a new selection tears down any in-flight one (resolves null)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let window = OverlayWindow(screen: screen) { [weak self] result in
                    self?.finish(result)
                }
                windows.append(window)
                window.orderFrontRegardless()
                window.makeKey()
            }
            // The caller hid the report window (and may have deactivated us), so
            // activate so the overlay is key — Esc works and the crosshair drag
            // starts on the FIRST click (paired with OverlayView.acceptsFirstMouse).
            if !windows.isEmpty { NSApp.activate(ignoringOtherApps: true) }
            if windows.isEmpty { finish(nil) }
        }
    }

    private func finish(_ rect: CGRect?) {
        let pending = continuation
        continuation = nil
        let open = windows
        windows = []
        for w in open {
            w.selectionHandler = nil
            w.orderOut(nil)
        }
        pending?.resume(returning: rect)
    }
}

/// A full-screen transparent overlay. Must become key to receive Esc.
private final class OverlayWindow: NSWindow {
    var selectionHandler: ((CGRect?) -> Void)?

    init(screen: NSScreen, onFinish: @escaping (CGRect?) -> Void) {
        selectionHandler = onFinish
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        title = "shotAI — Select area"
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        sharingType = .none
        isReleasedWhenClosed = false
        ignoresMouseEvents = false
        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] viewRect in
            guard let self else { return }
            self.selectionHandler?(viewRect.map { self.globalCGRect(fromViewRect: $0) })
        }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }

    /// View-local rect (top-left origin within this overlay) → global CG
    /// top-left points. The view fills the window which fills its screen.
    private func globalCGRect(fromViewRect rect: CGRect) -> CGRect {
        let screenFrame = frame // AppKit global, bottom-left origin
        let topLeftGlobal = CoordinateSpaces.cgRect(fromAppKit: screenFrame)
        return CGRect(
            x: (topLeftGlobal.minX + rect.minX).rounded(),
            y: (topLeftGlobal.minY + rect.minY).rounded(),
            width: rect.width.rounded(),
            height: rect.height.rounded()
        )
    }
}

/// Crosshair + drag rectangle + dimming + physical-pixel size badge, in
/// FLIPPED (top-left) view coordinates so rect math matches the global space.
private final class OverlayView: NSView {
    var onFinish: ((CGRect?) -> Void)?
    private var start: CGPoint?
    private var current: CGPoint?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    // Receive the click that activates the overlay AS the drag-start, instead of
    // it being swallowed just to bring the window forward (the "first empty
    // click" the user hit).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .cursorUpdate, .mouseMoved],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    private var selectionRect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        start = p
        current = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        // Mouse-up IS the confirm; anything smaller than 4×4 is a stray click.
        if let rect = selectionRect, rect.width >= 4, rect.height >= 4 {
            onFinish?(rect)
        } else {
            onFinish?(nil)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onFinish?(nil) // cancel immediately
    }

    override func otherMouseDown(with event: NSEvent) {
        onFinish?(nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onFinish?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = selectionRect else {
            drawHint()
            return
        }
        // Dim everything OUTSIDE the selection (only once a drag exists).
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: rect).reversed)
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()
        // 2pt indigo border.
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        NSColor(hexString: "#6366f1").setStroke()
        border.stroke()
        // Physical-pixel dims badge, top-left inside the rect.
        if rect.width >= 40, rect.height >= 22 {
            let scale = window?.screen?.backingScaleFactor ?? 1
            let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))px"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = text.size(withAttributes: attrs)
            let badge = NSRect(
                x: rect.minX + 4, y: rect.minY + 4,
                width: size.width + 12, height: size.height + 4)
            let path = NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6)
            NSColor(hexString: "#6366f1").setFill()
            path.fill()
            text.draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 2), withAttributes: attrs)
        }
    }

    private func drawHint() {
        let title = "Drag to select a capture area"
        let sub = "Press Esc to cancel"
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: NSColor(hexString: "#c7cdda"),
        ]
        let titleSize = title.size(withAttributes: titleAttrs)
        let subSize = sub.size(withAttributes: subAttrs)
        let width = max(titleSize.width, subSize.width) + 48
        let height = titleSize.height + subSize.height + 32
        let box = NSRect(
            x: (bounds.width - width) / 2,
            y: bounds.height * 0.14,
            width: width, height: height)
        let path = NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12)
        NSColor(hexString: "#111827").withAlphaComponent(0.85).setFill()
        path.fill()
        title.draw(
            at: NSPoint(x: box.midX - titleSize.width / 2, y: box.minY + 14),
            withAttributes: titleAttrs)
        sub.draw(
            at: NSPoint(x: box.midX - subSize.width / 2, y: box.minY + 16 + titleSize.height),
            withAttributes: subAttrs)
    }
}

extension NSColor {
    convenience init(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0x6366F1
        self.init(
            red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
