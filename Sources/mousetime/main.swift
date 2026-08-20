// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Paul Reichelt-Ritter

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
  mousetime daemon [--interval 30s]   keep it synced; this is what launchd runs
                                        [--settle 2.5s] [--all] [-v] [--suppress]
                                        [--battery] [--battery-thresholds 20,10,5]
  mousetime battery [-v]              read the mouse battery level
                    [--test-notification]
  mousetime suppress [--dry-run]      silence the receiver interface that emits
                     [--status]        input nobody asked for
                     [--clear]
  mousetime version
  mousetime help

Options:
  --all       widen the search to every AJAZZ interface, input devices
              included. The default only touches AJAZZ interfaces that are not
              standard input devices, which needs no macOS permission; --all
              may prompt for Input Monitoring.
  --dock      (list) only the 2.4G receiver dock
  -v          (sync) report every interface tried, and why it refused
              (daemon) log every periodic sync instead of summarising them

Why the short interval: the dock forgets the time within a few minutes -- most
likely when the mouse's radio link drops as it sleeps -- and it does so without
re-enumerating on USB, so no device notification fires. Re-sending is the only
thing that recovers the display. One 64-byte report to a USB-powered dock costs
nothing, and the mouse's own battery is not involved.

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
    status = runDaemon(Arguments(rest, valueOptions: [
        "interval", "settle", "battery-interval", "battery-thresholds",
    ]))

case "suppress":
    status = runSuppress(Arguments(rest))

case "battery":
    status = runBattery(Arguments(rest))

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
