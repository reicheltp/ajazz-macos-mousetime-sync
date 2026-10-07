#!/bin/bash
# Build MouseTime.app, the menu bar front end.
#
#   ./scripts/build-app.sh             build into dist/MouseTime.app
#   ./scripts/build-app.sh --install   ...then install to ~/Applications and
#                                      start it, taking over from the launchd
#                                      daemon if that is installed
#
# SwiftPM builds executables, not app bundles, and an app bundle is what
# notifications (UNUserNotificationCenter) and login items (SMAppService)
# require. So this assembles one around the SwiftPM binary.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

BUNDLE_ID="de.huskycare.MouseTime"
DAEMON_LABEL="de.huskycare.mousetime"
DAEMON_PLIST="$HOME/Library/LaunchAgents/$DAEMON_LABEL.plist"
APP="dist/MouseTime.app"
DEST="$HOME/Applications/MouseTime.app"

INSTALL=0
for arg in "$@"; do
	case "$arg" in
	--install) INSTALL=1 ;;
	*)
		echo "error: unknown argument \"$arg\"; expected --install" >&2
		exit 2
		;;
	esac
done

# When installing, build outside dist/: a second copy of the app lying around
# is one more thing that could get registered to launch at login.
if [[ $INSTALL -eq 1 ]]; then
	APP="$(mktemp -d)/MouseTime.app"
fi

VERSION="$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/mousetime/main.swift)"
if [[ -z "$VERSION" ]]; then
	echo "error: could not read the version from Sources/mousetime/main.swift" >&2
	exit 1
fi

echo "==> building MouseTime $VERSION"
swift build -c release --product MouseTimeBar
BUILT="$(swift build -c release --show-bin-path)/MouseTimeBar"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
install -m 755 "$BUILT" "$APP/Contents/MacOS/MouseTimeBar"
sed "s|__VERSION__|$VERSION|g" scripts/MouseTime-Info.plist >"$APP/Contents/Info.plist"

# Ad-hoc: no Developer ID behind this project. Enough for a stable identity,
# which is what notification and login-item permissions are keyed to.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

if [[ $INSTALL -eq 0 ]]; then
	echo ""
	echo "built $APP — run it with: open $APP"
	exit 0
fi

# Carry the daemon's flags over, so switching changes nothing about behaviour.
if [[ -f "$DAEMON_PLIST" ]]; then
	echo "==> carrying settings over from the launchd daemon"
	args="$(tr -d '\n\t ' <"$DAEMON_PLIST")"
	if [[ "$args" == *"<string>--suppress</string>"* ]]; then
		defaults write "$BUNDLE_ID" suppress -bool true
		echo "    phantom-input suppression: on"
	fi
	if [[ "$args" == *"<string>--battery</string>"* ]]; then
		defaults write "$BUNDLE_ID" batteryWarnings -bool true
		echo "    battery warnings: on"
	fi
	rate="$(sed -n 's|.*<string>--rate</string><string>\([0-9]*\)</string>.*|\1|p' <<<"$args")"
	if [[ -n "$rate" ]]; then
		defaults write "$BUNDLE_ID" holdRate -int "$rate"
		echo "    report rate: held at $rate Hz"
	fi

	# Two processes driving the receiver could interleave their command
	# sequences, so the daemon goes before the app starts.
	echo "==> stopping the launchd daemon (the app replaces it)"
	launchctl bootout "gui/$UID/$DAEMON_LABEL" 2>/dev/null || true
	rm -f "$DAEMON_PLIST"
fi

echo "==> installing to $DEST"
osascript -e 'quit app id "'"$BUNDLE_ID"'"' 2>/dev/null || true
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
rm -rf "$(dirname "$APP")"

echo "==> starting"
open "$DEST"

cat <<EOF

installed. MouseTime is in the menu bar, and starts at login (toggle in its
menu). The log is where it was: tail -f ~/Library/Logs/mousetime.log
EOF
