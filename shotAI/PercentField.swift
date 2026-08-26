import AppKit
import SwiftUI

/// A small numeric text field backed by `NSTextField`.
///
/// SwiftUI's `TextField` is deliberately NOT used here. Every key this control's
/// contract depends on — Return, Escape, ↑ and ↓ — reaches an editable text
/// field through AppKit's field editor, which handles them before a SwiftUI
/// `.onKeyPress` on the same view would see them. `control(_:textView:doCommandBy:)`
/// is the documented interception point for exactly those four selectors, so
/// this is the platform's own contract rather than a bet on modifier ordering.
///
/// It also buys the thing the Windows port got wrong: `cancelOperation` and
/// `controlTextDidEndEditing` are plain synchronous delegate callbacks on one
/// object, so "Escape already abandoned this" can be a stored flag that the
/// blur which follows is guaranteed to observe. With async state that ordering
/// is not guaranteed, and Escape saves the value it promised to discard.
struct PercentField: NSViewRepresentable {
    /// What to display. While a partial edit is buffered this is the draft, so
    /// it matches what is already on screen and nothing is written back.
    let text: String
    /// Mirrors first-responder state out so SwiftUI can draw the focus ring.
    @Binding var editing: Bool

    var onType: (String) -> Void
    var onStep: (Int) -> Void
    var onCommit: () -> Void
    var onAbandon: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.delegate = context.coordinator
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none          // SwiftUI draws the ring; see DocScaleControl
        f.alignment = .right
        f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        f.lineBreakMode = .byClipping
        f.cell?.usesSingleLineMode = true
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only write when it actually differs. A buffered draft equals what the
        // user typed, so typing never gets clobbered; a step or a snap does
        // differ, and should land even while the field is focused.
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PercentField
        /// Set by Escape immediately before resigning first responder, and read
        /// by the `controlTextDidEndEditing` that resigning triggers. Both run on
        /// the main thread in the same call stack, so the ordering holds.
        private var abandoning = false
        /// Guards the same double-fire for Return, which also ends editing.
        private var finishing = false

        init(_ p: PercentField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.onType(f.stringValue)
        }

        func controlTextDidBeginEditing(_ n: Notification) {
            abandoning = false
            finishing = false
            parent.editing = true
        }

        func controlTextDidEndEditing(_ n: Notification) {
            parent.editing = false
            defer { abandoning = false; finishing = false }
            if abandoning || finishing { return }
            parent.onCommit()
        }

        func control(_ c: NSControl, textView: NSTextView,
                     doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.moveUp(_:)):
                parent.onStep(+1); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onStep(-1); return true
            case #selector(NSResponder.insertNewline(_:)):
                finishing = true
                parent.onCommit()
                c.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                abandoning = true
                parent.onAbandon()
                c.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}
