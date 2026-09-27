#!/bin/zsh
# Builds build/den.app: release build, Info.plist, entitlements, stable ad-hoc signature.
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
cp Resources/den.icns "$APP/Contents/Resources/den.icns"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --deep --options runtime --entitlements Resources/den.entitlements --sign - "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
