#!/bin/zsh
# Measures den's memory: the app process plus every WebKit process macOS holds den responsible
# for (WebContent, Networking, GPU), with `footprint` (phys_footprint, Activity Monitor's Memory).
# usage: scripts/measure-memory.sh <scenario> [wait-seconds]
#   scenarios: blank (no web view: den only), main (1 live tab), load10 (10 tabs loaded, all live),
#              load10discard (10 tabs loaded, then 9 discarded), mini (a video playing in the mini player),
#              miniInline (the same video playing in its tab). SETTLE=<s> waits longer after scenario.ready.
# CPU=1 also samples %CPU of every process for 10 s (top).
# APP=path/to/den.app overrides build/den.app. FOOTPRINT_RAW=1 also prints footprint's own output.
#   DEN_EXTENSIONS_FROM=<an extensions folder> (extensions.json + <id>/ + icons/) measures with those installed.
set -euo pipefail
cd "$(dirname "$0")/.."
scenario=${1:-main}
wait=${2:-15}
app=${APP:-build/den.app}
source scripts/lib/launch.zsh
den_check_app $app
[[ -x build/denprocs && build/denprocs -nt scripts/lib/denprocs.swift ]] || swiftc -O scripts/lib/denprocs.swift -o build/denprocs
store=$(mktemp -d)
[[ -n ${DEN_EXTENSIONS_FROM:-} ]] && cp -R "$DEN_EXTENSIONS_FROM" "$store/extensions"
extra=()
[[ $scenario == blank ]] && extra=(--scenario blank)
[[ $scenario != blank && $scenario != main ]] && extra=(--scenario $scenario)
# Launched through LaunchServices so den is "responsible" for its WebKit processes (from a
# shell, the terminal would be), which is how denprocs finds them.
open -n -g -a "$PWD/$app" --stdout "$store/out.txt" --stderr "$store/out.txt" --args --no-den-home --demo --background --storage "$store" $extra
pid=""
for i in {1..100}; do pid=$(pgrep -f -- "--storage $store" | head -1 || true); [[ -n $pid ]] && break; sleep 0.1; done
[[ -n $pid ]] || { echo "den did not start"; exit 1; }
# Never leave a den behind, even if a reader of this script's output stops early (SIGPIPE).
trap 'kill -9 $pid 2>/dev/null; rm -rf "$store"' EXIT
if [[ $scenario == load10* || $scenario == mini* ]]; then
  for i in {1..150}; do grep -q scenario.ready "$store/out.txt" && break; sleep 1; done
  sleep ${SETTLE:-5}
else
  sleep "$wait"
fi
grep -E "scenario\.(ready|kept)" "$store/out.txt" || true
procs=("${(@f)$(build/denprocs $pid)}")
args=(-p $pid)
for line in $procs; do [[ -n $line ]] && args+=(-p ${line%% *}); done
raw=$(footprint $args 2>/dev/null)
[[ -n ${FOOTPRINT_RAW:-} ]] && print -r -- "$raw"
echo "scenario $scenario  den pid $pid  processes: den + ${#procs[@]} (${(j:, :)procs})"
print -r -- "$raw" | grep -E '^[^ ].*\[[0-9]+\].*: [0-9.]+ [KMG]B|Footprint:' | sed -E 's/^ +//'
if [[ -n ${CPU:-} ]]; then
  # 10 one-second samples (the first top sample has no CPU delta and is dropped); summed per sample.
  tops=(); for a in ${args:#-p}; do tops+=(-pid $a); done
  top -l 11 -s 1 -stats pid,cpu $tops 2>/dev/null | awk -v n=${#tops} '
    /^PID/ { s++; next } s > 1 && $1 ~ /^[0-9]+$/ { sum[s] += $2 }
    END { t = 0; c = 0; for (k in sum) { t += sum[k]; c++ } if (c) printf "cpu: %.1f%% (den + WebKit, mean of %d one-second samples)\n", t / c, c }'
fi
echo "loadavg $(sysctl -n vm.loadavg)"
# SIGTERM asks den to quit, which the quit plugin may hold for its dialog: then SIGKILL.
kill $pid 2>/dev/null || true
for i in {1..30}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
kill -9 $pid 2>/dev/null || true
rm -rf "$store"
