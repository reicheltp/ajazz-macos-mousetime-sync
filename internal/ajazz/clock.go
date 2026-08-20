package ajazz

import (
	"errors"
	"fmt"
	"time"
)

// Wire format of the "set clock" command.
//
// The dock accepts a 64-byte HID *feature* report on its vendor-specific
// interface. Byte 0 is the HID report ID and is part of the transferred buffer
// (hidapi on macOS forwards the whole slice when the report ID is non-zero, so
// the layout below is byte-for-byte what reaches the device):
//
//	0     report ID          0x28
//	1..6  zero
//	7     opcode             0xd7  (set date/time)
//	8..9  year, big endian   e.g. 0x07 0xea for 2026
//	10    month              1-12
//	11    day                1-31
//	12    hour               0-23
//	13    minute             0-59
//	14    second             0-59
//	15..63 zero
//
// The dock keeps no battery-backed RTC, so it comes up at 2001-01-01 00:00 and
// stays there until something tells it the time. The official Windows driver
// sends this report on connect; nothing on macOS does, which is the entire
// reason this program exists.
const (
	clockReportID   = 0x28
	clockOpcode     = 0xd7
	clockReportSize = 64

	offOpcode = 7
	offYear   = 8
	offMonth  = 10
	offDay    = 11
	offHour   = 12
	offMinute = 13
	offSecond = 14
)

// ClockReport builds the set-clock feature report for t. t is used in its own
// location, so pass a local time — the dock displays exactly what it is given.
func ClockReport(t time.Time) []byte {
	p := make([]byte, clockReportSize)
	p[0] = clockReportID
	p[offOpcode] = clockOpcode
	year := t.Year()
	p[offYear] = byte(year >> 8)
	p[offYear+1] = byte(year)
	p[offMonth] = byte(t.Month())
	p[offDay] = byte(t.Day())
	p[offHour] = byte(t.Hour())
	p[offMinute] = byte(t.Minute())
	p[offSecond] = byte(t.Second())
	return p
}

// SyncResult records the outcome of one interface attempt.
type SyncResult struct {
	Iface Iface
	Err   error // nil means the interface accepted the report
}

// ErrNoDevice is returned when no interface matched.
var ErrNoDevice = errors.New("no AJAZZ dock interface found")

// SyncClock sends the current time to every interface accepted by match and
// returns one result per interface.
//
// Every interface is tried rather than guessing which one is vendor-specific:
// the mouse and keyboard interfaces simply reject the report, and which
// interface number carries the control channel differs between firmware
// revisions. At least one success means the dock's clock was set.
func SyncClock(match Match, now time.Time) ([]SyncResult, error) {
	ifaces, err := Enumerate(match)
	if err != nil {
		return nil, err
	}
	if len(ifaces) == 0 {
		return nil, ErrNoDevice
	}

	report := ClockReport(now)
	results := make([]SyncResult, 0, len(ifaces))
	for _, i := range ifaces {
		results = append(results, SyncResult{Iface: i, Err: sendClock(i, report)})
	}
	return results, nil
}

func sendClock(i Iface, report []byte) error {
	d, err := Open(i)
	if err != nil {
		return err
	}
	defer d.Close()

	if _, err := d.SendFeatureReport(report); err != nil {
		return fmt.Errorf("send feature report: %w", err)
	}
	return nil
}

// AnyOK reports whether at least one interface accepted the report.
func AnyOK(results []SyncResult) bool {
	for _, r := range results {
		if r.Err == nil {
			return true
		}
	}
	return false
}
