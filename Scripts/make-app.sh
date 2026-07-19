#!/bin/zsh
# Builds RhythmCoach.app from the SwiftPM build (no Xcode needed).
# usage: make-app.sh [debug|release] [--universal]
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
UNIVERSAL="${2:-}"

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
    <key>CFBundleShortVersionString</key><string>1.1.3</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>RhythmCoach records your guitar to measure your timing against the click.</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/RhythmCoach" 2>/dev/null || echo '?'))"
