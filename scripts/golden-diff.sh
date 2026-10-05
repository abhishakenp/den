#!/bin/zsh
# UI parity check for the thin-host migration (docs/architecture/thin-host.md §6).
#   scripts/golden-diff.sh <run-id>               the CI pixel diff of a `ci-check.sh --snapshots` run
#   scripts/golden-diff.sh <dirA> <dirB>          pixel-diff two local folders of PNGs
# CI's snapshot job pixel-diffs its PNGs against the golden run in scripts/thin-host/golden-run
# (report only) and uploads the small `golden-diff` artifact: report.txt plus <name>.diff.png for
# each differing image (the new image greyed, differing pixels red). This script fetches it into
# .ci-artifacts/<run>/golden-diff and prints what differs. Images in
# scripts/thin-host/snapshot-noise.txt differ between two renders of the same commit (live pages,
# clocks) and are reported as `noise`. Exit 0 when nothing else differs.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if (( $# == 2 )); then
  mkdir -p build/perf
  [[ -x build/perf/pixel-diff && build/perf/pixel-diff -nt scripts/pixel-diff.swift ]] || swiftc -O scripts/pixel-diff.swift -o build/perf/pixel-diff
  exec build/perf/pixel-diff "$1" "$2" --out "$2/../diff" --noise scripts/thin-host/snapshot-noise.txt
fi
run=${1:?usage: scripts/golden-diff.sh <run-id> | <dirA> <dirB>}
d=.ci-artifacts/$run/golden-diff
[[ -f $d/report.txt ]] || { mkdir -p $d; gh run download $run -n golden-diff -D $d >/dev/null; }
grep -v '^same ' $d/report.txt
tail -1 $d/report.txt | grep -q ' 0 differ'
