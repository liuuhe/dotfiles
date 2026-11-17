#!/bin/zsh
set -euo pipefail

mouse_dir=${0:A:h}
executable=${1:-"$HOME/Library/Application Support/Hammerspoon/MouseScroll"}
build_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/mouse-scroll-build.XXXXXX")
trap '/bin/rm -rf -- "$build_dir"' EXIT

/usr/bin/xcrun --sdk macosx swiftc \
    -swift-version 5 -O \
    -module-cache-path "$build_dir/modules" \
    -framework Foundation -framework CoreGraphics -framework IOKit \
    "$mouse_dir/mouse.swift" \
    -o "$build_dir/MouseScroll"

/usr/bin/codesign --force --sign - \
    --identifier local.hammerspoon.mouse-scroll "$build_dir/MouseScroll"
/bin/mkdir -p "${executable:h}"
/bin/mv -f "$build_dir/MouseScroll" "$executable"
printf 'Built: %s\n' "$executable"
