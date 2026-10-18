#!/bin/bash
# Publishes a new version on GitHub:  ./release.sh 1.2 ["What changed"]
# Bumps the version in Info.plist, builds, tags and uploads the zip (used by the in-app
# updater) and the disk image (for first-time installs). Running copies show an "Update" button.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?Usage: ./release.sh <version> [release notes]}"
NOTES="${2:-}"
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then echo "Commit or stash your changes first."; exit 1; fi
if git rev-parse "$TAG" >/dev/null 2>&1; then echo "$TAG already exists."; exit 1; fi

plutil -replace CFBundleShortVersionString -string "$VERSION" Info.plist
BUILD=$(( $(plutil -extract CFBundleVersion raw Info.plist) + 1 ))
plutil -replace CFBundleVersion -string "$BUILD" Info.plist

./package.sh
ZIP="build/PDF-Narrator.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "build/PDF Narrator.app" "$ZIP"

git commit -qam "Release $TAG"
git tag "$TAG"
git push -q origin HEAD "$TAG"
if [ -n "$NOTES" ]; then
    gh release create "$TAG" "$ZIP" build/PDF-Narrator.dmg --title "PDF Narrator $VERSION" --notes "$NOTES"
else
    gh release create "$TAG" "$ZIP" build/PDF-Narrator.dmg --title "PDF Narrator $VERSION" --generate-notes
fi
