#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
swift build -c release
bin="$(swift build -c release --show-bin-path)/MobileTunnelManager"
app="$PWD/dist/Mobile Tunnel Manager.app"
icon_work="$(mktemp -d)"
trap 'rm -R -- "$icon_work"' EXIT
iconset="$icon_work/AppIcon.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
for size in 16 32 128 256 512; do
  retina_size=$((size * 2))
  sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z "$retina_size" "$retina_size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
install -m 755 "$bin" "$app/Contents/MacOS/MobileTunnelManager"
install -m 644 AppInfo.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
touch "$app"
printf '%s\n' "$app"
