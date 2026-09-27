#!/bin/zsh
# Builds build/den.app: release build, plugins, Info.plist, entitlements, stable signature.
# The bundle id (io.github.abhishakenp.den) and the signing identity never change, so macOS
# keeps TCC grants, Keychain access and default-browser registration across rebuilds
# (run scripts/make-signing-identity.sh once; without it the signature is ad hoc).
# DEN_SCENARIOS=1 keeps the `Scenarios` package trait (--scenario fixtures, MockServices) for
# scripts/snapshots.sh; by default the release app is built without it (no fixtures, no Network.framework).
set -euo pipefail
cd "$(dirname "$0")/.."
traits=(--disable-default-traits)
[[ -n ${DEN_SCENARIOS:-} ]] && traits=()
swift build -c release --product Den $traits
BIN="$(swift build -c release --show-bin-path)/Den"
APP=build/den.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Lowercase, like the app name: Spotlight and launchers (Raycast) match "den" against it.
cp "$BIN" "$APP/Contents/MacOS/den"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Build identity (docs/updates.md). DenHostAPI counts the commits that changed the host: a managed
# plugin only loads into a host of the generation it was built for. CFBundleVersion is monotonic
# for Sparkle. DEN_VERSION / DEN_BUILD override (scripts/release.sh, tests of older builds).
PL="$APP/Contents/Info.plist"
commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
git diff --quiet HEAD -- Sources Plugins Package.swift Package.resolved Resources 2>/dev/null || commit="$commit-dirty"
plutil -replace DenCommit -string "$commit" "$PL"
plutil -replace DenHostAPI -integer "$(git rev-list --count HEAD -- Sources Package.swift Package.resolved 2>/dev/null || echo 0)" "$PL"
plutil -replace DenScenarios -bool "$([[ -n ${DEN_SCENARIOS:-} ]] && echo YES || echo NO)" "$PL"
plutil -replace DenBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PL"
plutil -replace CFBundleVersion -string "${DEN_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}" "$PL"
[[ -n ${DEN_VERSION:-} ]] && plutil -replace CFBundleShortVersionString -string "$DEN_VERSION" "$PL"
# Sparkle (host updates), next to the binary.
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/den" 2>/dev/null || true
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Every Plugins/<id>/ becomes Contents/PlugIns/<id>.dylib (Embedded Swift, via cordis-build).
# Plugins/Shared/ is compiled into each plugin. Builds run in parallel.
CORDIS_BUILD=.build/checkouts/cordis-swift/Scripts/cordis-build
mkdir -p "$APP/Contents/PlugIns"
pids=()
for dir in Plugins/*/; do
  id="$(basename "$dir")"
  [[ "$id" == Shared ]] && continue
  # Declared permissions (session:<domain>, net:<domain>) ride next to the dylib as <id>.json.
  [[ -f "${dir}permissions.json" ]] && cp "${dir}permissions.json" "$APP/Contents/PlugIns/$id.json"
  # Files the plugin injects into pages (webviews.inject), read only when a feature is used.
  # (Under Resources: codesign --deep would take a folder in PlugIns for a nested bundle.)
  [[ -d "${dir}resources" ]] && mkdir -p "$APP/Contents/Resources/plugin-resources" && cp -R "${dir}resources" "$APP/Contents/Resources/plugin-resources/$id"
  "$CORDIS_BUILD" --id "$id" --out "$APP/Contents/PlugIns/$id.dylib" "$dir"*.swift Plugins/Shared/*.swift &
  pids+=($!)
done
for p in $pids; do wait $p; done
# cordis-build and its sources, so den can compile ~/.den/plugins/<id>/*.swift source plugins
# (den-shared = Plugins/Shared, compiled into each one like the bundled plugins).
CORDIS_ROOT=.build/checkouts/cordis-swift
RES="$APP/Contents/Resources/cordis"
mkdir -p "$RES/Scripts" "$RES/Sources/CCordis" "$RES/den-shared"
cp "$CORDIS_ROOT/Scripts/cordis-build" "$RES/Scripts/"
cp -R "$CORDIS_ROOT/Sources/CordisValue" "$CORDIS_ROOT/Sources/CordisKit" "$RES/Sources/"
cp -R "$CORDIS_ROOT/Sources/CCordis/include" "$RES/Sources/CCordis/"
cp Plugins/Shared/*.swift "$RES/den-shared/"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Signing identity: DEN_SIGN_IDENTITY if set (a name or SHA-1, "-" = ad hoc), else "den Local
# Signing" from scripts/make-signing-identity.sh when present (designated requirement = that
# certificate + bundle id, stable across rebuilds, so Keychain/TCC never re-ask), else ad hoc.
SIGN=${DEN_SIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null |
  awk 'index($0, "\"den Local Signing\"") { print $2; exit }')}
SIGN=${SIGN:--}
echo "signing with ${SIGN/#-/ad hoc}"
# Plugin dylibs are loose Mach-O files (not bundles), so --deep may skip them: sign explicitly.
for lib in "$APP"/Contents/PlugIns/*.dylib(N); do
  codesign --force --options runtime --sign "$SIGN" "$lib"
done
codesign --force --deep --options runtime --entitlements Resources/den.entitlements --sign "$SIGN" "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
