#!/bin/zsh
# Runs `swift test` holding a machine-wide lock, so parallel agents build freely but only one
# test run executes at a time (concurrent runs starve each other's timing-sensitive tests).
#   scripts/test.sh [swift test args...]
# Suites run one at a time (`--no-parallel`): they all share the main actor, and interleaving
# them only starves each other. DEN_TEST_PARALLEL=1 opts out.
# Every test has a watchdog (Tests/DenTestSupport/Watchdog.swift): DEN_TEST_LIMIT seconds per
# test (default 90), then a report of what it was waiting on. The whole run is capped too:
# DEN_TEST_RUN_LIMIT seconds (default 1800), after which it is killed. A run can fail; it can't hang.
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
print -u2 "test.sh: exit $rc after $(( SECONDS - start )) s"
exit $rc
