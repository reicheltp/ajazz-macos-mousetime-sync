//go:build darwin

// Package guard suppresses phantom HID input from an AJAZZ receiver.
//
// The receiver publishes keyboard and consumer-control interfaces in addition
// to the mouse. In 2.4 GHz mode those interfaces occasionally emit reports the
// user never asked for, which macOS faithfully turns into keystrokes and system
// actions — a stray Consumer "AL Control Panel" (0x019f), for example, is
// exactly what opening System Settings by itself looks like.
//
// There is no way to ask macOS to ignore one HID interface, but IOKit will let a
// process claim a device exclusively. Guard opens those interfaces with
// kIOHIDOptionsTypeSeizeDevice, which routes their input to this process
// instead of the window server: the phantom events are logged and go nowhere.
// The mouse interface is never claimed, so pointing keeps working.
//
// Seizing requires Input Monitoring permission (System Settings → Privacy &
// Security → Input Monitoring) for the binary that calls Run.
package guard

/*
#cgo LDFLAGS: -framework IOKit -framework CoreFoundation
#include "guard.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
)

// Event is a single HID value change observed on a guarded interface. When
// Options.DryRun is false, macOS never sees it.
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
	Seized    bool // false means the open failed — usually a missing permission
}

// Options selects which interfaces to claim.
type Options struct {
	// VendorID, when non-zero, is accepted in addition to a name match.
	VendorID int
	// Keyboard claims interfaces whose primary usage is Keyboard or Keypad.
	Keyboard bool
	// Consumer claims interfaces on the Consumer usage page (media and
	// application-launch keys).
	Consumer bool
	// DryRun observes without claiming: events are logged and still reach
	// macOS. Useful to confirm the diagnosis before changing behaviour.
	DryRun bool
}

// Handlers receive callbacks from the IOKit run loop.
type Handlers struct {
	OnEvent  func(Event)
	OnDevice func(Device)
}

var (
	mu      sync.Mutex
	running bool
	active  Handlers
)

// ErrBusy is returned when Run is called while another Run is in progress.
var ErrBusy = errors.New("guard already running")

// Run claims the matching interfaces and blocks until Stop is called.
//
// It pins itself to an OS thread because it drives a CFRunLoop, which is
// thread-local.
func Run(opts Options, h Handlers) error {
	mu.Lock()
	if running {
		mu.Unlock()
		return ErrBusy
	}
	running = true
	active = h
	mu.Unlock()

	defer func() {
		mu.Lock()
		running = false
		active = Handlers{}
		mu.Unlock()
	}()

	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	rc := C.mt_guard_run(
		C.int(opts.VendorID),
		cbool(opts.Keyboard),
		cbool(opts.Consumer),
		cbool(opts.DryRun),
	)
	if rc != 0 {
		return fmt.Errorf("IOHIDManager failed (IOReturn 0x%08x); "+
			"grant Input Monitoring permission and try again", uint32(rc))
	}
	return nil
}

// Stop unblocks a running Run.
func Stop() {
	C.mt_guard_stop()
}

func cbool(b bool) C.int {
	if b {
		return 1
	}
	return 0
}

func handlers() Handlers {
	mu.Lock()
	defer mu.Unlock()
	return active
}

//export mtGuardEvent
func mtGuardEvent(vendorID, productID, usagePage, usage, value C.int) {
	if fn := handlers().OnEvent; fn != nil {
		fn(Event{
			VendorID:  uint16(vendorID),
			ProductID: uint16(productID),
			UsagePage: uint16(usagePage),
			Usage:     uint16(usage),
			Value:     int(value),
		})
	}
}

//export mtGuardDevice
func mtGuardDevice(vendorID, productID, usagePage, usage C.int, product *C.char, seized C.int) {
	if fn := handlers().OnDevice; fn != nil {
		fn(Device{
			VendorID:  uint16(vendorID),
			ProductID: uint16(productID),
			UsagePage: uint16(usagePage),
			Usage:     uint16(usage),
			Product:   C.GoString(product),
			Seized:    seized != 0,
		})
	}
}
