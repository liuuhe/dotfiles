#!/bin/zsh
set -euo pipefail

picker_dir=${0:A:h}
bundle_dir="$HOME/Library/Application Support/Hammerspoon/ScreenshotPicker.app"
cache_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/screenshot-picker-build.XXXXXX")
trap '/bin/rm -rf -- "$cache_dir"' EXIT
/bin/mkdir -p "$bundle_dir/Contents/MacOS"

/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 5 -O \
    -module-cache-path "$cache_dir" \
    -framework AppKit -framework CoreGraphics \
    "$picker_dir/picker.swift" \
    -o "$bundle_dir/Contents/MacOS/ScreenshotPicker"

/bin/cat > "$bundle_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>local.hammerspoon.screenshot-picker</string>
    <key>CFBundleName</key><string>Screenshot Picker</string>
    <key>CFBundleExecutable</key><string>ScreenshotPicker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

/usr/bin/codesign --force --sign - "$bundle_dir"
printf 'Built: %s\n' "$bundle_dir"
