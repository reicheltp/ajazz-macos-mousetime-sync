# The AJAZZ dock protocol, as far as it is known

Everything here was observed on an **AJAZZ AJ159 APEX** with its magnetic
charging dock, on macOS 27.0 / Apple Silicon. Where something is a guess rather
than a measurement, it says so.

## Interface inventory

The receiver publishes three HID interfaces, all under the same USB device:

```
  3151:5007 GenericDesktop/Mouse "AJAZZ 2.4G 8K" [USB]
* 3151:5007 Vendor(0xffff)/0x0002 "AJAZZ 2.4G 8K" [USB]
  3151:5007 Consumer/0x0001 "AJAZZ 2.4G 8K" [USB]
```

Two things worth writing down:

**The vendor ID is `0x3151`.** AJAZZ uses `0x249a` on other models — the AJ179
battery tooling matches on that one — so a driver keyed to `0x249a` finds
nothing here. `mousetime` matches on neither: it looks for a product string
containing both `AJAZZ` and `2.4G`, because product IDs also vary by model and
firmware revision.

**There is no keyboard interface.** Only mouse, vendor and consumer. This
matters for the phantom-input question below.

The `*` marks what `mousetime` considers a control-channel candidate: an AJAZZ
interface whose primary usage is not mouse, pointer, keyboard, keypad or
consumer.

## Setting the clock

A 64-byte HID **feature** report on the vendor-defined interface. Byte 0 is the
report ID *and* the first transferred byte — the ID is passed separately to
`IOHIDDeviceSetReport` as well.

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

Local time: the dock displays exactly the numbers it is given, with no time-zone
handling of its own.

Hour, minute and second are zero-based; month and day are one-based.

There is **no acknowledgement**. A malformed report, a report to the wrong
interface, or a report sent too early is discarded in silence. That absence of
feedback is why `ClockReport` is a pure function with no IOKit in it, checked
byte-for-byte by `swift test` — a mistake here would surface as "the clock just
stopped working", with nothing in any log.

### Timing

After the dock appears on the bus, the firmware needs roughly two seconds before
it will accept a report. Sent immediately on enumeration, it is lost — silently,
per the above. `mousetime` waits 2.5 s.

## Why it re-sends every 30 seconds

Set the clock, then leave the mouse alone. Within a few minutes the display is
back to `00:00`.

The interesting part is what the receiver looks like when that happens: it is
**still enumerated**. Same `locationID`, same three interfaces, no
re-registration in the IO registry. The dock lost its clock without the USB
device going anywhere.

The consequence is structural: nothing announces the reset, so there is no event
to react to. Hotplug detection — which is otherwise the right tool, and is still
used here — cannot catch this case even in principle. Re-sending on a timer is
the only mechanism that recovers the display, which makes the interval the
primary mechanism rather than a fallback.

The most likely trigger is the mouse's radio link dropping as it goes to sleep.
That is a hypothesis; the reset was observed, its cause was not.

The cost of re-sending is one 64-byte report to a dock powered by USB. The
mouse's own battery is not in the path, so a short interval is close to free.

Hotplug detection still earns its place: it covers replugging the dock and
switching the hub between machines, where waiting for the timer would leave the
display wrong for up to 30 seconds.

Consequence for logging: at seconds-level intervals, printing every success
would bury real events under thousands of identical lines a day. Routine
periodic syncs collapse to one line plus a count every 15 minutes. Device
arrivals, departures and refusals always print, and any of them reopens the
window so the recovery afterwards is visible. `mousetime daemon -v` prints
everything.

## Permissions

macOS gates HID input devices behind *Input Monitoring* (TCC). Other tools in
this space require it. `mousetime` does not, and the difference is in how
devices are found.

The usual approach is `IOHIDManager` with a match-everything dictionary, then
`IOHIDManagerOpen`. That opens every matched device — keyboards included — which
is exactly what the permission check exists to catch.

`mousetime` instead:

1. enumerates with `IOServiceGetMatchingServices(kIOHIDDeviceKey)` and reads
   properties via `IORegistryEntryCreateCFProperty`. Reading the IO registry is
   unprivileged; it can see every device, including keyboards, without any
   grant.
2. filters in code, on the properties it just read.
3. calls `IOHIDDeviceCreate` and `IOHIDDeviceOpen` on **only** the
   vendor-defined interface, which macOS does not classify as a protected input
   device.

The mouse and consumer interfaces are never opened. Nothing about setting a
clock requires them.

This does mean that if a future firmware moved the control channel onto a
standard usage page, `mousetime sync --all` would be needed — and that path can
prompt for Input Monitoring.

## The phantom-input problem

The unresolved half. In 2.4 GHz mode the receiver reportedly produces input
nobody asked for: System Settings opening by itself, stray keystrokes.

What the inventory already tells us:

- **Stray keystrokes cannot come from this receiver.** It publishes no keyboard
  interface. There is no mechanism by which it could send a key.
- **System Settings opening is consistent with the consumer interface.** HID
  Consumer usage `0x019f`, "AL Control Panel", is mapped by macOS to exactly
  that action. Radio noise decoded into a consumer report would do it. This is a
  hypothesis, not a measurement.
- Other consumer usages would produce symptoms that *look* like typing without
  being typing: `0x0221` (AC Search) opens Spotlight, `0x0192` opens Calculator.

Before anything is filtered, one thing has to be known: **where the side buttons
live.** Browser back/forward is either plain mouse buttons 4 and 5 on the mouse
interface, or Consumer `AC Back` (`0x0224`) / `AC Forward` (`0x0225`) on the
consumer interface. If it is the latter, the consumer interface carries traffic
the user actually wants, and seizing it wholesale would break a working feature
to fix an intermittent one.

The next step is a `watch` command that logs what each interface emits without
intercepting it — which does need Input Monitoring, since it means reading input
devices. Then: press each side button, note the usage; leave it running until a
phantom event occurs, note that usage. Only then is there enough to design a
filter.

The mechanism a fix would use is `IOHIDDeviceOpen` with
`kIOHIDOptionsTypeSeizeDevice`, which gives one process exclusive claim on an
interface so its input never reaches the window server. The mouse interface must
never be seized, for obvious reasons.

## Not implemented

Known to be possible on this hardware, absent here:

- **Battery level.** Reportedly a query with opcode `0x20`, sub-command `0x01`,
  answered via `GET_FEATURE` into a 65-byte buffer. Unverified.
- **Uploading images and GIFs to the display.** The Windows software does this.
  The `aks075-linux` project does it for an AJAZZ *keyboard* screen, which may
  or may not use a related command set.
- **DPI, polling rate, button mapping, RGB.** All handled by the Windows
  software; none of it examined here.

## Code map

| File | Role |
|---|---|
| `Sources/MouseTimeKit/ClockReport.swift` | the wire format, pure and testable |
| `Sources/MouseTimeKit/DockDiscovery.swift` | registry enumeration, interface classification |
| `Sources/MouseTimeKit/ClockSync.swift` | opening the interface, sending the report |
| `Sources/MouseTimeKit/DockMonitor.swift` | `IOServiceAddMatchingNotification` hotplug |
| `Sources/MouseTimeKit/ClockSyncService.swift` | the sync triggers and debounce |
| `Sources/MouseTimeKit/HIDUsage.swift` | usage-page/usage names for legible output |
| `Sources/mousetime/` | the CLI, thin over the above |

The logic lives in `MouseTimeKit` and the CLI is a thin layer, so a menu bar app
could be added without restructuring.
