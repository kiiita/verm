#!/bin/bash
# Build Verm and assemble a proper .app bundle.
# A real bundle with NSMicrophoneUsageDescription is what lets macOS grant the
# mic (the wall cmux hit).
#
# Signing: we sign with a STABLE Apple Development identity (not ad-hoc). macOS
# TCC keys the mic grant off the code signature's designated requirement
# (Team ID + bundle id). Ad-hoc signing produces a fresh cdhash every build, so
# the grant was re-prompted on every rebuild. A stable identity keeps the same
# designated requirement across rebuilds -> grant the mic once, it sticks.
# (Hardened runtime is intentionally NOT enabled here: it would require the
#  audio-input entitlement to avoid blocking the mic. That belongs in the
#  Developer ID / notarized distribution build — see docs/PRODUCTION_READINESS.md.)
set -euo pipefail
DIR="/Users/kiiita/Dev/verm/poc"
APP="$DIR/Verm.app"
SIGN_ID="935AC99AFA6CD594FBE30D12B0B705474B0392DE"  # Apple Development: Yuto Kitakuni (3WYWE9BR5N)

swift build --package-path "$DIR" -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$DIR/.build/release/Verm" "$APP/Contents/MacOS/Verm"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Verm</string>
  <key>CFBundleIdentifier</key><string>com.kiiita.verm</string>
  <key>CFBundleName</key><string>Verm</string>
  <key>CFBundleDisplayName</key><string>Verm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSMicrophoneUsageDescription</key><string>音声入力ループでマイクを使用します。</string>
</dict>
</plist>
PLIST

# Bundle Ghostty resources (terminfo + shell-integration) so libghostty can load
# shell integration and report the working directory (OSC 7) -> live tab titles.
# Sourced from cmux's bundle (Ghostty's MIT resources, version-matched).
GRES="/Applications/cmux.app/Contents/Resources"
RDST="$APP/Contents/Resources"
mkdir -p "$RDST"
[ -d "$GRES/terminfo" ]      && cp -R "$GRES/terminfo" "$RDST/"
[ -d "$GRES/ghostty" ]       && cp -R "$GRES/ghostty" "$RDST/"
[ -f "$GRES/xterm-ghostty" ] && cp "$GRES/xterm-ghostty" "$RDST/"

# App icon
[ -f "$DIR/Icon/AppIcon.icns" ] && cp "$DIR/Icon/AppIcon.icns" "$RDST/AppIcon.icns"

codesign --force --sign "$SIGN_ID" "$APP"
echo "built: $APP"
