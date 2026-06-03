#!/bin/bash
# Build the PoC and assemble a proper .app bundle.
# A real bundle with NSMicrophoneUsageDescription is what lets macOS grant the
# mic (the wall cmux hit). Ad-hoc codesign is enough for local use.
set -euo pipefail
DIR="/Users/kiiita/Dev/verm/poc"
APP="$DIR/VoiceTerm.app"

swift build --package-path "$DIR" -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$DIR/.build/release/VoiceTermPoC" "$APP/Contents/MacOS/VoiceTerm"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>VoiceTerm</string>
  <key>CFBundleIdentifier</key><string>com.kiiita.voiceterm.poc</string>
  <key>CFBundleName</key><string>VoiceTerm PoC</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>音声入力ループのPoCでマイクを使用します。</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "built: $APP"
