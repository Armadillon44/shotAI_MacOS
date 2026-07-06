import Testing
@testable import CaptureKit
import ShotModel

// Caption strings must stay byte-identical to the Windows builder.
@Suite struct CaptionsTests {
    private func element(_ name: String?, _ type: String?) -> StepElement {
        StepElement(available: name != nil, name: name, controlType: type, bounds: nil)
    }

    @Test func namedElementCaptions() {
        #expect(buildClickCaption(button: .left, isMenuSelect: false, appName: "Safari", element: element("OK", "Button"))
            == "Click 'OK' button in Safari")
        #expect(buildClickCaption(button: .right, isMenuSelect: false, appName: "Finder", element: element("report.docx", "ListItem"))
            == "Right-click 'report.docx' item in Finder")
        // Unknown control word → noun omitted, no trailing space.
        #expect(buildClickCaption(button: .left, isMenuSelect: false, appName: "App", element: element("Orders table", "Table"))
            == "Click 'Orders table' in App")
    }

    @Test func menuItemWinsOverEverything() {
        // Even a right-click or misfired proximity gate captions the real
        // control when it IS a menu item.
        #expect(buildClickCaption(button: .right, isMenuSelect: false, appName: "Finder", element: element("Rename", "MenuItem"))
            == "Select 'Rename' in Finder")
        #expect(buildClickCaption(button: .left, isMenuSelect: true, appName: "Finder", element: element("Rename", "MenuItem"))
            == "Select 'Rename' in Finder")
    }

    @Test func namelessCaptions() {
        #expect(buildClickCaption(button: .right, isMenuSelect: false, appName: "Notes", element: nil)
            == "Right-click in Notes")
        #expect(buildClickCaption(button: .left, isMenuSelect: true, appName: "Notes", element: .unavailable)
            == "Select from context menu in Notes")
        #expect(buildClickCaption(button: .left, isMenuSelect: false, appName: "Notes", element: nil)
            == "Click in Notes")
    }

    @Test func controlWordTable() {
        let expected: [(String, String)] = [
            ("Button", "button"), ("SplitButton", "button"), ("Hyperlink", "link"),
            ("CheckBox", "checkbox"), ("RadioButton", "option"), ("Tab", "tab"),
            ("TabItem", "tab"), ("Edit", "field"), ("ComboBox", "dropdown"),
            ("ListItem", "item"), ("TreeItem", "item"), ("DataItem", "item"),
            ("Slider", "slider"), ("Spinner", "spinner"),
            ("MenuItem", ""), ("Text", ""), ("Unknown", ""),
        ]
        for (type, word) in expected {
            #expect(controlWord(type) == word, "controlWord(\(type))")
        }
        #expect(controlWord(nil) == "")
    }

    @Test func hotkeyCaption() {
        #expect(buildHotkeyCaption(windowTitle: "Orders — Chrome") == "Capture: Orders — Chrome")
        #expect(buildHotkeyCaption(windowTitle: nil) == "Capture: screen")
    }
}
