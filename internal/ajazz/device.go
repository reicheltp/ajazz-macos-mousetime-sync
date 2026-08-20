// Package ajazz talks to AJAZZ mice and their 2.4 GHz "smart dock" receivers
// over USB HID.
package ajazz

import (
	"fmt"
	"strings"

	"github.com/sstallion/go-hid"
)

// VendorID is the USB vendor ID AJAZZ ships its wireless receivers under.
// Product IDs vary per model and per firmware revision, so we never match on
// them; see Match.
const VendorID = 0x249a

// Iface is one HID interface exposed by a device. A single AJAZZ receiver
// publishes several: a mouse, one or more keyboard/consumer interfaces, and a
// vendor-specific one that carries the control protocol.
type Iface struct {
	Path      string
	VendorID  uint16
	ProductID uint16
	Mfr       string
	Product   string
	Serial    string
	UsagePage uint16
	Usage     uint16
	Interface int
	Bus       hid.BusType
}

func (i Iface) String() string {
	return fmt.Sprintf("%04x:%04x if=%d usage=%s %q %q",
		i.VendorID, i.ProductID, i.Interface, UsageName(i.UsagePage, i.Usage),
		i.Mfr, i.Product)
}

// IsAjazz reports whether an interface belongs to AJAZZ hardware. The vendor ID
// alone is not enough: some units report a white-label VID, and the descriptive
// strings are the only stable marker across firmware revisions.
func IsAjazz(i Iface) bool {
	if i.VendorID == VendorID {
		return true
	}
	return strings.Contains(strings.ToUpper(i.Mfr+" "+i.Product), "AJAZZ")
}

// IsDock reports whether an interface belongs to the 2.4 GHz receiver dock —
// the part with the display. The dock identifies itself with a product string
// like "AJAZZ 2.4G 8K"; the mouse's own wired interface does not carry "2.4G",
// which is how we tell the two apart without hardcoding product IDs.
func IsDock(i Iface) bool {
	up := strings.ToUpper(i.Product)
	return IsAjazz(i) && strings.Contains(up, "2.4G")
}

// Match is a predicate over interfaces, used to scope every command.
type Match func(Iface) bool

// Enumerate returns every HID interface accepted by match, in enumeration
// order. A nil match returns everything.
func Enumerate(match Match) ([]Iface, error) {
	if err := hid.Init(); err != nil {
		return nil, fmt.Errorf("hid init: %w", err)
	}
	var out []Iface
	err := hid.Enumerate(hid.VendorIDAny, hid.ProductIDAny, func(info *hid.DeviceInfo) error {
		i := Iface{
			Path:      info.Path,
			VendorID:  info.VendorID,
			ProductID: info.ProductID,
			Mfr:       info.MfrStr,
			Product:   info.ProductStr,
			Serial:    info.SerialNbr,
			UsagePage: info.UsagePage,
			Usage:     info.Usage,
			Interface: info.InterfaceNbr,
			Bus:       info.BusType,
		}
		if match == nil || match(i) {
			out = append(out, i)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("hid enumerate: %w", err)
	}
	return out, nil
}

// Open opens a single interface by its platform path.
func Open(i Iface) (*hid.Device, error) {
	d, err := hid.OpenPath(i.Path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", i.Path, err)
	}
	return d, nil
}
