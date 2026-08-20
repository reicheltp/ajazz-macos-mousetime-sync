import Foundation

/// Readable names for HID usage pages and usages.
///
/// This exists to make diagnostics legible. When a mouse produces a keystroke
/// nobody typed, the only useful evidence is which page and usage it arrived
/// on, and raw hex is hard to reason about.
public enum HIDUsage {
    // Usage pages, from the HID Usage Tables.
    public static let genericDesktopPage = 0x01
    public static let keyboardPage = 0x07
    public static let ledPage = 0x08
    public static let buttonPage = 0x09
    public static let consumerPage = 0x0c
    /// Pages at or above this value are vendor-defined. The dock's control
    /// channel lives on one of them.
    public static let vendorPageFloor = 0xff00

    // Generic Desktop usages that identify what an interface claims to be.
    public static let pointerUsage = 0x01
    public static let mouseUsage = 0x02
    public static let keyboardUsage = 0x06
    public static let keypadUsage = 0x07

    private static let pageNames: [Int: String] = [
        0x01: "GenericDesktop", 0x02: "Simulation", 0x03: "VR", 0x04: "Sport",
        0x05: "Game", 0x06: "GenericDevice", 0x07: "Keyboard", 0x08: "LED",
        0x09: "Button", 0x0a: "Ordinal", 0x0b: "Telephony", 0x0c: "Consumer",
        0x0d: "Digitizer",
    ]

    private static let desktopUsages: [Int: String] = [
        0x01: "Pointer", 0x02: "Mouse", 0x04: "Joystick", 0x05: "GamePad",
        0x06: "Keyboard", 0x07: "Keypad", 0x0e: "SystemMultiAxis",
        0x30: "X", 0x31: "Y", 0x38: "Wheel",
        0x80: "SystemControl", 0x81: "SystemPowerDown", 0x82: "SystemSleep",
        0x83: "SystemWakeUp", 0x84: "SystemContextMenu", 0x85: "SystemMainMenu",
    ]

    /// Consumer-page entries macOS acts on.
    ///
    /// `0x019f` is the one to watch for: macOS maps "AL Control Panel" straight
    /// to opening System Settings, which is what a settings window appearing by
    /// itself looks like from the outside. `0x0224`/`0x0225` matter for the
    /// opposite reason — those are legitimate browser back/forward, so if the
    /// mouse's side buttons arrive here they must not be filtered away.
    private static let consumerUsages: [Int: String] = [
        0x0030: "Power", 0x0034: "Sleep",
        0x00b5: "ScanNextTrack", 0x00b6: "ScanPreviousTrack", 0x00b7: "Stop",
        0x00b8: "Eject", 0x00cd: "PlayPause",
        0x00e2: "Mute", 0x00e9: "VolumeUp", 0x00ea: "VolumeDown",
        0x0183: "AL ConsumerControlConfiguration",
        0x018a: "AL EmailReader", 0x0192: "AL Calculator",
        0x0194: "AL LocalMachineBrowser", 0x0196: "AL InternetBrowser",
        0x019c: "AL LogOff", 0x019e: "AL TerminalLock",
        0x019f: "AL ControlPanel",
        0x01a2: "AL TaskManager", 0x01a4: "AL ProgramBrowser",
        0x01b6: "AL ImageBrowser", 0x01b7: "AL AudioBrowser",
        0x0201: "AC New", 0x0202: "AC Open", 0x0203: "AC Close",
        0x0207: "AC Save", 0x0208: "AC Print",
        0x021a: "AC Undo", 0x021b: "AC Copy", 0x021c: "AC Cut", 0x021d: "AC Paste",
        0x0221: "AC Search", 0x0223: "AC Home",
        0x0224: "AC Back", 0x0225: "AC Forward", 0x0226: "AC Stop",
        0x0227: "AC Refresh", 0x022a: "AC Bookmarks",
        0x0279: "AC Redo",
        0x029f: "AC DesktopShowAllWindows",
    ]

    private static let keyboardUsages: [Int: String] = [
        0x00: "None", 0x01: "ErrorRollOver", 0x02: "POSTFail", 0x03: "ErrorUndefined",
        0x28: "Return", 0x29: "Escape", 0x2a: "Backspace", 0x2b: "Tab", 0x2c: "Space",
        0x2d: "-", 0x2e: "=", 0x2f: "[", 0x30: "]", 0x31: "\\",
        0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/",
        0x39: "CapsLock",
        0x46: "PrintScreen", 0x47: "ScrollLock", 0x48: "Pause",
        0x49: "Insert", 0x4a: "Home", 0x4b: "PageUp", 0x4c: "Delete",
        0x4d: "End", 0x4e: "PageDown",
        0x4f: "Right", 0x50: "Left", 0x51: "Down", 0x52: "Up",
        0x65: "Application", 0x66: "Power",
        0xe0: "LeftCtrl", 0xe1: "LeftShift", 0xe2: "LeftAlt", 0xe3: "LeftCmd",
        0xe4: "RightCtrl", 0xe5: "RightShift", 0xe6: "RightAlt", 0xe7: "RightCmd",
    ]

    /// A readable name for a usage page.
    public static func pageName(_ page: Int) -> String {
        if let name = pageNames[page] { return name }
        if page >= vendorPageFloor { return String(format: "Vendor(0x%04x)", page) }
        return String(format: "Page(0x%04x)", page)
    }

    /// A readable name for a Keyboard/Keypad-page usage.
    public static func keyName(_ usage: Int) -> String {
        if let name = keyboardUsages[usage] { return name }
        switch usage {
        case 0x04...0x1d:
            return String(UnicodeScalar(UInt8(0x61 + usage - 0x04)))  // a...z
        case 0x1e...0x26:
            return String(UnicodeScalar(UInt8(0x31 + usage - 0x1e)))  // 1...9
        case 0x27:
            return "0"
        case 0x3a...0x45:
            return "F\(usage - 0x3a + 1)"
        case 0x68...0x73:
            return "F\(usage - 0x68 + 13)"
        case 0x54...0x63:
            return String(format: "Keypad(0x%02x)", usage)
        default:
            return String(format: "0x%02x", usage)
        }
    }

    /// Renders a page/usage pair the way HID documentation would.
    public static func name(page: Int, usage: Int) -> String {
        let specific: String?
        switch page {
        case genericDesktopPage: specific = desktopUsages[usage]
        case keyboardPage: specific = keyName(usage)
        case consumerPage: specific = consumerUsages[usage]
        case buttonPage: specific = "Button\(usage)"
        default: specific = nil
        }
        guard let specific else {
            return String(format: "%@/0x%04x", pageName(page), usage)
        }
        return "\(pageName(page))/\(specific)"
    }
}
