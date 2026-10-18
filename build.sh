#!/bin/bash
# Builds a universal (Apple Silicon + Intel) "PDF Narrator.app" into ./build
# using only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/PDF Narrator.app"
TMP="build/tmp"
rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TMP"

for arch in arm64 x86_64; do
    swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos14.0" \
        Sources/PDFNarrator.swift -o "$TMP/PDFNarrator-$arch"
done
lipo -create "$TMP"/PDFNarrator-arm64 "$TMP"/PDFNarrator-x86_64 -output "$APP/Contents/MacOS/PDFNarrator"

# App icon
swiftc Tools/MakeIcon.swift -o "$TMP/MakeIcon"
"$TMP/MakeIcon" "$TMP/icon.png"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$TMP/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$TMP/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"
rm -rf "$TMP"
echo "Built $APP"
