# mousetime

Keeps the clock on an **AJAZZ AJ159 APEX** smart dock in sync with macOS.

The dock — the magnetic charging base that doubles as the 2.4 GHz receiver and
carries the display — has no battery-backed clock. It powers up showing
`00:00` and the year 2001, and stays there until something tells it the time.
The Windows driver does that on connect. There is no macOS driver, so nothing
does. This is that missing piece.

Native Swift against IOKit, no dependencies.

## Install

```sh
./launchd/install.sh
```

That builds a release binary, installs it to
`~/Library/Application Support/mousetime/`, and loads a launchd agent that
syncs the clock when the dock connects, after the machine wakes from sleep, on
time-zone or clock changes, and every 15 minutes as a safety net.

**No macOS permission is required.** See [Permissions](#permissions) for why
that is worth pointing out.

```sh
tail -f ~/Library/Logs/mousetime.log   # watch it work
./launchd/install.sh uninstall         # remove
```

## Use directly

```sh
swift build

.build/debug/mousetime list      # what is attached; * marks the control channel
.build/debug/mousetime sync -v   # set the clock once, reporting each interface
.build/debug/mousetime daemon    # run in the foreground
```

`mousetime list` on a connected AJ159 dock looks like this:

```
  3151:5007 GenericDesktop/Mouse "AJAZZ 2.4G 8K" [USB]
* 3151:5007 Vendor(0xffff)/0x0002 "AJAZZ 2.4G 8K" [USB]
  3151:5007 Consumer/0x0001 "AJAZZ 2.4G 8K" [USB]
```

Three interfaces: the mouse, a vendor-defined control channel, and a
consumer-control endpoint. The clock command only works on the middle one.

Note the vendor ID: **`0x3151`**, not the `0x249a` that AJAZZ uses on other
models. Nothing here matches on vendor or product IDs for that reason — the
dock is found by its product string containing both `AJAZZ` and `2.4G`.

If `list` marks no candidate with `*`, try `mousetime sync --all`, which also
offers the report to the input interfaces.

## The protocol

A 64-byte HID **feature** report on the vendor-defined interface. Byte 0 is the
report ID and is part of the transferred buffer.

| Offset | Value | Meaning |
|---|---|---|
| 0 | `0x28` | report ID |
| 1–6 | `0x00` | padding |
| 7 | `0xd7` | opcode: set date/time |
| 8–9 | big endian | year (2026 = `0x07ea`) |
| 10 | 1–12 | month |
| 11 | 1–31 | day |
| 12 | 0–23 | hour |
| 13 | 0–59 | minute |
| 14 | 0–59 | second |
| 15–63 | `0x00` | padding |

Local time — the dock displays exactly what it is given.

A malformed report is discarded silently; there is no acknowledgement and no
error. That is why `ClockReport` is a pure function with no IOKit in it, pinned
byte-for-byte by tests:

```sh
swift test
```

Credit for the opcodes goes to
[mstoiakevych/ajazz-clock-sync](https://github.com/mstoiakevych/ajazz-clock-sync),
which implements the same command for Linux and macOS and covers the AJ179 and
AJ199 docks as well.

## Permissions

macOS gates HID input devices behind *Input Monitoring*. Other tools in this
space ask for it, because they use `IOHIDManager` with a match-everything
dictionary — that opens keyboards too, which trips the check.

mousetime avoids it. Devices are enumerated by reading the IO registry
(`IOServiceGetMatchingServices` plus `IORegistryEntryCreateCFProperty`), which
is unprivileged, and the only interface ever opened is the vendor-defined one,
which is not a protected input device. Nothing about the clock needs to touch
the mouse, the keyboard, or the consumer endpoint.

## Architecture

`MouseTimeKit` holds the logic and `mousetime` is a thin CLI over it, so a menu
bar app can be added later without restructuring.

| File | Role |
|---|---|
| `Sources/MouseTimeKit/ClockReport.swift` | the wire format, pure and testable |
| `Sources/MouseTimeKit/DockDiscovery.swift` | registry enumeration, interface classification |
| `Sources/MouseTimeKit/ClockSync.swift` | opening the interface and sending the report |
| `Sources/MouseTimeKit/DockMonitor.swift` | hotplug notifications, no polling |
| `Sources/MouseTimeKit/ClockSyncService.swift` | the four sync triggers, with debounce |
| `Sources/MouseTimeKit/HIDUsage.swift` | usage-page/usage names for legible output |

The dock disappears from the bus entirely when the mouse sleeps or the hub is
switched to another machine, and comes back with its clock reset — so the
*transition* is the signal that matters, not a periodic check. Hence
`IOServiceAddMatchingNotification` rather than polling, with the timer only as
a safety net.

One deliberate delay: after the dock appears there is a ~2.5 s settle before
the report is sent. The firmware will not accept it immediately after
enumeration, and a report sent too early is lost without any error.

## Not done yet: the phantom input

The other half of the problem is that in 2.4 GHz mode the receiver sometimes
produces input nobody asked for — System Settings opening on its own, stray
keystrokes. That is **not addressed yet**, on purpose: it needs measuring
before it needs code.

What the interface inventory already tells us:

- The AJ159 receiver publishes **no keyboard interface**. Only mouse,
  vendor, and consumer. So stray *keystrokes* cannot originate here — the
  receiver has no way to send them.
- System Settings opening by itself is consistent with the consumer interface.
  HID Consumer usage `0x019f` ("AL Control Panel") is mapped by macOS to
  exactly that. This is a hypothesis, not a measurement.
- The consumer interface may also be where the side buttons' browser
  back/forward live (`AC Back` = `0x0224`, `AC Forward` = `0x0225`) — or they
  may be plain mouse buttons 4 and 5. Until that is known, the consumer
  interface must not be filtered wholesale.

Next step is a `watch` command that logs what each interface actually emits,
without intercepting it. That one does need Input Monitoring. A fix comes after
the data, not before.
