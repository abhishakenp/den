#!/usr/bin/env bash
# Deletes remote ci/** scratch branches (scripts/ci-check.sh) whose head commit is older than N days.
#   scripts/ci/prune-ci-branches.sh [days=7]      DRY_RUN=1 lists without deleting
#   GH_REPO=owner/name selects the repo (default: the current checkout's).
# Only refs under ci/ are ever touched.
set -euo pipefail
days=${1:-7}
repo=${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}
cutoff=$(( $(date +%s) - days * 86400 ))
branches=$(gh api "repos/$repo/git/matching-refs/heads/ci/" --paginate --jq '.[] | "\(.ref) \(.object.sha)"')
[[ -n $branches ]] || { echo "no ci/ branches"; exit 0; }
while read -r ref sha; do
  [[ $ref == refs/heads/ci/* ]] || continue
  date=$(gh api "repos/$repo/commits/$sha" --jq .commit.committer.date)
  ts=$(date -j -u -f %Y-%m-%dT%H:%M:%SZ "$date" +%s 2>/dev/null || date -u -d "$date" +%s)
  if (( ts < cutoff )); then
    if [[ -n ${DRY_RUN:-} ]]; then echo "would delete ${ref#refs/heads/} (last commit $date)"
    else gh api -X DELETE "repos/$repo/git/${ref}" && echo "deleted ${ref#refs/heads/} (last commit $date)"; fi
  else
    echo "keep ${ref#refs/heads/} (last commit $date)"
  fi
done <<< "$branches"
