# Shared by scripts/install.sh and scripts/dev-sync.sh. Source it from the repo root.
#   den_verify            build build/den.app and run swift test; nonzero if either fails
#   den_install [app]     quit the running den (SIGTERM: clean, no quit dialog), swap the app into
#                         /Applications, register it with LaunchServices/Spotlight, relaunch, and
#                         wait for the first window; prints the relaunch gap and session check
#   den_plugin <id>...    build Plugins/<id>/ into ~/.den/plugins/<id>.dylib (atomic, hot-swapped)

DEN_APP_DEST=${DEN_APP_DEST:-/Applications/den.app}
DEN_HOME_DIR=${DEN_HOME:-$HOME/.den}
DEN_LOG=$DEN_HOME_DIR/logs/den.log
DEN_MANAGED=$DEN_HOME_DIR/plugins/.dev-sync   # plugin ids dev-sync wrote (cleared on install)
CORDIS_BUILD=.build/checkouts/cordis-swift/Scripts/cordis-build

den_ms() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000'; }
den_say() { print -r -- "[$(date +%H:%M:%S)] $*"; }

den_verify() {
  local t0=$(den_ms)
  den_say "build: scripts/bundle.sh"
  scripts/bundle.sh > build/dev-sync-bundle.log 2>&1 || { den_say "build FAILED (build/dev-sync-bundle.log):"; grep -m5 -E "error:" build/dev-sync-bundle.log; return 1; }
  den_say "test: swift test"
  swift test > build/dev-sync-test.log 2>&1 || { den_say "tests FAILED (build/dev-sync-test.log):"; grep -m8 -E "error:|✘" build/dev-sync-test.log; return 1; }
  den_say "verified in $(( ($(den_ms) - t0) / 1000 )) s: $(grep -Eo 'Test run with [0-9]+ tests.*passed' build/dev-sync-test.log | tail -1)"
}

# Pids of the installed den (either executable name, before and after the rename to lowercase).
den_pids() { pgrep -f "^$DEN_APP_DEST/Contents/MacOS/[Dd]en( |\$)" || true; }

den_install() {
  local src=${1:-build/den.app}
  [[ -d $src ]] || { den_say "no $src"; return 1; }
  # Copy first, while the old den still runs, so the gap is only quit + rename + launch.
  rm -rf "$DEN_APP_DEST.new"
  ditto "$src" "$DEN_APP_DEST.new"
  codesign --verify --strict "$DEN_APP_DEST.new" || { den_say "signature check failed"; rm -rf "$DEN_APP_DEST.new"; return 1; }
  local lines=0; [[ -f $DEN_LOG ]] && lines=$(wc -l < $DEN_LOG)
  local t0=$(den_ms) pids=($(den_pids))
  for p in $pids; do kill -TERM $p 2>/dev/null || true; done
  local waited=0
  while [[ -n "$(den_pids)" ]]; do
    sleep 0.05; (( waited += 1 ))
    (( waited > 200 )) && { den_say "den did not quit within 10 s"; return 1; }
  done
  local t_quit=$(den_ms)
  rm -rf "$DEN_APP_DEST.old"
  [[ -d $DEN_APP_DEST ]] && mv "$DEN_APP_DEST" "$DEN_APP_DEST.old"
  mv "$DEN_APP_DEST.new" "$DEN_APP_DEST"
  rm -rf "$DEN_APP_DEST.old"
  # The new bundle has every plugin dev-sync built: drop those overrides so they can't go stale.
  if [[ -f $DEN_MANAGED ]]; then
    for id in $(sort -u $DEN_MANAGED); do rm -f "$DEN_HOME_DIR/plugins/$id.dylib"; done
    rm -f $DEN_MANAGED
  fi
  open "$DEN_APP_DEST"
  local t_open=$(den_ms)
  # LaunchServices + Spotlight (so launchers find "den"), off the relaunch path.
  ( /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEN_APP_DEST"
    mdimport "$DEN_APP_DEST" ) >/dev/null 2>&1 &
  local line="" tries=0
  while (( tries < 300 )); do
    line=$(tail -n +$((lines + 1)) $DEN_LOG 2>/dev/null | grep -m1 " launch pid=" || true)
    [[ -n $line ]] && break
    sleep 0.05; (( tries += 1 ))
  done
  [[ -n $line ]] || { den_say "no first window logged within 15 s (see $DEN_LOG)"; return 1; }
  local fw=$(print -r -- $line | sed -E 's/.*firstWindowEpochMs=([0-9]+).*/\1/')
  local launch=$(print -r -- $line | sed -E 's/.*firstWindowMs=([0-9.]+).*/\1/')
  den_say "relaunch: quit $((t_quit - t0)) ms, swap $((t_open - t_quit)) ms, launch ${launch} ms (process start -> first window); gap quit->first window $((fw - t0)) ms"
  local before=$(tail -n +$((lines + 1)) $DEN_LOG 2>/dev/null | grep " quit pid=" | tail -1 | grep -Eo 'spaces=.*')
  local after=$(print -r -- $line | grep -Eo 'spaces=.*')
  if [[ -z $before ]]; then den_say "session: $after (previous den logged no quit state)"
  elif [[ $before == $after ]]; then den_say "session restored: $after"
  else den_say "session CHANGED: before [$before] after [$after]"; fi
}

den_plugin() {
  local ok=0 id
  mkdir -p "$DEN_HOME_DIR/plugins"
  for id in "$@"; do
    if [[ ! -d Plugins/$id ]]; then
      rm -f "$DEN_HOME_DIR/plugins/$id.dylib"; den_say "plugin $id: folder gone, override removed"; continue
    fi
    local t0=$(den_ms) out
    if out=$("$CORDIS_BUILD" --id "$id" --out "$DEN_HOME_DIR/plugins/$id.dylib" Plugins/$id/*.swift Plugins/Shared/*.swift 2>&1); then
      print -r -- $id >> $DEN_MANAGED
      den_say "plugin $id: built in $(( $(den_ms) - t0 )) ms -> ~/.den/plugins/$id.dylib"
    else
      ok=1; den_say "plugin $id: build FAILED, running den keeps the previous build"; print -r -- "$out" | grep -m5 "error:"
    fi
  done
  return $ok
}
