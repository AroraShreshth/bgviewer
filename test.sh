#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

BIN="$(mktemp -d)/bgtest"
echo "→ Compiling tests…"
swiftc -O -swift-version 5 \
	Sources/Shell.swift \
	Sources/Models.swift \
	Sources/ServiceScanner.swift \
	Sources/ServiceControl.swift \
	Sources/DiskScanner.swift \
	Sources/DiskMap.swift \
	Sources/DevJunk.swift \
	Sources/Updater.swift \
	Tests/main.swift \
	-o "$BIN"

echo "→ Running tests…"
echo
"$BIN" "$@"
