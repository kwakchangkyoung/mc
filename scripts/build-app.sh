#!/bin/bash
# Builds build/MacClean.app from the SwiftPM executable (ad-hoc signed, for local runs).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release --product MacClean
bin_dir="$(swift build -c release --show-bin-path)"

app="$root/build/MacClean.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/MacClean" "$app/Contents/MacOS/MacClean"

cat > "$app/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.nitmus.macclean</string>
    <key>CFBundleName</key><string>MacClean</string>
    <key>CFBundleDisplayName</key><string>맥클린</string>
    <key>CFBundleExecutable</key><string>MacClean</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>ko</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "$app"
