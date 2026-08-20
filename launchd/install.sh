#!/bin/bash
# Install mousetime as a per-user launchd agent that keeps the dock clock synced.
#
#   ./launchd/install.sh            install and start
#   ./launchd/install.sh uninstall  stop and remove
set -euo pipefail

LABEL="de.huskycare.mousetime"
BINDIR="$HOME/.local/bin"
LOGDIR="$HOME/Library/Logs"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

uninstall() {
	# bootout fails when the agent is not loaded; that is fine here.
	launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
	rm -f "$PLIST"
	echo "removed $LABEL (binary left at $BINDIR/mousetime)"
}

if [[ "${1:-}" == "uninstall" ]]; then
	uninstall
	exit 0
fi

echo "==> building"
mkdir -p "$BINDIR" "$LOGDIR" "$(dirname "$PLIST")"
(cd "$REPO" && go build -o "$BINDIR/mousetime" .)

echo "==> writing $PLIST"
sed -e "s|__BINDIR__|$BINDIR|g" -e "s|__LOGDIR__|$LOGDIR|g" \
	"$REPO/launchd/$LABEL.plist" >"$PLIST"

echo "==> loading agent"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl enable "gui/$UID/$LABEL"

echo
echo "installed. the clock is synced on connect and every 15 minutes."
echo "  logs:    tail -f $LOGDIR/mousetime.log"
echo "  status:  launchctl print gui/$UID/$LABEL | head -20"
echo "  remove:  $0 uninstall"
