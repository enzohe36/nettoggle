#!/bin/sh
# Build NetToggle.app into ~/Applications.
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/NetToggle.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
python3 make_icon.py
cp AppIcon.icns "$APP/Contents/Resources/"
# The overlay hides a duplicate Command Line Tools modulemap (redefinition of module SwiftBridging).
OVERLAY=$(mktemp -d)
: > "$OVERLAY/empty.modulemap"
cat > "$OVERLAY/vfs.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file",
  "name": "/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap",
  "external-contents": "$OVERLAY/empty.modulemap" } ] }
YAML
swiftc -parse-as-library -O -vfsoverlay "$OVERLAY/vfs.yaml" -Xcc -ivfsoverlay -Xcc "$OVERLAY/vfs.yaml" NetToggle.swift -o "$APP/Contents/MacOS/NetToggle"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>NetToggle</string>
  <key>CFBundleIdentifier</key><string>local.nettoggle</string>
  <key>CFBundleName</key><string>NetToggle</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
rm -rf "$OVERLAY"
codesign --force --sign - "$APP"
echo "Built $APP"
