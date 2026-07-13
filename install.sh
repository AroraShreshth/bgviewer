#!/bin/bash
# bgviewer installer — downloads the latest release, installs it to
# /Applications, clears the quarantine flag (the app isn't notarized yet),
# and launches it.
#
#   curl -fsSL https://raw.githubusercontent.com/AroraShreshth/bgviewer/main/install.sh | bash
set -euo pipefail

REPO="AroraShreshth/bgviewer"
API="https://api.github.com/repos/$REPO/releases/latest"

echo "→ Finding the latest bgviewer release…"
URL=$(curl -fsSL "$API" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)
[ -n "$URL" ] || { echo "✗ Couldn't find a release asset. See https://github.com/$REPO/releases"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ Downloading $(basename "$URL")…"
curl -fsSL "$URL" -o "$TMP/bgviewer.zip"

echo "→ Installing to /Applications…"
ditto -xk "$TMP/bgviewer.zip" "$TMP/extract"
rm -rf /Applications/bgviewer.app
ditto "$TMP/extract/bgviewer.app" /Applications/bgviewer.app

# Not notarized yet, so Gatekeeper would block the first launch — clear the
# quarantine flag the download put there.
xattr -dr com.apple.quarantine /Applications/bgviewer.app 2>/dev/null || true

echo "→ Launching…"
open /Applications/bgviewer.app
echo "✓ Done — look for the gauge icon in your menu bar (top right)."
