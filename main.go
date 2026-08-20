// Command mousetime keeps the clock on an AJAZZ AJ159 APEX smart dock in sync
// with macOS, and suppresses the phantom keyboard input the receiver emits in
// 2.4 GHz mode.
//
// Run "mousetime" with no arguments for usage.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"mousetime/internal/ajazz"
	"mousetime/internal/guard"
)

const usage = `mousetime — AJAZZ AJ159 APEX dock support for macOS

Usage:
  mousetime list                 list AJAZZ HID interfaces (-all for every device)
  mousetime sync                 set the dock clock to the current local time once
  mousetime daemon               keep the clock synced; run this from launchd
  mousetime descriptor           dump each interface's HID report descriptor
  mousetime sniff                log raw input reports from an interface
  mousetime guard                claim the phantom keyboard/consumer interfaces
  mousetime version              print version

Run "mousetime <command> -h" for command flags.
`

var version = "dev"

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	cmd, args := os.Args[1], os.Args[2:]
	var err error
	switch cmd {
	case "list":
		err = cmdList(args)
	case "sync":
		err = cmdSync(args)
	case "daemon":
		err = cmdDaemon(args)
	case "descriptor", "desc":
		err = cmdDescriptor(args)
	case "sniff":
		err = cmdSniff(args)
	case "guard":
		err = cmdGuard(args)
	case "version", "-v", "--version":
		fmt.Println("mousetime", version)
	case "help", "-h", "--help":
		fmt.Print(usage)
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", cmd, usage)
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

// matchFlags installs the interface-selection flags shared by most commands and
// returns a function that resolves them into a matcher.
func matchFlags(fs *flag.FlagSet) func() ajazz.Match {
	all := fs.Bool("all", false, "match every HID interface, not just AJAZZ ones")
	dockOnly := fs.Bool("dock", false, `only match the 2.4G receiver dock (product string contains "2.4G")`)
	name := fs.String("name", "", "only match interfaces whose manufacturer or product contains this substring (case-insensitive)")
	iface := fs.Int("iface", -1, "only match this USB interface number")

	return func() ajazz.Match {
		return func(i ajazz.Iface) bool {
			switch {
			case *dockOnly && !ajazz.IsDock(i):
				return false
			case !*all && !*dockOnly && !ajazz.IsAjazz(i):
				return false
			}
			if *name != "" {
				hay := strings.ToUpper(i.Mfr + " " + i.Product)
				if !strings.Contains(hay, strings.ToUpper(*name)) {
					return false
				}
			}
			if *iface >= 0 && i.Interface != *iface {
				return false
			}
			return true
		}
	}
}

func cmdList(args []string) error {
	fs := flag.NewFlagSet("list", flag.ExitOnError)
	resolve := matchFlags(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}

	ifaces, err := ajazz.Enumerate(resolve())
	if err != nil {
		return err
	}
	if len(ifaces) == 0 {
		fmt.Println("no matching HID interfaces — is the dock plugged in and switched to this machine?")
		return nil
	}
	for _, i := range ifaces {
		fmt.Printf("%s\n    path=%s serial=%q bus=%s\n", i, i.Path, i.Serial, i.Bus)
	}
	return nil
}

func cmdSync(args []string) error {
	fs := flag.NewFlagSet("sync", flag.ExitOnError)
	resolve := matchFlags(fs)
	verbose := fs.Bool("v", false, "report every interface tried, including rejections")
	if err := fs.Parse(args); err != nil {
		return err
	}
	return syncOnce(resolve(), *verbose, true)
}

func syncOnce(match ajazz.Match, verbose, quietOnMiss bool) error {
	now := time.Now()
	results, err := ajazz.SyncClock(match, now)
	if err != nil {
		return err
	}

	for _, r := range results {
		switch {
		case r.Err == nil:
			fmt.Printf("synced %s → %s\n", now.Format("2006-01-02 15:04:05"), r.Iface)
		case verbose:
			fmt.Printf("skipped %s: %v\n", r.Iface, r.Err)
		}
	}

	if !ajazz.AnyOK(results) {
		return fmt.Errorf("found %d AJAZZ interface(s) but none accepted the clock report "+
			"(run with -v for per-interface errors)", len(results))
	}
	return nil
}

func cmdDaemon(args []string) error {
	fs := flag.NewFlagSet("daemon", flag.ExitOnError)
	resolve := matchFlags(fs)
	interval := fs.Duration("interval", 15*time.Minute, "how often to re-send the time")
	settle := fs.Duration("settle", 3*time.Second, "how long to wait after the dock appears before sending")
	if err := fs.Parse(args); err != nil {
		return err
	}
	match := resolve()

	fmt.Printf("mousetime daemon: interval=%s settle=%s\n", *interval, *settle)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	// Poll rather than watch: the dock disappears entirely when the mouse
	// sleeps or the hub is switched to another machine, and reappears with the
	// clock reset. Detecting the transition is what actually matters — the
	// periodic re-send only exists to correct drift and to cover a wake from
	// sleep where the transition was missed.
	const pollEvery = 5 * time.Second
	poll := time.NewTicker(pollEvery)
	defer poll.Stop()
	periodic := time.NewTicker(*interval)
	defer periodic.Stop()

	present := false
	syncNow := func(reason string) {
		if err := syncOnce(match, false, true); err != nil {
			fmt.Fprintf(os.Stderr, "%s: sync failed: %v\n", reason, err)
			return
		}
	}

	// First pass immediately, so a launchd start does the right thing.
	if ifaces, err := ajazz.Enumerate(match); err == nil && len(ifaces) > 0 {
		present = true
		syncNow("startup")
	}

	for {
		select {
		case <-stop:
			fmt.Println("stopping")
			return nil

		case <-poll.C:
			ifaces, err := ajazz.Enumerate(match)
			if err != nil {
				fmt.Fprintln(os.Stderr, "enumerate:", err)
				continue
			}
			nowPresent := len(ifaces) > 0
			if nowPresent && !present {
				// The dock's firmware needs a moment after enumeration before
				// it will accept a report; sending too early is silently lost.
				time.Sleep(*settle)
				syncNow("connect")
			}
			present = nowPresent

		case <-periodic.C:
			if present {
				syncNow("periodic")
			}
		}
	}
}

func cmdDescriptor(args []string) error {
	fs := flag.NewFlagSet("descriptor", flag.ExitOnError)
	resolve := matchFlags(fs)
	raw := fs.Bool("raw", false, "print the raw descriptor bytes as well")
	if err := fs.Parse(args); err != nil {
		return err
	}

	ifaces, err := ajazz.Enumerate(resolve())
	if err != nil {
		return err
	}
	if len(ifaces) == 0 {
		return ajazz.ErrNoDevice
	}

	for _, i := range ifaces {
		fmt.Printf("=== %s\n", i)
		desc, err := ajazz.Descriptor(i)
		if err != nil {
			fmt.Printf("    unavailable: %v\n", err)
			continue
		}
		if *raw {
			fmt.Printf("    % x\n", desc)
		}
		for _, line := range ajazz.DescribeDescriptor(desc) {
			fmt.Printf("    %s\n", line)
		}
	}
	return nil
}

func cmdSniff(args []string) error {
	fs := flag.NewFlagSet("sniff", flag.ExitOnError)
	resolve := matchFlags(fs)
	dur := fs.Duration("for", 0, "stop after this long (0 = until interrupted)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	ifaces, err := ajazz.Enumerate(resolve())
	if err != nil {
		return err
	}
	switch len(ifaces) {
	case 0:
		return ajazz.ErrNoDevice
	case 1:
	default:
		fmt.Fprintln(os.Stderr, "multiple interfaces match; narrow it with -iface:")
		for _, i := range ifaces {
			fmt.Fprintf(os.Stderr, "  -iface %d  %s\n", i.Interface, i)
		}
		return fmt.Errorf("%d interfaces matched, need exactly one", len(ifaces))
	}

	return ajazz.Sniff(ifaces[0], os.Stdout, ajazz.SniffOpts{Duration: *dur})
}

func cmdGuard(args []string) error {
	fs := flag.NewFlagSet("guard", flag.ExitOnError)
	keyboard := fs.Bool("keyboard", true, "claim interfaces whose primary usage is Keyboard/Keypad")
	consumer := fs.Bool("consumer", true, "claim interfaces on the Consumer usage page (media/launch keys)")
	dryRun := fs.Bool("dry-run", false, "observe without claiming; events still reach macOS")
	vid := fs.Int("vid", ajazz.VendorID, "USB vendor ID to accept in addition to a name match (0 to disable)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if !*keyboard && !*consumer {
		return fmt.Errorf("nothing to do: enable at least one of -keyboard or -consumer")
	}

	verb := "claiming"
	if *dryRun {
		verb = "observing (dry run — events still reach macOS)"
	}
	fmt.Printf("mousetime guard: %s AJAZZ keyboard=%t consumer=%t\n", verb, *keyboard, *consumer)
	fmt.Println("the mouse interface is never claimed, so pointing keeps working")

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		fmt.Println("\nreleasing interfaces")
		guard.Stop()
	}()

	seized := 0
	err := guard.Run(guard.Options{
		VendorID: *vid,
		Keyboard: *keyboard,
		Consumer: *consumer,
		DryRun:   *dryRun,
	}, guard.Handlers{
		OnDevice: func(d guard.Device) {
			status := "FAILED to claim (grant Input Monitoring permission)"
			if d.Seized {
				seized++
				status = "claimed"
			}
			fmt.Printf("%s %04x:%04x %s %q\n", status, d.VendorID, d.ProductID,
				ajazz.UsageName(d.UsagePage, d.Usage), d.Product)
		},
		OnEvent: func(e guard.Event) {
			// A key-up (value 0) is the tail of an event already reported.
			if e.Value == 0 {
				return
			}
			mark := " "
			if ajazz.SuspectPhantom(e.UsagePage, e.Usage) {
				mark = "!"
			}
			fmt.Printf("%s %s suppressed %s value=%d\n",
				time.Now().Format("15:04:05.000"), mark,
				ajazz.UsageName(e.UsagePage, e.Usage), e.Value)
		},
	})
	if err != nil {
		return err
	}
	if seized == 0 {
		fmt.Println("note: no interfaces were claimed — nothing was being suppressed")
	}
	return nil
}
