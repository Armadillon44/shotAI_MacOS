import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import ShotModel

/// The real TriggerSource: a listen-only, MOUSE-ONLY CGEventTap (empirically
/// needs no TCC grant in that exact configuration — adding any keyboard event
/// type would silently re-gate it behind Input Monitoring) plus a Carbon
/// RegisterEventHotKey ⌘⇧S (the same mechanism Electron's globalShortcut
/// uses; no TCC needed, not deprecated).
///
/// Thread model: attach()/detach() are driven from the CaptureEngine actor's
/// executor (a background cooperative thread); the tap callback runs on a
/// dedicated tap thread; the hotkey handler is dispatched by the MAIN thread's
/// Carbon event dispatcher. All shared fields are guarded by `lock`, the tap
/// thread's lifecycle is coordinated through `stopped` so a fast attach→detach
/// can't leak an enabled tap or a spinning run loop, and every Carbon
/// hotkey call is marshaled to the main thread (HIToolbox is not thread-safe).
public final class SystemTriggers: TriggerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var mouseHandler: (@Sendable (TapEvent) -> Void)?
    private var hotkeyCallback: (@Sendable () -> Void)?
    /// True once detach() has begun: the tap thread bails instead of entering
    /// its run loop, the tap callback stops re-enabling, and a queued hotkey
    /// install skips.
    private var stopped = true

    public enum TriggerError: Error, LocalizedError {
        case tapCreationFailed

        public var errorDescription: String? {
            "The global click listener could not be created. Grant Input Monitoring in System Settings and relaunch."
        }
    }

    public init() {}

    public func attach(
        mouse: @escaping @Sendable (TapEvent) -> Void,
        hotkey: (@Sendable () -> Void)?
    ) throws {
        lock.lock()
        mouseHandler = mouse
        hotkeyCallback = hotkey
        stopped = false
        let needTap = tap == nil
        // Guard on BOTH refs so a prior failed RegisterEventHotKey (which left
        // a handler but no ref) can't orphan a second handler on re-attach.
        let needHotkey = hotkey != nil && hotKeyRef == nil && hotKeyHandler == nil
        if needTap {
            do {
                try startTapLocked()
            } catch {
                lock.unlock()
                throw error
            }
        }
        lock.unlock()
        if needHotkey {
            // Carbon on the main thread; FIFO-ordered against detach's uninstall.
            DispatchQueue.main.async { [weak self] in self?.installHotkey() }
        }
    }

    public func detach() {
        lock.lock()
        mouseHandler = nil
        hotkeyCallback = nil
        stopped = true
        let tap = self.tap
        let source = self.runLoopSource
        let runLoop = self.tapRunLoop
        self.tap = nil
        self.runLoopSource = nil
        self.tapRunLoop = nil
        self.tapThread = nil
        lock.unlock()

        // Tap teardown is synchronous (no Carbon): disable immediately so no
        // further events deliver, then stop the run loop the thread is in. If
        // the thread hasn't published its run loop yet (runLoop == nil),
        // `stopped` makes it bail on startup without entering the loop.
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        // Carbon hotkey teardown on main, queued AFTER any pending install so
        // it reads the stored refs (FIFO).
        DispatchQueue.main.async { [weak self] in self?.uninstallHotkey() }
    }

    // MARK: - Event tap

    /// Precondition: `lock` is held by the caller.
    private func startTapLocked() throws {
        // MOUSE-DOWN ONLY. Keyboard types would change the TCC class.
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<SystemTriggers>.fromOpaque(refcon!).takeUnretainedValue()
                me.handleTapEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            throw TriggerError.tapCreationFailed
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        // Dedicated thread so a busy main thread can't starve the tap into
        // kCGEventTapDisabledByTimeout. The captured `tap`/`source` locals
        // avoid unlocked reads of the instance fields.
        let thread = Thread { [weak self] in
            guard let self else { return }
            // Publish this thread's run loop under the lock — but only if a
            // detach hasn't already run; otherwise disable the tap and bail so
            // no enabled tap / spinning run loop leaks.
            let shouldRun: Bool = self.lock.withLock {
                if self.stopped { return false }
                self.tapRunLoop = CFRunLoopGetCurrent()
                return true
            }
            guard shouldRun else {
                CGEvent.tapEnable(tap: tap, enable: false)
                return
            }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        thread.name = "shotAI.clickTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    /// Runs on the tap thread. Must never block: copy fields, hand off, return.
    private func handleTapEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // One slow moment must not permanently kill click capture — but if
            // detach has begun, DON'T re-enable a tap it just disabled (and
            // read the port under the lock, not racing detach's nil-store).
            let tap = lock.withLock { self.stopped ? nil : self.tap }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let button: MouseButton
        switch type {
        case .leftMouseDown:
            button = .left
        case .rightMouseDown:
            button = .right
        case .otherMouseDown:
            // buttonNumber 2 = middle; anything past that = 'other'.
            button = event.getIntegerValueField(.mouseEventButtonNumber) == 2 ? .middle : .other
        default:
            return
        }
        // CGEvent.location is global TOP-LEFT points — the pipeline's space.
        let handler = lock.withLock { mouseHandler }
        handler?(TapEvent(location: event.location, button: button))
    }

    // MARK: - Hotkey (⌘⇧S — parity with CommandOrControl+Shift+S)
    // All of these run on the MAIN thread (HIToolbox is not thread-safe) and
    // are FIFO-ordered on the main queue, so an install can't reorder past its
    // own uninstall.

    private func installHotkey() {
        // Skip if a detach landed first, or something already installed.
        let proceed = lock.withLock { !stopped && hotKeyRef == nil && hotKeyHandler == nil }
        guard proceed else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef?
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, userData in
                let me = Unmanaged<SystemTriggers>.fromOpaque(userData!).takeUnretainedValue()
                let cb = me.lock.withLock { me.hotkeyCallback }
                cb?()
                return noErr
            },
            1, &spec, refcon, &handlerRef
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_4F54) /* 'SHOT' */, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_S),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        lock.lock()
        // Registration failure is tolerated silently, as on Windows — but tear
        // down the handler so a later attach can retry cleanly (no orphan).
        hotKeyHandler = handlerRef
        hotKeyRef = status == noErr ? ref : nil
        lock.unlock()
        if status != noErr, let handlerRef {
            RemoveEventHandler(handlerRef)
            lock.withLock { hotKeyHandler = nil }
        }
    }

    private func uninstallHotkey() {
        let (ref, handler): (EventHotKeyRef?, EventHandlerRef?) = lock.withLock {
            let r = hotKeyRef
            let h = hotKeyHandler
            hotKeyRef = nil
            hotKeyHandler = nil
            return (r, h)
        }
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
