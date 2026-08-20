package ajazz

import (
	"testing"
	"time"
)

// TestClockReportLayout pins the wire format byte-for-byte. The dock silently
// ignores a malformed report, so a regression here would look like "the clock
// just stopped working" with no error to go on.
func TestClockReportLayout(t *testing.T) {
	// 2026-08-20 14:37:09 local. 2026 = 0x07ea.
	got := ClockReport(time.Date(2026, time.August, 20, 14, 37, 9, 0, time.Local))

	if len(got) != 64 {
		t.Fatalf("report length = %d, want 64", len(got))
	}

	want := map[int]byte{
		0:  0x28, // report ID
		7:  0xd7, // set date/time
		8:  0x07, // year high
		9:  0xea, // year low
		10: 8,    // month
		11: 20,   // day
		12: 14,   // hour
		13: 37,   // minute
		14: 9,    // second
	}
	for off, w := range want {
		if got[off] != w {
			t.Errorf("byte %d = 0x%02x, want 0x%02x", off, got[off], w)
		}
	}

	for i, b := range got {
		if _, set := want[i]; set {
			continue
		}
		if b != 0 {
			t.Errorf("byte %d = 0x%02x, want zero padding", i, b)
		}
	}
}

func TestClockReportMidnight(t *testing.T) {
	// Midnight and January exercise the zero-vs-one-based fields: hour and
	// second are zero-based, month and day are one-based.
	got := ClockReport(time.Date(2001, time.January, 1, 0, 0, 0, 0, time.Local))
	if got[offMonth] != 1 || got[offDay] != 1 {
		t.Errorf("month/day = %d/%d, want 1/1", got[offMonth], got[offDay])
	}
	if got[offHour] != 0 || got[offMinute] != 0 || got[offSecond] != 0 {
		t.Errorf("time = %d:%d:%d, want 0:0:0", got[offHour], got[offMinute], got[offSecond])
	}
	if got[offYear] != 0x07 || got[offYear+1] != 0xd1 { // 2001 = 0x07d1
		t.Errorf("year = 0x%02x%02x, want 0x07d1", got[offYear], got[offYear+1])
	}
}

func TestIsDock(t *testing.T) {
	tests := []struct {
		name  string
		iface Iface
		ajazz bool
		dock  bool
	}{
		{"dock by name", Iface{Mfr: "AJAZZ", Product: "AJAZZ 2.4G 8K"}, true, true},
		{"dock lowercase", Iface{Product: "ajazz 2.4g 8k receiver"}, true, true},
		{"wired mouse", Iface{VendorID: VendorID, Product: "AJ159 APEX"}, true, false},
		{"vid only", Iface{VendorID: VendorID}, true, false},
		{"ajazz keyboard", Iface{Product: "AJAZZ AK820MAX"}, true, false},
		{"unrelated", Iface{VendorID: 0x05ac, Product: "Magic Trackpad"}, false, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := IsAjazz(tc.iface); got != tc.ajazz {
				t.Errorf("IsAjazz = %t, want %t", got, tc.ajazz)
			}
			if got := IsDock(tc.iface); got != tc.dock {
				t.Errorf("IsDock = %t, want %t", got, tc.dock)
			}
		})
	}
}

func TestSuspectPhantom(t *testing.T) {
	// 0x019f is the prime suspect: macOS turns Consumer "AL Control Panel"
	// into "open System Settings".
	if !SuspectPhantom(PageConsumer, 0x019f) {
		t.Error("Consumer/AL ControlPanel should be flagged")
	}
	if !SuspectPhantom(PageKeyboard, 0x04) {
		t.Error("any real keypress from a mouse should be flagged")
	}
	if SuspectPhantom(PageKeyboard, 0x01) {
		t.Error("ErrorRollOver is noise, not a phantom keypress")
	}
	if SuspectPhantom(PageButton, 1) {
		t.Error("mouse buttons are expected input")
	}
}

func TestUsageName(t *testing.T) {
	tests := []struct {
		page, usage uint16
		want        string
	}{
		{PageConsumer, 0x019f, "Consumer/AL ControlPanel"},
		{PageKeyboard, 0x04, "Keyboard/a"},
		{PageKeyboard, 0x3a, "Keyboard/F1"},
		{PageKeyboard, 0x27, "Keyboard/0"},
		{PageGenericDesktop, 0x02, "GenericDesktop/Mouse"},
		{0xff00, 0x01, "Vendor(0xff00)/0x0001"},
	}
	for _, tc := range tests {
		if got := UsageName(tc.page, tc.usage); got != tc.want {
			t.Errorf("UsageName(%#x, %#x) = %q, want %q", tc.page, tc.usage, got, tc.want)
		}
	}
}
