#!/bin/sh
# Builds a Developer ID signed, notarized "TH-D74 Programmer.app" and zips it
# into build/release/TH-D74-Programmer.zip.
#
# Signing uses Xcode's automatic (cloud-managed) Developer ID signing, so no
# certificate is needed in the local keychain: Xcode must be signed in to an
# Apple developer account for the team below. Notarization uses credentials
# saved beforehand with:
#
#     xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
#
# Usage: Scripts/release.sh <team-id> <notary-profile>
set -e
cd "$(dirname "$0")/.."

TEAM="${1:?usage: Scripts/release.sh <team-id> <notary-profile>}"
PROFILE="${2:?usage: Scripts/release.sh <team-id> <notary-profile>}"
NAME="TH-D74 Programmer"
BUNDLE_ID="io.github.mark-oskin.THD74Programmer"
OUT="build/release"

./Scripts/make-app.sh
# The hardened runtime flag has to be on before export; the export keeps it.
codesign --force --options runtime --sign - "build/$NAME.app"

# Wrap the app in an Xcode archive so that xcodebuild can export and sign it.
rm -rf "$OUT"
ARCHIVE="$OUT/THD74.xcarchive"
mkdir -p "$ARCHIVE/Products/Applications"
cp -R "build/$NAME.app" "$ARCHIVE/Products/Applications/"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "build/$NAME.app/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "build/$NAME.app/Contents/Info.plist")
cat > "$ARCHIVE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>ApplicationProperties</key>
	<dict>
		<key>ApplicationPath</key><string>Applications/$NAME.app</string>
		<key>Architectures</key><array><string>arm64</string><string>x86_64</string></array>
		<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
		<key>CFBundleShortVersionString</key><string>$VERSION</string>
		<key>CFBundleVersion</key><string>$BUILD</string>
		<key>SigningIdentity</key><string>-</string>
		<key>Team</key><string>$TEAM</string>
	</dict>
	<key>ArchiveVersion</key><integer>2</integer>
	<key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
	<key>Name</key><string>$NAME</string>
	<key>SchemeName</key><string>THD74App</string>
</dict>
</plist>
PLIST
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
    -exportPath "$OUT/export" -allowProvisioningUpdates
APP="$OUT/export/$NAME.app"
codesign --verify --deep --strict "$APP"

ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"

rm -f "$OUT/TH-D74-Programmer.zip"
ditto -c -k --keepParent "$APP" "$OUT/TH-D74-Programmer.zip"
echo "Release build: $OUT/TH-D74-Programmer.zip"
shasum -a 256 "$OUT/TH-D74-Programmer.zip"
