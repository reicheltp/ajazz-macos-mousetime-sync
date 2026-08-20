#!/bin/bash
# Install mousetime as a per-user launchd agent that keeps the dock clock synced.
#
#   ./launchd/install.sh            build, install and start
#   ./launchd/install.sh uninstall  stop and remove
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

echo "==> building"
cd "$REPO"
swift build -c release

echo "==> installing to $BINARY"
mkdir -p "$PREFIX" "$LOGDIR" "$(dirname "$PLIST")"
# Copy to a stable path rather than running out of .build: macOS ties any
# permission grant to the binary's path and signature, and .build is wiped by
# `swift package clean`.
install -m 755 "$REPO/.build/release/mousetime" "$BINARY"

# Ad-hoc sign with a stable identifier. Without a Developer ID this does not
# survive a rebuild for permission purposes, but it does give the binary a
# consistent identity, which is as good as it gets here.
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

installed. The dock clock is set when it connects, after waking from sleep,
on time-zone changes, and every 15 minutes as a safety net.

No macOS permission is needed: only the receiver's vendor-specific interface
is opened, which is not a protected input device.

  logs:    tail -f $LOGDIR/mousetime.log
  status:  launchctl print gui/$UID/$LABEL | head -20
  remove:  $0 uninstall
EOF
