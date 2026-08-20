# mousetime — fix the `00:00` clock on an AJAZZ mouse dock on macOS

Sets the clock on the display of an **AJAZZ AJ159 APEX** charging dock from
macOS, so it stops showing `00:00` and the year 2001.

AJAZZ ships configuration software for Windows only. On macOS the dock's screen
never learns what time it is: it powers up at `2001-01-01 00:00` and stays
there. `mousetime` is the small missing piece that tells it — a background
service, native Swift, no dependencies, and **no macOS permissions required**.

Should also work on the **AJ179 APEX** and **AJ199** docks, which take the same
command. If you try one, please open an issue either way.

## The problem, concretely

The AJ159 APEX comes with a magnetic charging dock that doubles as the 2.4 GHz
receiver and has a little colour display on the front. The display shows a
clock. The clock is wrong, always, because nothing on macOS ever sets it.

Worse, it does not stay set. Even after you set it once, the dock forgets the
time again within a few minutes — so a one-shot fix is not enough, and that is
why this ships as a background service rather than a script you run by hand.

## Install

The package declares macOS 13 as its minimum. It has been tested on macOS 27.0
on Apple Silicon, and nowhere else yet.

### Download a build

Grab the archive from [Releases](../../releases) — one universal binary, Apple
Silicon and Intel:

```sh
tar -xzf mousetime-*-macos.tar.gz
cd mousetime-*-macos
./launchd/install.sh
```

**macOS will not trust this download, and it is right not to.** There is no
Apple Developer ID behind this project, so the binary cannot be notarised.
`install.sh` clears the quarantine flag on the copy it installs and tells you
while it does it. If handing Gatekeeper a bypass for a stranger's binary is not
your idea of a good time — fair — build it yourself, below. Either way, check
the archive against the published `.sha256`.

### Or build it

Needs only the Xcode command line tools; the package has no dependencies.

```sh
git clone https://github.com/reicheltp/ajazz-macos-mousetime-sync.git
cd ajazz-macos-mousetime-sync
./launchd/install.sh
```

Either route ends the same way: the dock's clock is correct within a second or
two and stays correct — after sleep, after unplugging and replugging, and across
time-zone changes. The service starts again automatically when you log in.

```sh
tail -f ~/Library/Logs/mousetime.log   # see what it is doing
./launchd/install.sh uninstall         # remove it completely
```

### Why no permission prompt?

Because it never touches your mouse or your keyboard. Comparable tools ask for
*Input Monitoring*, which is a big thing to grant a background process. This one
only opens the receiver's vendor-specific interface, which macOS does not treat
as an input device, and it finds devices by reading the IO registry rather than
by opening them. Details in [docs/PROTOCOL.md](docs/PROTOCOL.md#permissions).

## Use it by hand

```sh
swift build

.build/debug/mousetime list      # what's attached; * marks the control channel
.build/debug/mousetime sync      # set the clock once, right now
.build/debug/mousetime sync -v   # ...and say what each interface answered
.build/debug/mousetime daemon    # run in the foreground instead of via launchd
.build/debug/mousetime help
```

`list` on a connected AJ159 dock:

```
  3151:5007 GenericDesktop/Mouse "AJAZZ 2.4G 8K" [USB]
* 3151:5007 Vendor(0xffff)/0x0002 "AJAZZ 2.4G 8K" [USB]
  3151:5007 Consumer/0x0001 "AJAZZ 2.4G 8K" [USB]
```

Three interfaces from one receiver: the mouse, a vendor-defined control channel,
and a consumer-control endpoint. Only the middle one accepts the clock command.

## Troubleshooting

**`no AJAZZ interfaces found`** — the dock isn't connected, or its switch is set
to another machine. `mousetime list --all` lists every HID device on the system,
which tells you whether macOS sees the receiver at all.

**`none accepted the clock report`** — run `mousetime sync -v` to see what each
interface said, then try `mousetime sync --all`, which also offers the report to
the input interfaces. If that works, please open an issue with the output of
`mousetime list --all`; it probably means your firmware puts the control channel
somewhere this doesn't look yet.

**The clock is right but drifts or resets** — check the service is actually
running: `launchctl print gui/$UID/de.huskycare.mousetime | head`.

## How it works, briefly

A 64-byte HID feature report with report ID `0x28` and opcode `0xd7`, carrying
the year, month, day, hour, minute and second. It goes to the receiver's
vendor-defined HID interface.

The dock discards a malformed report silently — no acknowledgement, no error —
so the byte layout is pinned by tests (`swift test`) rather than trusted.

Full write-up, including the interface inventory, the permission reasoning and
why it re-sends every 30 seconds: **[docs/PROTOCOL.md](docs/PROTOCOL.md)**.

## Battery, and a warning before it dies

```sh
mousetime battery                     # mouse battery: 100%
mousetime battery --test-notification  # prove the notification path works
```

To get warned automatically, install with `--battery`:

```sh
./launchd/install.sh --battery
```

The daemon then reads the level every five minutes and posts a macOS
notification when it falls to 20%, 10% and 5% — once each per discharge cycle,
re-armed only when the mouse is actually charged again. Thresholds are
configurable: `daemon --battery-thresholds 30,15,5`.

Also needs no permission: the level comes from the same vendor interface as the
clock. Notifications go through `osascript`, so they are attributed to Script
Editor rather than to mousetime — a bare binary has no bundle identifier, and
`UNUserNotificationCenter` requires one. A menu bar app would fix that, since it
needs a bundle anyway.

**A nearly empty battery cannot be produced on demand for testing**, so the
threshold logic is a pure state machine covered by unit tests rather than
verified against hardware, and `--test-notification` exists so the delivery path
can be checked separately. What *has* been verified on hardware is the reading
itself.

## The phantom input

In wireless mode the receiver sometimes produces input nobody asked for — System
Settings opening on its own, stray keystrokes. The cause is identified, and
there is an opt-in fix.

The receiver's second HID interface declares a consumer array spanning usages
`0x0000`–`0x033C`, a keyboard collection accepting any keycode with any
modifier, and a system-control collection that can request sleep or power down.
Because the consumer field is a bare range rather than a list of specific
usages, *any* 16-bit value is a well-formed report — so a corrupted 2.4 GHz
packet becomes a real system action or a real keystroke.

Nothing you press depends on that interface. The five buttons — including
browser back and forward — the wheel and horizontal scroll are all on the mouse
interface. So the whole thing can be mapped to nothing:

```sh
mousetime suppress --dry-run   # show what would be silenced
mousetime suppress             # do it (needs no permission)
mousetime suppress --status    # how many usages are currently silenced
mousetime suppress --clear     # undo
```

The mapping is attached to a live HID service, so unplugging the dock or
rebooting clears it. To have it reapplied automatically:

```sh
./launchd/install.sh --suppress
```

It is opt-in rather than default because it disables an entire HID interface.
That is demonstrably safe on the AJ159, whose descriptors are documented in
[docs/PROTOCOL.md](docs/PROTOCOL.md#what-each-interface-can-emit) — but it has
not been checked on the other models this may run against.

**Honest limitation:** this uses macOS's own `UserKeyMapping`, and the mapping is
verifiably present in the event system's active filter. Whether a usage mapped
to zero is *discarded* rather than passed through could not be proven directly,
because the phantom events cannot be triggered on demand. The evidence is
consistent; the proof is "it stopped happening".

## Contributing

Issues and pull requests welcome, especially:

- **Other docks.** AJ179 APEX, AJ199, or anything else with this screen. Paste
  the output of `mousetime list --all` and say whether `sync` worked.
- **More of the protocol.** Battery level and uploading images to the display
  are both known to be possible; neither is implemented here.
- **Phantom input measurements.** See the link above.

```sh
swift build && swift test
```

### Cutting a release

The version in `Sources/mousetime/main.swift` is the single source of truth. Bump
it, commit, then tag:

```sh
git tag v0.2.0 && git push --tags
```

`.github/workflows/release.yml` refuses to publish if the tag and that version
disagree, so a release can never advertise a version its binary does not report.
The build itself lives in `scripts/package.sh` — run it locally to get the exact
archive CI would publish, including the universal-binary check:

```sh
./scripts/package.sh
```

## Credit

The clock opcodes were worked out by
[mstoiakevych/ajazz-clock-sync](https://github.com/mstoiakevych/ajazz-clock-sync)
(MIT), which solves the same problem for Linux and macOS in Python and Swift and
covers the AJ179 and AJ199 docks. This is an independent implementation from the
documented byte layout, with different device discovery and no permission
requirement — but the reverse engineering credit is theirs.

## Licence

GNU General Public License v3.0 or later. See [LICENSE](LICENSE).

Copyright (C) 2026 Paul Reichelt-Ritter
