#!/bin/bash
# Install mousetime as a per-user launchd agent that keeps the dock clock synced.
#
#   ./launchd/install.sh            install and start
#   ./launchd/install.sh uninstall  stop and remove
#
# Works in two situations, which is why it looks for a binary before building
# one: inside a git clone it compiles from source, and inside an unpacked
# release archive it uses the binary shipped alongside it. Keeping it one script
# means the download path and the build path cannot drift apart.
set -euo pipefail

LABEL="de.huskycare.mousetime"
PREFIX="$HOME/Library/Application Support/mousetime"
BINARY="$PREFIX/mousetime"
LOGDIR="$HOME/Library/Logs"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

uninstall() {
	# bootout fails when the agent is not loaded, which is fine here.
	launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
	rm -f "$PLIST"
	rm -rf "$PREFIX"
	echo "removed $LABEL"
}

if [[ "${1:-}" == "uninstall" ]]; then
	uninstall
	exit 0
fi

if [[ -x "$REPO/mousetime" ]]; then
	# Unpacked release archive: the binary sits next to this script's parent.
	SOURCE="$REPO/mousetime"
	echo "==> using the prebuilt binary in $REPO"
elif [[ -f "$REPO/Package.swift" ]]; then
	echo "==> building from source"
	(cd "$REPO" && swift build -c release)
	SOURCE="$REPO/.build/release/mousetime"
else
	echo "error: found neither a prebuilt ./mousetime nor a Package.swift in $REPO" >&2
	exit 1
fi

echo "==> installing to $BINARY"
mkdir -p "$PREFIX" "$LOGDIR" "$(dirname "$PLIST")"
# Copy to a stable path rather than running from .build or the download folder:
# macOS ties any permission grant to the binary's path and signature, and
# `swift package clean` wipes .build.
install -m 755 "$SOURCE" "$BINARY"

# A binary downloaded from the internet carries com.apple.quarantine, and macOS
# refuses to launch it because this project has no Apple Developer ID to
# notarise with. Clearing the flag is what makes a downloaded release runnable
# at all -- said out loud rather than done quietly, because it is a deliberate
# step around Gatekeeper and only sensible for software you chose to trust.
if xattr -p com.apple.quarantine "$BINARY" >/dev/null 2>&1; then
	echo "==> clearing the Gatekeeper quarantine flag on the installed binary"
	echo "    (it was downloaded; this project is unsigned and cannot be notarised)"
	xattr -d com.apple.quarantine "$BINARY" 2>/dev/null || true
fi

# Ad-hoc sign with a stable identifier. This does not satisfy Gatekeeper -- only
# a Developer ID would -- but it gives the binary a consistent identity, which
# is what macOS keys permission grants to.
codesign --force --sign - --identifier "$LABEL" "$BINARY" 2>/dev/null \
	|| echo "    (codesign failed; continuing unsigned)"

echo "==> writing $PLIST"
sed -e "s|__BINARY__|$BINARY|g" -e "s|__LOGDIR__|$LOGDIR|g" \
	"$REPO/launchd/$LABEL.plist" >"$PLIST"

echo "==> loading agent"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"

cat <<EOF

installed. The dock clock is re-sent every 30 seconds, and also when the dock
connects, after waking from sleep, and on clock or time-zone changes.

The short interval is not paranoia: the dock forgets the time within a few
minutes, without re-enumerating on USB, so nothing announces it and re-sending
is the only cure. One 64-byte report to a USB-powered dock costs nothing.

No macOS permission is needed: only the receiver's vendor-specific interface
is opened, which is not a protected input device.

  logs:    tail -f $LOGDIR/mousetime.log
  status:  launchctl print gui/$UID/$LABEL | head -20
  remove:  $0 uninstall
EOF
