#!/bin/zsh
# Builds distributable artifacts: universal RhythmCoach.app packed as
# a drag-to-Applications DMG and a zip.
# usage: make-release.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-1.1.2}"

./Scripts/make-app.sh release --universal

DMG="dist/RhythmCoach-$VERSION.dmg"
ZIP="dist/RhythmCoach-$VERSION-macos.zip"
rm -f "$DMG" "$ZIP"

STAGE="$(mktemp -d)"
cp -R dist/RhythmCoach.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "RhythmCoach $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

ditto -c -k --keepParent dist/RhythmCoach.app "$ZIP"

echo "artifacts:"
ls -lh "$DMG" "$ZIP" | awk '{print "  " $9 " (" $5 ")"}'
