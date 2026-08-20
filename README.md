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

Needs the Xcode command line tools. The package declares macOS 13 as its
minimum; it has been tested on macOS 27.0 on Apple Silicon, and nowhere else
yet.

```sh
git clone https://github.com/reicheltp/ajazz-macos-mousetime-sync.git
cd ajazz-macos-mousetime-sync
./launchd/install.sh
```

That's it. The dock's clock is correct within a second or two, and stays correct
— including after sleep, after unplugging and replugging, and across time-zone
changes. The service starts again automatically when you log in.

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

## Not fixed yet: the phantom input

The other complaint about this mouse in wireless mode is that it sometimes
produces input nobody asked for — System Settings opening on its own, stray
keystrokes. **This does not address that.** Deliberately: it needs measuring
before it needs code, and the interface inventory already contradicts part of
the obvious explanation. See
[docs/PROTOCOL.md](docs/PROTOCOL.md#the-phantom-input-problem) for where the
diagnosis stands and what would settle it.

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
