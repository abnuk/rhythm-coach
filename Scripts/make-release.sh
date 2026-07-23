#!/bin/zsh
# Builds distributable artifacts: universal RhythmCoach.app packed as
# a drag-to-Applications DMG and a zip.
# usage: make-release.sh [version]
#
# Signing/notarization (optional, driven by env — see make-app.sh for SIGN_ID):
#   SIGN_ID         Developer ID identity passed through to codesign.
#   NOTARY_PROFILE  notarytool keychain profile; when set, the app and the DMG
#                   are notarized + stapled so Gatekeeper stays quiet offline.
# Example once the Developer account is active:
#   SIGN_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=rc-notary \
#     ./Scripts/make-release.sh
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-1.1.4}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
SIGN_ID="${SIGN_ID:-}"

./Scripts/make-app.sh release --universal
APP="dist/RhythmCoach.app"

# Notarize + staple the app first, so the extracted .app is trusted offline.
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "notarizing app ($NOTARY_PROFILE)..."
    TMP="$(mktemp -d)"
    ditto -c -k --keepParent "$APP" "$TMP/app.zip"
    xcrun notarytool submit "$TMP/app.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -rf "$TMP"
fi

DMG="dist/RhythmCoach-$VERSION.dmg"
ZIP="dist/RhythmCoach-$VERSION-macos.zip"
rm -f "$DMG" "$ZIP"

STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "RhythmCoach $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

ditto -c -k --keepParent "$APP" "$ZIP"

# Sign + notarize + staple the DMG too. The DMG must carry its OWN Developer ID
# signature: an unsigned DMG, even when notarized, fails `spctl -t open` with
# "no usable signature", so Gatekeeper warns when the downloaded image is opened.
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "signing + notarizing dmg..."
    [[ -n "$SIGN_ID" ]] && codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "artifacts:"
ls -lh "$DMG" "$ZIP" | awk '{print "  " $9 " (" $5 ")"}'
if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "note: NOTARY_PROFILE unset -> artifacts are NOT notarized; Gatekeeper will warn on download."
fi
