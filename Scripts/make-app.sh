#!/bin/zsh
# Builds RhythmCoach.app from the SwiftPM build (no Xcode needed).
# usage: make-app.sh [debug|release] [--universal]
#
# Signing (optional): set SIGN_ID to a Developer ID identity to sign with
# hardened runtime + entitlements (required for notarization). When empty,
# falls back to the ad-hoc signature so local builds keep working.
#   SIGN_ID="Developer ID Application: Name (TEAMID)" ./Scripts/make-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
UNIVERSAL="${2:-}"
SIGN_ID="${SIGN_ID:-}"

APP="dist/RhythmCoach.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "$UNIVERSAL" == "--universal" ]]; then
    echo "building universal ($CONFIG)..."
    swift build -c "$CONFIG" --product RhythmCoach --triple arm64-apple-macosx
    swift build -c "$CONFIG" --product RhythmCoach --triple x86_64-apple-macosx
    lipo -create \
        ".build/arm64-apple-macosx/$CONFIG/RhythmCoach" \
        ".build/x86_64-apple-macosx/$CONFIG/RhythmCoach" \
        -output "$APP/Contents/MacOS/RhythmCoach"
else
    echo "building ($CONFIG)..."
    swift build -c "$CONFIG" --product RhythmCoach
    cp ".build/$CONFIG/RhythmCoach" "$APP/Contents/MacOS/RhythmCoach"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>RhythmCoach</string>
    <key>CFBundleIdentifier</key><string>com.abnuk.rhythmcoach</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>RhythmCoach</string>
    <key>CFBundleDisplayName</key><string>RhythmCoach</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1.4</string>
    <key>CFBundleVersion</key><string>6</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>RhythmCoach records your guitar to measure your timing against the click.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "$SIGN_ID" ]]; then
    echo "signing with Developer ID: $SIGN_ID"
    codesign --force --options runtime --timestamp \
        --entitlements Resources/RhythmCoach.entitlements \
        --sign "$SIGN_ID" "$APP"
else
    echo "ad-hoc signing (set SIGN_ID for a Developer ID signature)"
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/RhythmCoach" 2>/dev/null || echo '?'))"
