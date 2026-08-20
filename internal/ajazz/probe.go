package ajazz

import (
	"fmt"
	"io"
	"strings"
	"time"
)

// Descriptor returns the raw HID report descriptor for an interface.
func Descriptor(i Iface) ([]byte, error) {
	d, err := Open(i)
	if err != nil {
		return nil, err
	}
	defer d.Close()

	buf := make([]byte, 4096)
	n, err := d.GetReportDescriptor(buf)
	if err != nil {
		return nil, fmt.Errorf("get report descriptor: %w", err)
	}
	return buf[:n], nil
}

// DescribeDescriptor walks a report descriptor and summarises the collections
// it declares. This is a deliberately shallow decode — enough to answer "does
// this interface claim to be a keyboard?", which is the question that matters
// when hunting phantom input.
func DescribeDescriptor(desc []byte) []string {
	var (
		out      []string
		page     uint16
		reportID byte
		indent   int
	)
	for p := 0; p < len(desc); {
		b := desc[p]
		p++
		// Long items are declared but never used in practice by these devices.
		if b == 0xfe {
			if p+1 >= len(desc) {
				break
			}
			p += 2 + int(desc[p])
			continue
		}
		size := int(b & 0x03)
		if size == 3 {
			size = 4
		}
		if p+size > len(desc) {
			break
		}
		var val uint32
		for k := 0; k < size; k++ {
			val |= uint32(desc[p+k]) << (8 * k)
		}
		p += size
		tag := b & 0xfc

		pad := strings.Repeat("  ", indent)
		switch tag {
		case 0x04: // Usage Page (global)
			page = uint16(val)
		case 0x08: // Usage (local)
			out = append(out, fmt.Sprintf("%sUsage %s", pad, UsageName(page, uint16(val))))
		case 0x84: // Report ID (global)
			reportID = byte(val)
			out = append(out, fmt.Sprintf("%sReport ID 0x%02x", pad, reportID))
		case 0xa0: // Collection
			kinds := map[uint32]string{0x00: "Physical", 0x01: "Application", 0x02: "Logical"}
			k := kinds[val]
			if k == "" {
				k = fmt.Sprintf("0x%02x", val)
			}
			out = append(out, fmt.Sprintf("%sCollection (%s)", pad, k))
			indent++
		case 0xc0: // End Collection
			if indent > 0 {
				indent--
			}
		case 0x80: // Input
			out = append(out, fmt.Sprintf("%sInput  (page %s)", strings.Repeat("  ", indent), PageName(page)))
		case 0x90: // Output
			out = append(out, fmt.Sprintf("%sOutput (page %s)", strings.Repeat("  ", indent), PageName(page)))
		case 0xb0: // Feature
			out = append(out, fmt.Sprintf("%sFeature(page %s)", strings.Repeat("  ", indent), PageName(page)))
		}
	}
	return out
}

// SniffOpts configures Sniff.
type SniffOpts struct {
	// Duration bounds the capture. Zero means run until the context of the
	// caller closes the device (i.e. forever).
	Duration time.Duration
	// PollTimeout is how long each read waits before checking whether the
	// overall Duration has elapsed.
	PollTimeout time.Duration
}

// Sniff reads input reports from one interface and writes an annotated hex log
// to w. It is the diagnostic half of the phantom-input problem: it shows what
// the dock actually emits, without suppressing it.
//
// Note that macOS only hands input reports to a userspace reader for interfaces
// it has not exclusively claimed. Keyboard and consumer interfaces generally
// need Input Monitoring permission, and even then the system consumes the
// events in parallel — use Guard when the goal is to stop them.
func Sniff(i Iface, w io.Writer, opts SniffOpts) error {
	if opts.PollTimeout <= 0 {
		opts.PollTimeout = 500 * time.Millisecond
	}

	d, err := Open(i)
	if err != nil {
		return err
	}
	defer d.Close()

	fmt.Fprintf(w, "sniffing %s\n", i)

	deadline := time.Time{}
	if opts.Duration > 0 {
		deadline = time.Now().Add(opts.Duration)
	}

	buf := make([]byte, 65)
	for {
		if !deadline.IsZero() && time.Now().After(deadline) {
			return nil
		}
		n, err := d.ReadWithTimeout(buf, opts.PollTimeout)
		if err != nil {
			return fmt.Errorf("read: %w", err)
		}
		if n == 0 {
			continue // timeout, nothing pending
		}
		fmt.Fprintf(w, "%s  % x\n", time.Now().Format("15:04:05.000"), buf[:n])
	}
}
