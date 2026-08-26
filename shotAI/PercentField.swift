import AppKit
import SwiftUI

/// A small numeric text field backed by `NSTextField`.
///
/// SwiftUI's `TextField` is deliberately NOT used here. Every key this control's
/// contract depends on — Return, Escape, ↑ and ↓ — reaches an editable text
/// field through AppKit's field editor, which handles them before a SwiftUI
/// `.onKeyPress` on the same view would see them.
/// `control(_:textView:doCommandBy:)` is the documented interception point for
/// exactly those four selectors.
///
/// It also buys the thing the Windows port got wrong: `cancelOperation` and
/// `controlTextDidEndEditing` are plain synchronous delegate callbacks on one
/// object, so "Escape already abandoned this" can be a stored flag that any
/// blur which follows is guaranteed to observe.
struct PercentField: NSViewRepresentable {
    /// What to display. While a partial edit is buffered this IS the draft, so
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
        // Only write when it actually differs.
        //
        // This is why `DocScaleControl.typed` must never shorten what the user
        // typed: whatever it stores comes straight back here, and a write into a
        // live field editor DELETES the keystroke that has not been processed
        // yet. A 3-character truncation here made the field uneditable at any
        // value from 100% up — every keystroke was eaten and the old value
        // re-applied.
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PercentField
        /// Set by Escape and read by any `controlTextDidEndEditing` that follows,
        /// so an abandoned edit cannot be committed by the blur behind it. Reset
        /// as soon as the user types again — otherwise Escape, then more typing,
        /// then a click away would silently discard the second edit too.
        private var abandoning = false
        /// Same guard for Return, which also commits.
        private var finishing = false

        init(_ p: PercentField) { parent = p }

        func controlTextDidChange(_ n: Notification) {
            abandoning = false
            finishing = false
            guard let f = n.object as? NSTextField else { return }
            parent.onType(f.stringValue)
        }

        func controlTextDidBeginEditing(_ n: Notification) {
            abandoning = false
            finishing = false
            parent.editing = true
            // Select all on focus. The field is 3 characters wide and its whole
            // purpose is replacing one number with another, so a click that
            // parked a caret mid-value and left the user typing "1|00" was never
            // the intent.
            (n.object as? NSTextField)?.currentEditor()?.selectAll(nil)
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
                // KEEP focus. Standard NSTextField behaviour is to commit in
                // place, and dropping first responder here would make the
                // contract's "arrow key applies immediately" unreachable for a
                // second adjustment without going back to the mouse — ↑ would
                // fall through to the report and scroll it instead.
                finishing = true
                parent.onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                abandoning = true
                parent.onAbandon()
                return true
            default:
                return false
            }
        }
    }
}
