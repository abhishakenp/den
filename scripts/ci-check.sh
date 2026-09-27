#!/bin/zsh
# Remote build mode (docs/dev.md): builds and tests HEAD on GitHub Actions instead of this Mac.
#   scripts/ci-check.sh [--snapshots] [--name <branch-suffix>]
# Pushes HEAD to the scratch branch ci/<name> (default: the current branch or worktree name),
# waits for the CI run on that exact commit, prints the job summary and the failed tests, and
# downloads every artifact to .ci-artifacts/<run-id>/. Exits non-zero unless the run is green.
# --snapshots also renders scripts/snapshots.sh on a second runner (PNGs in the artifacts).
# Only ci/** branches are ever force-pushed; ci/** branches are pruned 7 days after their last commit.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
snapshots=0 name=""
while (( $# )); do
  case $1 in
    --snapshots) snapshots=1 ;;
    --name) name=${2:?}; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ -z $name ]]; then
  name=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || basename "$PWD")
  name=${name#worktree-}
fi
name=$(print -r -- "$name" | tr -c 'A-Za-z0-9._/-' '-' | sed 's/^[-/]*//; s/[-/]*$//')
[[ -n $name && $name != main ]] || name=$(basename "$PWD")
branch=ci/$name
[[ $branch == ci/?* ]] || { echo "refusing to push to $branch" >&2; exit 2; }
sha=$(git rev-parse HEAD)
[[ -z $(git status --porcelain --untracked-files=no) ]] || echo "warning: uncommitted changes are NOT tested; only HEAD ${sha:0:12} is"

remote_sha=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ $remote_sha != "$sha" ]]; then
  git push --force --quiet origin "HEAD:refs/heads/$branch"  # scratch branch only
  echo "pushed ${sha:0:12} to $branch"
fi
# A push triggers the build+test run. Snapshots (or a commit already on the branch) need a
# dispatch; it supersedes the push run for the same ref (concurrency group), which is cancelled.
event=push
if (( snapshots )) || [[ $remote_sha == "$sha" ]]; then
  event=workflow_dispatch
  gh workflow run ci.yml --ref "$branch" -f snapshots=$( (( snapshots )) && echo true || echo false) >/dev/null
  echo "dispatched ci.yml on $branch (snapshots=$( (( snapshots )) && echo on || echo off))"
fi

run=""
for _ in {1..40}; do
  run=$(gh run list --workflow ci.yml --branch "$branch" --commit "$sha" --event $event --limit 5 \
    --json databaseId,createdAt --jq "[.[] | select(.createdAt >= \"$start\")][0].databaseId // empty")
  [[ -n $run ]] && break
  sleep 3
done
[[ -n $run ]] || { echo "no $event run for ${sha:0:12} on $branch appeared" >&2; exit 1; }
url=$(gh run view "$run" --json url --jq .url)
echo "run: $url"

t0=$SECONDS
rc=0
gh run watch "$run" --compact --interval 20 --exit-status >/dev/null || rc=$?
conclusion=$(gh run view "$run" --json conclusion --jq .conclusion)
echo
echo "== $conclusion in $(( (SECONDS - t0) / 60 ))m$(( (SECONDS - t0) % 60 ))s: $url"
gh run view "$run" --json jobs --jq '.jobs[] | "\(.conclusion // .status)\t\(.name)\t\((((.completedAt | fromdate) - (.startedAt | fromdate)) / 60 | floor))m"' 2>/dev/null || true

out=.ci-artifacts/$run
mkdir -p "$out"
gh run download "$run" --dir "$out" 2>/dev/null || true
echo "artifacts: $out ($(find "$out" -type f | wc -l | tr -d ' ') files)"
log=$(find "$out" -name test.log | head -1)
if [[ -n $log ]]; then
  grep -E '^✘ Test .*(recorded an issue|failed after)|Test run with|exited with unexpected signal|Executed [0-9]+ tests' "$log" | tail -40 || true
fi
if [[ $conclusion != success ]]; then
  echo "== failed step logs (tail)"
  gh run view "$run" --log-failed 2>/dev/null | cut -f3- | grep -vE '^\s*$' | tail -60 || true
  exit $(( rc ? rc : 1 ))
fi
