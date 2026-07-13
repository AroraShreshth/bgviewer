#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="bgviewer.app"
BIN="$APP/Contents/MacOS/bgviewer"

echo "→ Building bgviewer…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -parse-as-library -swift-version 5 \
	-target arm64-apple-macos13.0 \
	Sources/Shell.swift \
	Sources/Models.swift \
	Sources/ServiceScanner.swift \
	Sources/ServiceControl.swift \
	Sources/ServiceStore.swift \
	Sources/Views.swift \
	Sources/BgviewerApp.swift \
	-framework SwiftUI -framework AppKit -framework Foundation \
	-o "$BIN"

# Ad-hoc sign so macOS gives it a stable identity across launches.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built ./$APP"
