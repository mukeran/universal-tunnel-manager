#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
swift build -c release "$@"
bin="$(swift build -c release "$@" --show-bin-path)/UniversalTunnelManager"
app="$PWD/dist/Universal Tunnel Manager.app"
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
# English uses source strings as keys. Keep an English bundle for explicit lookups.
mkdir -p "$app/Contents/Resources/en.lproj"
printf '/* English strings are the localization keys. */\n' > "$app/Contents/Resources/en.lproj/Localizable.strings"
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$app/Contents/Resources"
install -m 644 LICENSE "$app/Contents/Resources/LICENSE.txt"
install -m 644 ThirdParty/SSHTunnelManager/LICENSE "$app/Contents/Resources/SSH-Tunnel-Manager-LICENSE.txt"
install -m 755 "$bin" "$app/Contents/MacOS/UniversalTunnelManager"
install -m 644 AppInfo.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
touch "$app"
printf '%s\n' "$app"
