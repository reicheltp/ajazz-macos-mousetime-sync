#!/bin/bash
# Build a release archive: a universal binary plus everything needed to install
# it without a checkout.
#
#   ./scripts/package.sh
#
# Output lands in dist/. The GitHub release workflow calls this rather than
# repeating the steps in YAML, so what CI ships is what you can reproduce and
# test locally.
set -euo pipefail

LABEL="de.huskycare.mousetime"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

# The version in the source is the single source of truth; the release workflow
# checks the git tag against it rather than injecting a string at build time, so
# a published binary can never report a version it was not built as.
VERSION="$(sed -n 's/^let version = "\(.*\)"$/\1/p' Sources/mousetime/main.swift)"
if [[ -z "$VERSION" ]]; then
	echo "error: could not read the version from Sources/mousetime/main.swift" >&2
	exit 1
fi

NAME="mousetime-$VERSION-macos"
STAGE="dist/$NAME"

echo "==> mousetime $VERSION"

echo "==> testing"
swift test

echo "==> building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BUILT="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/mousetime"

# A single-architecture binary here would silently exclude every Intel Mac, and
# nothing else in the pipeline would notice.
ARCHS="$(lipo -archs "$BUILT")"
for want in arm64 x86_64; do
	case " $ARCHS " in
	*" $want "*) ;;
	*)
		echo "error: built binary lacks $want (has: $ARCHS)" >&2
		exit 1
		;;
	esac
done
echo "    architectures: $ARCHS"

echo "==> assembling $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/launchd"
install -m 755 "$BUILT" "$STAGE/mousetime"
install -m 755 launchd/install.sh "$STAGE/launchd/install.sh"
install -m 644 "launchd/$LABEL.plist" "$STAGE/launchd/$LABEL.plist"
install -m 644 README.md LICENSE "$STAGE/"
mkdir -p "$STAGE/docs"
install -m 644 docs/PROTOCOL.md "$STAGE/docs/PROTOCOL.md"

# Ad-hoc sign so the archive carries a consistent code identity. This does not
# satisfy Gatekeeper -- that needs a Developer ID and notarisation, which this
# project does not have -- but an unsigned binary is worse in every way.
codesign --force --sign - --identifier "$LABEL" "$STAGE/mousetime"
codesign --verify --verbose=1 "$STAGE/mousetime" 2>&1 | sed 's/^/    /'

echo "==> archiving"
ARCHIVE="dist/$NAME.tar.gz"
# --no-mac-metadata keeps AppleDouble ._ files out of the tarball; they are
# noise everywhere except the Mac that produced it.
tar --no-mac-metadata -czf "$ARCHIVE" -C dist "$NAME"
shasum -a 256 "$ARCHIVE" | sed "s| dist/| |" >"$ARCHIVE.sha256"

echo
echo "$ARCHIVE"
echo "$(cat "$ARCHIVE.sha256")"
echo
echo "contents:"
tar -tzf "$ARCHIVE" | sed 's/^/  /'
