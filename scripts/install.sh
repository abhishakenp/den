#!/bin/zsh
# Verified build -> install -> relaunch, once: scripts/bundle.sh and swift test must both pass,
# then den.app replaces /Applications/den.app and the running den relaunches with its session
# (spaces, tabs, selection come back from plugin storage). A failing build is never installed.
#   scripts/install.sh              build, test, install, relaunch
#   scripts/install.sh --no-test    skip swift test (still never installs a failed build)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/app.zsh
mkdir -p build
if [[ ${1:-} == --no-test ]]; then
  scripts/bundle.sh > build/dev-sync-bundle.log 2>&1 || { den_say "build FAILED (build/dev-sync-bundle.log)"; exit 1; }
else
  den_verify || exit 1
fi
den_install build/den.app
