import Foundation

// Line-buffer stdout. When launchd redirects it to a log file it is a pipe, not
// a terminal, so the C runtime block-buffers it — and a daemon whose only
// observability is its log file must not sit on output for 4 KB at a time.
setvbuf(stdout, nil, _IOLBF, 0)

let version = "0.1.0"

let usage = """
mousetime \(version) — AJAZZ AJ159 APEX dock support for macOS

The dock has no battery-backed clock: it starts at 2001-01-01 00:00 and stays
there until something tells it the time. On Windows the driver does that. This
does it on macOS.

Usage:
  mousetime list [--all] [--dock]     show AJAZZ HID interfaces; * marks the
                                      control-channel candidate
  mousetime sync [-v] [--all]         set the dock clock once, now
  mousetime daemon [--interval 15m]   keep it synced; this is what launchd runs
                                        [--settle 2.5s] [--all]
  mousetime version
  mousetime help

Options:
  --all       widen the search to every AJAZZ interface, input devices
              included. The default only touches AJAZZ interfaces that are not
              standard input devices, which needs no macOS permission; --all
              may prompt for Input Monitoring.
  --dock      (list) only the 2.4G receiver dock
  -v          (sync) report every interface tried, and why it refused

Install as a background service:
  ./launchd/install.sh
"""

let argv = Array(CommandLine.arguments.dropFirst())

guard let command = argv.first else {
    print(usage)
    exit(2)
}

let rest = Array(argv.dropFirst())
let status: Int32

switch command {
case "list":
    status = runList(Arguments(rest))

case "sync":
    status = runSync(Arguments(rest))

case "daemon":
    status = runDaemon(Arguments(rest, valueOptions: ["interval", "settle"]))

case "version", "--version", "-v":
    print("mousetime \(version)")
    status = 0

case "help", "--help", "-h":
    print(usage)
    status = 0

default:
    complain("unknown command \"\(command)\"")
    print(usage)
    status = 2
}

exit(status)
