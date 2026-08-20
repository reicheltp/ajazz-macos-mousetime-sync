package ajazz

import "fmt"

// HID usage pages we care about when diagnosing phantom input.
const (
	PageGenericDesktop = 0x01
	PageKeyboard       = 0x07
	PageLED            = 0x08
	PageButton         = 0x09
	PageConsumer       = 0x0c
	PageVendorFirst    = 0xff00
)

var pageNames = map[uint16]string{
	PageGenericDesktop: "GenericDesktop",
	0x02:               "Simulation",
	0x03:               "VR",
	0x04:               "Sport",
	0x05:               "Game",
	0x06:               "GenericDevice",
	PageKeyboard:       "Keyboard",
	PageLED:            "LED",
	PageButton:         "Button",
	0x0a:               "Ordinal",
	0x0b:               "Telephony",
	PageConsumer:       "Consumer",
	0x0d:               "Digitizer",
}

var desktopUsages = map[uint16]string{
	0x01: "Pointer", 0x02: "Mouse", 0x04: "Joystick", 0x05: "GamePad",
	0x06: "Keyboard", 0x07: "Keypad", 0x0e: "SystemMultiAxis",
	0x30: "X", 0x31: "Y", 0x38: "Wheel",
	0x80: "SystemControl", 0x81: "SystemPowerDown", 0x82: "SystemSleep",
	0x83: "SystemWakeUp", 0x84: "SystemContextMenu", 0x85: "SystemMainMenu",
}

// consumerUsages covers the entries macOS acts on. 0x019f in particular is the
// one to look for: macOS maps "AL Control Panel" straight to opening System
// Settings, which is the most likely source of a settings window appearing on
// its own.
var consumerUsages = map[uint16]string{
	0x0030: "Power", 0x0034: "Sleep",
	0x00b5: "ScanNextTrack", 0x00b6: "ScanPreviousTrack", 0x00b7: "Stop",
	0x00b8: "Eject", 0x00cd: "PlayPause",
	0x00e2: "Mute", 0x00e9: "VolumeUp", 0x00ea: "VolumeDown",
	0x0183: "AL ConsumerControlConfiguration",
	0x018a: "AL EmailReader", 0x0192: "AL Calculator",
	0x0194: "AL LocalMachineBrowser", 0x196: "AL InternetBrowser",
	0x019c: "AL LogOff", 0x019e: "AL TerminalLock",
	0x019f: "AL ControlPanel", // macOS: opens System Settings
	0x01a2: "AL TaskManager", 0x01a4: "AL ProgramBrowser",
	0x01ab: "AC SpellCheck", 0x01b6: "AL ImageBrowser", 0x01b7: "AL AudioBrowser",
	0x0201: "AC New", 0x0202: "AC Open", 0x0203: "AC Close", 0x0207: "AC Save",
	0x0208: "AC Print", 0x0221: "AC Search", 0x0223: "AC Home",
	0x0224: "AC Back", 0x0225: "AC Forward", 0x0226: "AC Stop",
	0x0227: "AC Refresh", 0x022a: "AC Bookmarks",
	0x0279: "AC Redo", 0x021a: "AC Undo", 0x021b: "AC Copy",
	0x021c: "AC Cut", 0x021d: "AC Paste",
	0x029f: "AC DesktopShowAllWindows", 0x02a0: "AC SoftKeyLeft",
}

// keyboardUsages maps HID Keyboard/Keypad page usages to readable names. Only
// the ranges that can plausibly show up as phantom input are named; anything
// else prints as a raw code.
var keyboardUsages = map[uint16]string{
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
	0xe0: "LeftCtrl", 0xe1: "LeftShift", 0xe2: "LeftAlt", 0xe3: "LeftGUI",
	0xe4: "RightCtrl", 0xe5: "RightShift", 0xe6: "RightAlt", 0xe7: "RightGUI",
}

// KeyName returns a readable name for a Keyboard-page usage.
func KeyName(usage uint16) string {
	if n, ok := keyboardUsages[usage]; ok {
		return n
	}
	switch {
	case usage >= 0x04 && usage <= 0x1d: // a..z
		return string(rune('a' + usage - 0x04))
	case usage >= 0x1e && usage <= 0x26: // 1..9
		return string(rune('1' + usage - 0x1e))
	case usage == 0x27:
		return "0"
	case usage >= 0x3a && usage <= 0x45: // F1..F12
		return fmt.Sprintf("F%d", usage-0x3a+1)
	case usage >= 0x68 && usage <= 0x73: // F13..F24
		return fmt.Sprintf("F%d", usage-0x68+13)
	case usage >= 0x54 && usage <= 0x63:
		return fmt.Sprintf("Keypad(0x%02x)", usage)
	}
	return fmt.Sprintf("0x%02x", usage)
}

// PageName returns a readable name for a usage page.
func PageName(page uint16) string {
	if n, ok := pageNames[page]; ok {
		return n
	}
	if page >= PageVendorFirst {
		return fmt.Sprintf("Vendor(0x%04x)", page)
	}
	return fmt.Sprintf("Page(0x%04x)", page)
}

// UsageName renders a page/usage pair the way HID documentation would.
func UsageName(page, usage uint16) string {
	var name string
	switch page {
	case PageGenericDesktop:
		name = desktopUsages[usage]
	case PageKeyboard:
		name = KeyName(usage)
	case PageConsumer:
		name = consumerUsages[usage]
	case PageButton:
		name = fmt.Sprintf("Button%d", usage)
	}
	if name == "" {
		return fmt.Sprintf("%s/0x%04x", PageName(page), usage)
	}
	return fmt.Sprintf("%s/%s", PageName(page), name)
}

// SuspectPhantom reports whether a page/usage pair is one that would visibly
// disturb a macOS session if a mouse emitted it — i.e. the symptoms worth
// chasing. Used to highlight lines in guard/sniff output.
func SuspectPhantom(page, usage uint16) bool {
	switch page {
	case PageKeyboard:
		// Anything on the keyboard page from a mouse is already wrong, but
		// modifiers and rollover errors are the usual noise.
		return usage > 0x03
	case PageConsumer:
		switch usage {
		case 0x019f, 0x0183, 0x0192, 0x0221, 0x0223, 0x01a2, 0x019e, 0x019c:
			return true
		}
	case PageGenericDesktop:
		switch usage {
		case 0x81, 0x82, 0x83, 0x84, 0x85: // power/sleep/menu
			return true
		}
	}
	return false
}
