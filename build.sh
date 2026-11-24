#!/bin/sh
# Builds AutoTH.app (menu-bar only). Run: ./build.sh && open AutoTH.app
set -e
cd "$(dirname "$0")"
mkdir -p AutoTH.app/Contents/MacOS AutoTH.app/Contents/Resources
cp dict/thaidict.txt AutoTH.app/Contents/Resources/
# Universal (Apple silicon + Intel), runs on macOS 13+
tmp=$(mktemp -d)
for arch in arm64 x86_64; do swiftc -O -target $arch-apple-macos13 main.swift -o "$tmp/$arch"; done
lipo -create "$tmp/arm64" "$tmp/x86_64" -output AutoTH.app/Contents/MacOS/AutoTH
rm -rf "$tmp"
cat > AutoTH.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.autoth</string>
<key>CFBundleName</key><string>AutoTH</string>
<key>CFBundleExecutable</key><string>AutoTH</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - AutoTH.app
AutoTH.app/Contents/MacOS/AutoTH --selftest
