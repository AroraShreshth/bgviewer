#!/bin/bash
# Local release build: stamps the version, runs the FULL test suite,
# builds, and produces dist/bgviewer-<version>.zip with a checksum.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>   e.g. ./release.sh 1.0.0}"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
echo "→ Version stamped: $VERSION"

./test.sh
./build.sh

mkdir -p dist
ZIP="dist/bgviewer-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent bgviewer.app "$ZIP"
shasum -a 256 "$ZIP" | tee "dist/bgviewer-$VERSION.sha256"

cat <<EOF

✓ $ZIP ready.

To publish (after pushing the repo to GitHub):
  git add -A && git commit -m "release: v$VERSION"
  git tag "v$VERSION"
  git push origin main --tags     # the Release workflow attaches the zip
EOF
