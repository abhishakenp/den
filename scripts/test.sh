#!/bin/zsh
# Runs `swift test` holding a machine-wide lock, so parallel agents build freely but only one
# test run executes at a time (concurrent runs starve each other's timing-sensitive tests).
#   scripts/test.sh [swift test args...]
# Suites run one at a time (`--no-parallel`): they all share the main actor, and interleaving
# them only starves each other. DEN_TEST_PARALLEL=1 opts out.
# Every test has a watchdog (Tests/DenTestSupport/Watchdog.swift): DEN_TEST_LIMIT seconds per
# test (default 120), then a report of what it was waiting on. The whole run is capped too:
# DEN_TEST_RUN_LIMIT seconds (default 1800), after which it is killed. A run can fail; it can't hang.
# Every WebContent process the tests used must exit by the end; survivors are named, killed, and
# fail the run (exit 3).
set -euo pipefail
cd "$(dirname "$0")/.."
build_log=$(mktemp -t den-test-build)
if ! swift build --build-tests >$build_log 2>&1; then
  grep -E "error:" $build_log | sort -u | head -40 >&2 || tail -40 $build_log >&2
  rm -f $build_log
  print -u2 "test.sh: build failed"
  exit 1
fi
rm -f $build_log
lock=/tmp/den-swift-test.lock
waited=0
until mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$lock"
    continue
  fi
  (( waited % 60 == 0 )) && print -u2 "test.sh: waiting for test lock held by pid ${holder:-?}"
  sleep 2
  (( waited += 2 ))
done
print $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT INT TERM
args=(--skip-build)
[[ ${DEN_TEST_PARALLEL:-0} == 1 ]] || args+=(--no-parallel)
limit=${DEN_TEST_RUN_LIMIT:-1800}
# WebKit leak guard: the tests log every WebContent pid they used (Tests/DenTestSupport/Leaks.swift).
webkit_log=$(mktemp -t den-test-webkit)
export DEN_TEST_WEBKIT_LOG=$webkit_log
webcontent() { { pgrep -x com.apple.WebKit.WebContent || true; } | wc -l | tr -d ' '; }  # none running (a CI runner) is 0, not a pipefail exit
before=$(webcontent)
trap 'rm -rf "$lock" "$webkit_log"' EXIT INT TERM
start=$SECONDS
swift test $args "$@" &
pid=$!
# Kills `swift test` and the test process it runs.
kill_tree() { local c; for c in $(pgrep -P $1); do kill_tree $c; done; kill -TERM $1 2>/dev/null || true; }
while kill -0 $pid 2>/dev/null; do
  if (( SECONDS - start > limit )); then
    print -u2 "test.sh: the run exceeded ${limit} s (DEN_TEST_RUN_LIMIT); killing it"
    kill_tree $pid
    break
  fi
  sleep 1
done
rc=0
wait $pid || rc=$?
# Every WebContent process the run used must be gone (they exit once their page is closed or the
# test process ends; a stuck one kept audio sessions open in coreaudiod). Give them 20 s, then name
# the test that leaked each survivor, kill it, and fail the run.
is_webcontent() { [[ $(ps -o comm= -p $1 2>/dev/null) == *com.apple.WebKit.WebContent ]]; }
pids=(${(f)"$(cut -f1 $webkit_log | sort -u)"})
for i in {1..40}; do
  alive=()
  for p in $pids; do [[ -n $p ]] && is_webcontent $p && alive+=($p); done
  (( ${#alive} == 0 )) && break
  sleep 0.5
done
after=$(webcontent)
print -u2 "test.sh: WebContent processes before $before, after $after; the run used ${#pids}, still alive ${#alive}"
if (( ${#alive} > 0 )); then
  for p in $alive; do
    print -u2 "test.sh: LEAK: WebContent pid $p from $(awk -F'\t' -v p=$p '$1 == p {print $2}' $webkit_log | sort -u | paste -sd, -); killing it"
    kill -9 $p 2>/dev/null || true
  done
  (( rc == 0 )) && rc=3
fi
print -u2 "test.sh: exit $rc after $(( SECONDS - start )) s"
exit $rc
