#!/bin/zsh
# Builds RhythmCoach.app from the SwiftPM release build (no Xcode needed).
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"

echo "building ($CONFIG)..."
swift build -c "$CONFIG" --product RhythmCoach

APP="dist/RhythmCoach.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/$CONFIG/RhythmCoach" "$APP/Contents/MacOS/RhythmCoach"

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
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>RhythmCoach records your guitar to measure your timing against the click.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built $APP"
