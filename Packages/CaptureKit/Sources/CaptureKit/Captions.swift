import Foundation
import ShotModel

/// Auto-caption builder, byte-identical to the Windows strings so captions and
/// the Claude prompt read the same across platforms (controlType is persisted
/// in the Windows UIA vocabulary; see ElementLocator's role mapping).

/// UIA control type → friendly noun; "" = omitted (no trailing space).
public func controlWord(_ controlType: String?) -> String {
    switch controlType {
    case "Button", "SplitButton": "button"
    case "Hyperlink": "link"
    case "CheckBox": "checkbox"
    case "RadioButton": "option"
    case "Tab", "TabItem": "tab"
    case "Edit": "field"
    case "ComboBox": "dropdown"
    case "ListItem", "TreeItem", "DataItem": "item"
    case "Slider": "slider"
    case "Spinner": "spinner"
    default: ""
    }
}

public func buildClickCaption(
    button: MouseButton,
    isMenuSelect: Bool,
    appName: String,
    element: StepElement?
) -> String {
    if let name = element?.name, !name.isEmpty {
        // Only call it a menu selection when the clicked element really IS a
        // menu item — the proximity gate sometimes flags a click in a dialog
        // the menu opened (e.g. an OK button); caption the actual control.
        if element?.controlType == "MenuItem" {
            return "Select '\(name)' in \(appName)"
        }
        let word = controlWord(element?.controlType)
        let tail = word.isEmpty ? "" : " \(word)"
        return button == .right
            ? "Right-click '\(name)'\(tail) in \(appName)"
            : "Click '\(name)'\(tail) in \(appName)"
    }
    if button == .right { return "Right-click in \(appName)" }
    if isMenuSelect { return "Select from context menu in \(appName)" }
    return "Click in \(appName)"
}

public func buildHotkeyCaption(windowTitle: String?) -> String {
    "Capture: \(windowTitle ?? "screen")"
}

/// Caption for a click-less "insert a screenshot here" capture (area / window /
/// screen). No clicked element, so it just names what was captured; the user
/// edits it inline as needed.
public func buildManualCaption(mode: CaptureMode, windowTitle: String?) -> String {
    switch mode {
    case .area: return "Area screenshot"
    case .screen: return "Screen screenshot"
    case .window:
        if let t = windowTitle, !t.isEmpty { return "Screenshot of \(t)" }
        return "Window screenshot"
    case .auto: return buildHotkeyCaption(windowTitle: windowTitle)
    }
}
