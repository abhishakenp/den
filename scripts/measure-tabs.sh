#!/bin/zsh
# Background-tab memory on real sites, and how fast a background tab comes back.
# usage: scripts/measure-tabs.sh "<url> <url>…"
#   A separate den (its own --storage, its own website data: never the den in use) closes its seed
#   tabs, opens each URL in turn (DWELL s on screen each, default 8) and shows the first again
#   (`--scenario realtabs`). Then `footprint` of den + every WebKit process it is responsible for,
#   at each of CHECKS (seconds after the last tab loaded, default "15 120"). RETURN=1 then shows
#   every background tab in turn and prints how long each took (scenario.return lines), and
#   measures once more. DISCARD=1 discards the background tabs first (measured), so the return
#   times are restores. APP=path/to/den.app overrides build/den.app.
set -euo pipefail
cd "$(dirname "$0")/.."
urls=${1:?urls}
app=${APP:-build/den.app}
source scripts/lib/launch.zsh
den_check_app $app
[[ -x build/denprocs && build/denprocs -nt scripts/lib/denprocs.swift ]] || swiftc -O scripts/lib/denprocs.swift -o build/denprocs
store=$(mktemp -d)
open -n -g -a "${app:A}" --stdout "$store/out.txt" --stderr "$store/out.txt" --env DEN_DWELL=${DWELL:-8} --env DEN_DISCARD=${DISCARD:-0} \
  --args --no-den-home --demo --background --storage "$store" --scenario realtabs --url "$urls"
pid=""
for i in {1..100}; do pid=$(pgrep -f -- "--storage $store" | head -1 || true); [[ -n $pid ]] && break; sleep 0.1; done
[[ -n $pid ]] || { echo "den did not start"; exit 1; }
trap 'kill -9 $pid 2>/dev/null; rm -rf "$store"' EXIT
for i in {1..300}; do grep -q scenario.ready "$store/out.txt" && break; sleep 1; done
grep -E "scenario\.(ready|pool)" "$store/out.txt" || { echo "no scenario.ready"; tail -20 "$store/out.txt"; exit 1; }
measure() {
  local procs=("${(@f)$(build/denprocs $pid)}") args=(-p $pid)
  for line in $procs; do [[ -n $line ]] && args+=(-p ${line%% *}); done
  echo "-- $1: den + ${#procs[@]} (${(j:, :)procs})"
  footprint $args 2>/dev/null | grep -E '^[^ ].*\[[0-9]+\].*: [0-9.]+ [KMG]B|Footprint:' | sed -E 's/^ +//'
}
t=0
for c in ${=CHECKS:-15 120}; do sleep $(( c - t )); t=$c; measure "${c}s after ready"; done
if [[ -n ${RETURN:-} ]]; then
  touch "$store/return.now"
  [[ ${DISCARD:-0} == 1 ]] && { sleep 5; measure "background tabs discarded"; }
  for i in {1..300}; do grep -q scenario.returnDone "$store/out.txt" && break; sleep 1; done
  grep -E "scenario\.(beforeReturn|return |returnDone|pool)" "$store/out.txt" || true
  sleep 5
  measure "after every tab came back"
fi
kill $pid 2>/dev/null || true
for i in {1..30}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
kill -9 $pid 2>/dev/null || true
