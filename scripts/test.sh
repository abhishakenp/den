#!/bin/zsh
# Runs `swift test` holding a machine-wide lock, so parallel agents build freely but only one
# test run executes at a time (concurrent runs starve each other's timing-sensitive tests).
#   scripts/test.sh [swift test args...]
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-tests >/dev/null
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
swift test --skip-build "$@"
