#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP="bgviewer.app"
BIN="$APP/Contents/MacOS/bgviewer"

echo "→ Building bgviewer…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/"

# Universal binary: build each slice, then lipo them together.
SLICES=()
for ARCH in arm64 x86_64; do
	swiftc -O -parse-as-library -swift-version 5 \
		-target "$ARCH-apple-macos13.0" \
		Sources/Shell.swift \
		Sources/Models.swift \
		Sources/ServiceScanner.swift \
		Sources/ServiceControl.swift \
		Sources/DiskScanner.swift \
		Sources/DiskMap.swift \
		Sources/DevJunk.swift \
		Sources/Updater.swift \
		Sources/DiskMapWindow.swift \
		Sources/ServiceStore.swift \
		Sources/Views.swift \
		Sources/BgviewerApp.swift \
		-framework SwiftUI -framework AppKit -framework Foundation \
		-framework ServiceManagement -framework UserNotifications \
		-o "$BIN-$ARCH"
	SLICES+=("$BIN-$ARCH")
done
lipo -create "${SLICES[@]}" -output "$BIN"
rm -f "${SLICES[@]}"

# Ad-hoc sign so macOS gives it a stable identity across launches.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built ./$APP"
