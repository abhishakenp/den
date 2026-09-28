#!/bin/zsh
# den performance regression check against the absolute budgets in docs/perf/budgets.json.
# usage: scripts/perf.sh [--report-only] [path/to/den.app]   (default build/den.app; scripts/bundle.sh builds it)
#   --report-only       never fail on a budget (CI: budgets were calibrated on an M3, not a runner)
#   PERF_REPORT=file    also write the results as a Markdown table to file
#   PERF_RUNS=10        measured warm launches (after 1 discarded warm-up)
#   PERF_QUIET_WAIT=600 seconds to wait for a quiet machine (1-min load < 4, no Swift build)
# Method (the same one used for Dia/Arc in docs/perf/baseline.md): scripts/perf/perfprobe.swift asks
# LaunchServices for a new, non-activated instance and polls CGWindowListCopyWindowInfo every 1 ms for
# its first on-screen window. Memory is phys_footprint (what `footprint`/Activity Monitor show), for
# the den process alone ("host") and summed with every WebKit process den is responsible for ("total").
# Every run uses a throwaway --storage copy; ~/Library/Application Support/den and ~/.den are never used.
# Test windows do appear on screen (not activated) for a few seconds each; every instance is quit.
# Exits 1 if any metric exceeds its budget, 2 on setup errors.
set -euo pipefail
cd "$(dirname "$0")/.."
report_only=0
[[ ${1:-} == --report-only ]] && { report_only=1; shift; }
app=${1:-build/den.app}
runs=${PERF_RUNS:-10}
budgets=docs/perf/budgets.json
[[ -d $app ]] || { echo "no app at $app (run scripts/bundle.sh)"; exit 2; }
source scripts/lib/launch.zsh
den_refuse_installed $app || exit 2

mkdir -p build/perf
for tool in perfprobe denstore; do
  if [[ ! -x build/perf/$tool || scripts/perf/$tool.swift -nt build/perf/$tool ]]; then
    swiftc -O scripts/perf/$tool.swift -o build/perf/$tool
  fi
done
probe=build/perf/perfprobe denstore=build/perf/denstore

waited=0
while :; do
  load1=$(sysctl -n vm.loadavg | awk '{print $2}')
  awk "BEGIN{exit !($load1 < 4)}" && ! pgrep -f 'swift-build|swift-frontend|cordis-build' >/dev/null && break
  if (( waited >= ${PERF_QUIET_WAIT:-600} )); then
    echo "warning: machine not quiet (1-min load $load1); numbers are TAINTED"; break
  fi
  sleep 20; (( waited += 20 ))
done
echo "load average at start: $(sysctl -n vm.loadavg)"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"; den_leftovers $app || true' EXIT
log=$tmp/log
# Store templates: "seeded" = den's first-run store (created by one throwaway launch), "empty" = the
# same with zero tabs, "tabs200" = 200 never-loaded tabs and nothing selected (metadata only).
mkdir -p $tmp/seeded
# 20 s: the first launch compiles the shields rule lists into the template, so every measured
# launch starts like any launch after the first (a compile at launch leaves its working memory
# behind; that case is scripts/perf/lab.sh emptycompile).
$probe mem $app --settle 20 -- --storage $tmp/seeded > /dev/null
cp -R $tmp/seeded $tmp/empty && $denstore empty-tabs $tmp/empty > /dev/null
cp -R $tmp/seeded $tmp/tabs200 && $denstore tabs 200 $tmp/tabs200 > /dev/null
fresh() { rm -rf $tmp/store; cp -R $tmp/$1 $tmp/store; }   # every measurement starts from a clean copy
val() { awk -v k=$1 '$1 == k {print $2}' $log; }
field() { grep "^$1" $log | grep -o "$2[= ][0-9.]*" | grep -o '[0-9.]*$'; }

echo "== launch, seeded store ($runs warm runs)"
fresh seeded
$probe launch $app --runs $runs --warmup 1 -- --storage $tmp/store | tee $log
launch_med=$(field summary.reqMs median) launch_p90=$(field summary.reqMs p90)

echo "== no tabs: 10 s after first window, then 30 s idle"
fresh empty
$probe mem $app --settle 10 --cpu 30 -- --storage $tmp/store | tee $log
host0=$(val mem.hostMB) total0=$(val mem.totalMB) cpu0=$(val cpu.idlePct)
wake0=$(awk '/^cpu.idlePct/ {for(i=1;i<=NF;i++) if($i=="wakeups/s") print $(i+1)}' $log)

echo "== 200 discarded (never-loaded) tabs"
fresh tabs200
$probe mem $app --settle 10 -- --storage $tmp/store | tee $log
host200=$(val mem.hostMB)
per_tab_kb=$(awk "BEGIN{printf \"%.1f\", ($host200 - $host0) * 1024 / 200}")

echo "== one page: empty store + https://example.com opened at launch"
fresh empty
$probe mem $app --settle 10 --url https://example.com -- --storage $tmp/store | tee $log
page_total=$(val mem.totalMB)
echo "load average at end: $(sysctl -n vm.loadavg)"

budget() { plutil -extract "den.$1" raw -o - $budgets; }
fail=0
report=${PERF_REPORT:-}
if [[ -n $report ]]; then
  mkdir -p "${report:h}"
  { echo "| metric | measured | budget | |"; echo "|---|---:|---:|---|"; } > "$report"
fi
check() { # name measured budget-key
  local b r; b=$(budget $3)
  if awk "BEGIN{exit !($2 <= $b)}"; then r=PASS; printf "PASS  %-26s %8.2f <= %s\n" $1 $2 $b
  else r=FAIL; printf "FAIL  %-26s %8.2f >  %s\n" $1 $2 $b; fail=1; fi
  [[ -z $report ]] || printf "| %s | %.2f | %s | %s |\n" $1 $2 $b $r >> "$report"
}
echo "== budgets ($budgets)"
check launch.medianMs $launch_med launchMedianMs
check launch.p90Ms $launch_p90 launchP90Ms
check noTabs.hostMB $host0 noTabsHostMB
check noTabs.totalMB $total0 noTabsTotalMB
check noTabs.idleCpuPct $cpu0 idleCpuPct
check noTabs.idleWakeupsPerSec $wake0 idleWakeupsPerSec
check discardedTab.KB $per_tab_kb perDiscardedTabKB
check onePage.totalMB $page_total onePageTotalMB
if [[ -n $report ]]; then
  { echo; echo "$(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores, $(( $(sysctl -n hw.memsize) / 1073741824 )) GB; $runs runs; load at end: $(sysctl -n vm.loadavg)"; } >> "$report"
fi
if (( fail && report_only )); then echo "report-only: budget failures do not fail the run"; exit 0; fi
exit $fail
