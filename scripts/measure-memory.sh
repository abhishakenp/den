#!/bin/zsh
# Measures den's memory: the app process plus the WebKit processes it spawned.
# usage: scripts/measure-memory.sh <scenario> [wait-seconds]
#   scenarios: main (1 live tab), load10 (10 live tabs), load10discard (10 tabs, 9 discarded)
# Requires build/den.app (scripts/bundle.sh). Uses `footprint` (phys_footprint, what Activity Monitor shows as Memory).
set -euo pipefail
cd "$(dirname "$0")/.."
scenario=${1:-main}
wait=${2:-15}
webkit_pids() { pgrep -f 'com.apple.WebKit.(WebContent|Networking|GPU)' | sort -n || true; }
before=$(webkit_pids)
store=$(mktemp -d)
build/den.app/Contents/MacOS/Den --demo --scenario "$scenario" --storage "$store" > "$store/out.txt" 2>&1 &
pid=$!
if [[ $scenario == load10* ]]; then
  for i in {1..120}; do grep -q scenario.ready "$store/out.txt" && break; sleep 1; done
  sleep 5
else
  sleep "$wait"
fi
after=$(webkit_pids)
new=$(comm -13 <(echo "$before") <(echo "$after") | tr '\n' ' ')
grep scenario.ready "$store/out.txt" || true
echo "den pid $pid; new WebKit pids: $new"
footprint -p $pid $(for p in ${=new}; do echo -p $p; done) 2>/dev/null | grep -E '^\s*(Den|com.apple.WebKit|Summary|TOTAL)|phys_footprint:|Footprint' | head -40
kill $pid
