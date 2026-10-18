#!/bin/bash
# Builds the app and wraps it in a drag-to-install disk image: build/PDF-Narrator.dmg
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
STAGE="build/dmg"
DMG="build/PDF-Narrator.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "build/PDF Narrator.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "INSTALL.txt" "$STAGE/Read Me First.txt"
hdiutil create -volname "PDF Narrator" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Created $DMG"
