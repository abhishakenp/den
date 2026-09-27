#!/bin/zsh
# Builds build/den.app: release build, plugins, Info.plist, entitlements, stable ad-hoc signature.
# The bundle id (io.github.abhishakenp.den) and the ad-hoc identity never change, so macOS
# keeps TCC grants and default-browser registration across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Den
BIN="$(swift build -c release --show-bin-path)/Den"
APP=build/den.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Den"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Every Plugins/<id>/ becomes Contents/PlugIns/<id>.dylib (Embedded Swift, via cordis-build).
# Plugins/Shared/ is compiled into each plugin. Builds run in parallel.
CORDIS_BUILD=.build/checkouts/cordis-swift/Scripts/cordis-build
mkdir -p "$APP/Contents/PlugIns"
pids=()
for dir in Plugins/*/; do
  id="$(basename "$dir")"
  [[ "$id" == Shared ]] && continue
  "$CORDIS_BUILD" --id "$id" --out "$APP/Contents/PlugIns/$id.dylib" "$dir"*.swift Plugins/Shared/*.swift &
  pids+=($!)
done
for p in $pids; do wait $p; done
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --deep --options runtime --entitlements Resources/den.entitlements --sign - "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
