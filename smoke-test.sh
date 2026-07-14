#!/bin/bash
# End-to-end install smoke test: package the built app exactly like the release
# workflow, install it exactly like install.sh, then launch it and prove it
# stays up. Run after ./build.sh; used by CI and the release pipeline so no
# build ships unless it demonstrably runs on macOS.
set -euo pipefail
cd "$(dirname "$0")"

[ -d bgviewer.app ] || { echo "✗ bgviewer.app not found — run ./build.sh first"; exit 1; }

WORK=$(mktemp -d)
TARGET=""
cleanup() {
	[ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
	[ -n "$TARGET" ] && rm -rf "$TARGET"
	rm -rf "$WORK"
}
trap cleanup EXIT

echo "→ Package (as the release workflow does)…"
ditto -c -k --keepParent bgviewer.app "$WORK/bgviewer.zip"

echo "→ Extract (as install.sh does)…"
ditto -xk "$WORK/bgviewer.zip" "$WORK/extract"

# Install to /Applications when writable (CI runners, most Macs), else ~/Applications.
# A unique name keeps this from ever touching a real install of bgviewer.
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
TARGET="$DEST/bgviewer-smoketest.app"
rm -rf "$TARGET"
ditto "$WORK/extract/bgviewer.app" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
echo "  installed to $TARGET"

echo "→ Verify the installed bundle…"
lipo -info "$TARGET/Contents/MacOS/bgviewer" | grep -q "x86_64 arm64" \
	&& echo "  ✓ universal binary (x86_64 + arm64)" \
	|| { echo "  ✗ not a universal binary"; exit 1; }
codesign --verify --deep --strict "$TARGET" \
	&& echo "  ✓ signature intact after zip round-trip" \
	|| { echo "  ✗ signature broken by packaging"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TARGET/Contents/Info.plist")
[ -n "$VER" ] && echo "  ✓ version stamped: $VER" || { echo "  ✗ no version"; exit 1; }
[ -f "$TARGET/Contents/Resources/AppIcon.icns" ] \
	&& echo "  ✓ app icon present" || { echo "  ✗ AppIcon.icns missing"; exit 1; }

echo "→ Launch and hold for 9 seconds…"
# -n forces a fresh instance even if a real bgviewer is already running;
# -g keeps it in the background. pgrep on the smoketest path isolates our copy.
open -g -n "$TARGET"
sleep 6
PID=$(pgrep -f "$TARGET/Contents/MacOS/bgviewer" | head -1)
[ -n "$PID" ] && echo "  ✓ launched (pid $PID)" || { echo "  ✗ app did not launch"; exit 1; }
sleep 3
kill -0 "$PID" 2>/dev/null \
	&& echo "  ✓ still alive after 9s — no startup crash" \
	|| { echo "  ✗ app died within 9s of launching"; exit 1; }

echo
echo "✓ Install smoke test passed — build installs and runs on this macOS ($(sw_vers -productVersion))"
