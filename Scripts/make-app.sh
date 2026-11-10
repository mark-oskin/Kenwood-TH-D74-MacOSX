#!/bin/sh
# Builds "TH-D74 Programmer.app" into ./build from the Swift package.
set -e
cd "$(dirname "$0")/.."

# A universal binary, so the app runs on both Apple silicon and Intel Macs.
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product THD74App
BIN="$(swift build -c release $ARCHS --show-bin-path)/THD74App"

APP="build/TH-D74 Programmer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/THD74App"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>TH-D74 Programmer</string>
    <key>CFBundleDisplayName</key><string>TH-D74 Programmer</string>
    <key>CFBundleIdentifier</key><string>local.thd74.programmer</string>
    <key>CFBundleExecutable</key><string>THD74App</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Connects to your TH-D74 over Bluetooth to read and program its memory channels.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
