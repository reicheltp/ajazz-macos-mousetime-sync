//go:build !darwin

package guard

import "errors"

// Event is a single HID value change observed on a guarded interface.
type Event struct {
	VendorID  uint16
	ProductID uint16
	UsagePage uint16
	Usage     uint16
	Value     int
}

// Device describes an interface Guard considered claiming.
type Device struct {
	VendorID  uint16
	ProductID uint16
	UsagePage uint16
	Usage     uint16
	Product   string
	Seized    bool
}

// Options selects which interfaces to claim.
type Options struct {
	VendorID int
	Keyboard bool
	Consumer bool
	DryRun   bool
}

// Handlers receive callbacks while guarding.
type Handlers struct {
	OnEvent  func(Event)
	OnDevice func(Device)
}

// ErrBusy is returned when Run is called while another Run is in progress.
var ErrBusy = errors.New("guard already running")

// ErrUnsupported is returned on platforms without an exclusive-open mechanism.
var ErrUnsupported = errors.New("guard is only implemented on macOS")

// Run is unsupported on this platform. On Linux, the equivalent is a udev/hwdb
// rule or a libinput quirk that ignores the offending interface.
func Run(Options, Handlers) error { return ErrUnsupported }

// Stop is a no-op on this platform.
func Stop() {}
