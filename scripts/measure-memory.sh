#!/bin/zsh
# Measures den's memory: the app process plus the WebKit processes it spawned.
# usage: scripts/measure-memory.sh <scenario> [wait-seconds]
#   scenarios: main (1 live tab), load10 (10 live tabs), load10discard (10 tabs, 9 discarded)
#   DEN_EXTENSIONS_FROM=<an extensions folder> (extensions.json + <id>/ + icons/) measures with those installed.
# Requires build/den.app (scripts/bundle.sh). Uses `footprint` (phys_footprint, what Activity Monitor shows as Memory).
# den is launched through LaunchServices (`open -n`), so it is its own "responsible process": the
# WebKit processes counted are exactly the ones macOS attributes to it, even with other browsers
# (or other dens) running.
set -euo pipefail
cd "$(dirname "$0")/.."
scenario=${1:-main}
wait=${2:-15}
store=$(mktemp -d)
[[ -n ${DEN_EXTENSIONS_FROM:-} ]] && cp -R "$DEN_EXTENSIONS_FROM" "$store/extensions"
open -n -g --stdout "$store/out.txt" --stderr "$store/out.txt" build/den.app --args --no-den-home --demo --scenario "$scenario" --storage "$store"
pid=""
for i in {1..100}; do pid=$(pgrep -f "den.app/Contents/MacOS/den .*--storage $store" | head -1 || true); [[ -n $pid ]] && break; sleep 0.1; done
[[ -n $pid ]] || { echo "den did not start"; exit 1; }
if [[ $scenario == load10* ]]; then
  for i in {1..120}; do grep -q scenario.ready "$store/out.txt" && break; sleep 1; done
  sleep 5
else
  sleep "$wait"
fi
new=$(python3 -c '
import ctypes, subprocess, sys
f = ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
out = subprocess.run(["pgrep", "-f", "com.apple.WebKit.(WebContent|Networking|GPU)"], capture_output=True, text=True).stdout.split()
print(" ".join(p for p in out if f(int(p)) == int(sys.argv[1])))' $pid)
grep scenario.ready "$store/out.txt" || true
echo "den pid $pid; its WebKit pids: $new"
footprint -p $pid $(for p in ${=new}; do echo -p $p; done) 2>/dev/null | grep -E '^\s*(den|com.apple.WebKit|Summary|TOTAL)|phys_footprint:|Footprint' | head -40
kill $pid
