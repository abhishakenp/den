# App Intents metadata for a SwiftPM-built app (sourced by scripts/bundle.sh).
#
# The system lists an app's Shortcuts / Siri / Spotlight actions from
# Contents/Resources/Metadata.appintents. Xcode extracts it at build time; SwiftPM doesn't, so this
# does what Xcode 26's ExtractAppIntentsMetadata step does: swiftc emits each module's constant
# values (appintents_swift_flags), then appintentsmetadataprocessor runs once per module, the
# library (DenHost: the intents and entities) first, then the app module (Den: the App Shortcuts
# phrases) with the library's result linked in. A failure stops the build: a broken intent would
# otherwise ship silently.

# The protocols whose conformances swiftc records (Xcode 26.5's list).
appintents_protocols() {
  print -r -- '["AnyResolverProviding","AppEntity","AppEnum","AppExtension","AppIntent","AppIntentsPackage","AppShortcutProviding","AppShortcutsProvider","DynamicOptionsProvider","EntityQuery","ExtensionPointDefining","IntentValueQuery","Resolver","TransientEntity","_AssistantIntentsProvider","_GenerativeFunctionExtractable","_IntentValueRepresentable"]' > "$1"
}

# swift build flags that make swiftc write <Module>.swiftconstvalues next to its objects.
#   appintents_swift_flags <protocols.json>
appintents_swift_flags() {
  print -r -- -Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file -Xswiftc -Xfrontend -Xswiftc "$1"
}

# appintents_extract <bin dir> <bundle id> <out Resources dir> <work dir> <lib module> <app module>
appintents_extract() {
  local bin=$1 bundle_id=$2 resources=$3 work=$4 lib=$5 app=$6
  local sdk tc xcv deploy=26.0
  sdk=$(xcrun --sdk macosx --show-sdk-path)
  tc=${$(xcrun --find swiftc):h:h:h}
  xcv=$(xcodebuild -version 2>/dev/null | awk '/Build version/{print $3}')
  rm -rf "$work"; mkdir -p "$work"
  : > "$work/empty.list"
  _appintents_run() {  # module output binary static-list
    local m=$1 out=$2 binary=$3 static=$4
    local cv="$bin/$m.build/$m.swiftconstvalues"
    [[ -f $cv ]] || { print -u2 "appintents: no constant values for $m ($cv); touch its sources and rebuild"; return 1; }
    find "Sources/$m" -name '*.swift' > "$work/$m.SwiftFileList"
    print -r -- "$cv" > "$work/$m.SwiftConstValuesFileList"
    xcrun appintentsmetadataprocessor \
      --toolchain-dir "$tc" --module-name "$m" --sdk-root "$sdk" \
      --xcode-version "$xcv" --platform-family macOS --deployment-target $deploy \
      --bundle-identifier "$bundle_id" --output "$out" \
      --target-triple "arm64-apple-macos$deploy" --binary-file "$binary" \
      --dependency-file "$work/$m.dependency_info.dat" \
      --stringsdata-file "$work/$m.ExtractedAppShortcutsMetadata.stringsdata" \
      --source-file-list "$work/$m.SwiftFileList" \
      --metadata-file-list "$work/empty.list" \
      --static-metadata-file-list "$static" \
      --swift-const-vals-list "$work/$m.SwiftConstValuesFileList" \
      --force --compile-time-extraction --deployment-aware-processing \
      --validate-assistant-intents --no-app-shortcuts-localization >"$work/$m.log" 2>&1 \
      || { cat "$work/$m.log" >&2; print -u2 "appintents: metadata extraction failed for $m"; return 1; }
  }
  local libobj=(${bin}/${lib}.build/*.o(N))
  (( ${#libobj} )) || { print -u2 "appintents: no objects for $lib in $bin"; return 1; }
  _appintents_run "$lib" "$work/$lib.appintents" "${libobj[1]}" "$work/empty.list" || return 1
  print -r -- "$work/$lib.appintents/Metadata.appintents/extract.actionsdata" > "$work/$app.static.list"
  _appintents_run "$app" "$work/app" "$bin/$app" "$work/$app.static.list" || return 1
  [[ -f "$work/app/Metadata.appintents/extract.actionsdata" ]] || { print -u2 "appintents: no extract.actionsdata"; return 1; }
  rm -rf "$resources/Metadata.appintents"
  cp -R "$work/app/Metadata.appintents" "$resources/"
}
