#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
app_path="$script_dir/.build/USB16x16 Latency.app"
contents_path="$app_path/Contents"

CLANG_MODULE_CACHE_PATH=/private/tmp/usb16x16-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/usb16x16-swiftpm-cache \
swift build -c release --package-path "$script_dir"

mkdir -p "$contents_path/MacOS"
/bin/cp "$script_dir/.build/release/usb16x16-latency" \
    "$contents_path/MacOS/usb16x16-latency"
/bin/cp "$script_dir/Support/Info.plist" "$contents_path/Info.plist"
plutil -lint "$contents_path/Info.plist"
codesign --force --sign - --timestamp=none "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

print -r -- "$app_path"
