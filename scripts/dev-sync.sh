#!/bin/zsh
# The agent -> live app loop. Watches the repo and keeps the installed den on the latest code:
#   Plugins/<id>/**       rebuild that plugin into ~/.den/plugins/<id>.dylib (atomic rename);
#                         the running den hot-swaps it within ~100 ms of the write
#   Plugins/Shared/**     rebuild every plugin
#   Sources/, Resources/, Package.*, scripts/bundle.sh
#                         bundle + swift test; only if both pass, install to /Applications and
#                         relaunch den with its session (scripts/lib/app.zsh den_install)
# Changes are debounced (quiet for DEBOUNCE_MS, default 1500) and a failing build is never
# installed. Uses fswatch when installed, else polls mtimes every POLL seconds (default 1).
#   scripts/dev-sync.sh [--repo <dir>]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/app.zsh
[[ ${1:-} == --repo ]] && cd "$2"
[[ -x $CORDIS_BUILD ]] || swift package resolve
mkdir -p build
DEBOUNCE_MS=${DEBOUNCE_MS:-1500}
POLL=${POLL:-1}
WATCH_PATHS=(Plugins Sources Resources Package.swift Package.resolved scripts/bundle.sh)

# Sort changed paths into plugin ids and a host flag, then act.
handle() {
  local -a ids; local host=0 p id
  for p in "$@"; do
    p=${p#$PWD/}
    case $p in
      Plugins/Shared|Plugins/Shared/*) ids+=(${${(f)"$(ls -d Plugins/*/ | xargs -n1 basename | grep -vx Shared)"}}) ;;
      Plugins/?*) id=${${p#Plugins/}%%/*}; [[ $id == .* ]] || ids+=($id) ;;
      Sources/*|Resources/*|Package.swift|Package.resolved|scripts/bundle.sh) host=1 ;;
    esac
  done
  ids=(${(u)ids})
  if (( host )); then
    den_say "host change: verified build, install, relaunch"
    if den_verify; then den_install build/den.app || den_say "install failed; den keeps running the previous build"
    else den_say "not installed: fix the build or tests, save again"; fi
  elif (( ${#ids} )); then
    den_plugin $ids || true
  fi
}

den_say "dev-sync: watching $PWD (${WATCH_PATHS[*]}) -> ~/.den/plugins and $DEN_APP_DEST"
if command -v fswatch >/dev/null; then
  den_say "using fswatch"
  fswatch -r -l 0.2 -e '/\.build/' -e '/build/' -e '\.swp$' -e '~$' $WATCH_PATHS | while true; do
    typeset -a batch=()
    IFS= read -r first || break
    batch+=($first)
    while IFS= read -r -t $(( DEBOUNCE_MS / 1000.0 )) more; do batch+=($more); done
    handle $batch
  done
else
  den_say "fswatch not installed: polling every ${POLL}s (brew install fswatch for events)"
  stamp=$(mktemp -t den-sync); next=$(mktemp -t den-sync)
  trap 'rm -f $stamp $next' EXIT
  typeset -a batch=()
  typeset quiet_since=0
  while true; do
    touch $next
    changed=(${(f)"$(find $WATCH_PATHS -newer $stamp -type f ! -name '*.swp' 2>/dev/null; find Plugins -mindepth 1 -maxdepth 1 -type d -newer $stamp 2>/dev/null)"})
    mv -f $next $stamp
    if (( ${#changed} )); then batch+=($changed); quiet_since=$(den_ms)
    elif (( ${#batch} )) && (( $(den_ms) - quiet_since >= DEBOUNCE_MS )); then
      handle ${(u)batch}; batch=()
    fi
    sleep $POLL
  done
fi
