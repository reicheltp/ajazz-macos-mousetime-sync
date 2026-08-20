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

**Three interfaces is not three collections.** `PrimaryUsage` names only the
*first* collection in an interface's report descriptor, and the second interface
has four. Reading the three lines above and concluding "no keyboard, so no stray
keystrokes" is wrong — an earlier revision of this document made exactly that
mistake. What each interface can actually emit is in the descriptors below.

The `*` marks what `mousetime` considers a control-channel candidate: an AJAZZ
interface whose primary usage is not mouse, pointer, keyboard, keypad or
consumer.

## What each interface can emit

Report descriptors are readable from the IO registry — the `ReportDescriptor`
property on each `IOHIDDevice` — which needs no permission at all:

```sh
ioreg -a -c IOHIDDevice -r -l
```

### The mouse interface (71 bytes)

```
05 01 09 02 A1 01 09 01 A1 00     Generic Desktop / Mouse / Pointer
  05 09 19 01 29 05               Button page, Usage Minimum 1, Maximum 5
  15 00 25 01 75 01 95 05 81 02     -> 5 buttons, one bit each
  95 03 81 01                       -> 3 bits padding
  05 01 09 30 09 31 75 10 95 02 81 06   X, Y as 16-bit relative
  09 38 75 08 95 01 81 06               Wheel, 8-bit relative
  05 0C 0A 38 02 95 01 81 06            Consumer AC Pan (0x0238), horizontal scroll
C0 C0
```

**Five buttons, and they live here.** Browser back and forward are buttons 4 and
5 on the mouse interface — plain `Button` page usages. They do *not* go through
the consumer interface. That answers the question that was blocking any attempt
to filter the phantom input: nothing the user actually presses depends on the
second interface.

### The second interface (120 bytes) — four collections

```
Report ID 3   Consumer Control
              Usage Minimum 0x0000, Usage Maximum 0x033C
              one 16-bit array field
Report ID 2   Generic Desktop / System Control
              Usage Minimum 0x81, Usage Maximum 0x83
              -> System Power Down, System Sleep, System Wake Up
Report ID 7   Generic Desktop / Keyboard
              modifiers 0xE0-0xE7 as an 8-bit bitmap
              plus six 8-bit keycodes, Usage Minimum 0x00, Usage Maximum 0xFF
Report ID 5   Vendor page 0xFFFF, three bytes
```

This is the whole phantom-input problem in one place. That interface can send:

- **any consumer usage from 0 to 0x33C** — a 16-bit array field with no
  enumeration of specific usages, so a single wrong value is a valid report.
  `0x00E9` is Volume Up, `0x019F` opens System Settings, `0x0221` opens
  Spotlight, `0x0192` opens Calculator.
- **any keycode with any modifier combination**, on report ID 7. So stray
  keystrokes are not only possible here, this is the only place they could come
  from.
- **system sleep and power down**, on report ID 2.

A mouse with five buttons, a wheel and horizontal scroll needs none of it.

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

Observed symptom, with a screenshot to go by: System Settings opening on its own
at the **Sound** pane, only while the mouse is used through the dock.

The report descriptors above explain it, and they close the question that was
blocking a fix.

**Everything needed to produce these symptoms is on the second interface.** Its
consumer collection is a bare 16-bit array spanning usages `0x0000`–`0x033C`,
so any 16-bit value is a valid report; its keyboard collection accepts any
keycode with any modifier bitmap; its system-control collection can request
sleep or power down. A 2.4 GHz link that occasionally delivers a corrupted
packet, decoded against that descriptor, produces arbitrary system actions and
arbitrary keystrokes. No exotic explanation is needed.

The Sound pane specifically fits two paths, both available here: macOS opens
Sound settings on **Option + a volume key**, which needs a modifier from report
ID 7 plus `0x00E9`/`0x00EA` from report ID 3 — or `0x019F` ("AL Control Panel")
opens System Settings, which restores whichever pane was last viewed. One
screenshot does not separate the two, and it does not need to: the fix is the
same either way.

**Nothing the user presses depends on that interface.** Browser back and forward
are buttons 4 and 5 on the *mouse* interface, per its descriptor. Five buttons,
a wheel and horizontal scroll are the entire useful surface of this mouse, and
all of them are on the mouse interface. The second interface has no legitimate
function for this device — which is what makes disabling it wholesale a
proportionate fix rather than a trade-off.

An earlier revision of this section argued the opposite from `PrimaryUsage`
alone and concluded stray keystrokes could not originate here. `PrimaryUsage`
reports one collection out of four. Descriptors, not summaries.

### What a fix would do

`IOHIDDeviceOpen` with `kIOHIDOptionsTypeSeizeDevice` claims an interface
exclusively, so its input never reaches the window server. Applied to the second
interface only; the mouse interface must never be seized, for obvious reasons.

Costs to weigh before building it: seizing an input device requires Input
Monitoring, which the clock sync deliberately avoids, so it would have to be
opt-in and separate. It also holds the interface for as long as the process runs.

Worth trying first, because it needs no code and no permission: `hidutil` can
set a `UserKeyMapping` on a matched device to map usages to nothing. Whether it
can cover a full 16-bit consumer array rather than individual usages is untested.

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
