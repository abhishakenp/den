#!/bin/zsh
# CI entry point for the test suite: runs scripts/test.sh, logging to build/ci-logs/test.log.
# Most suites open real (off-screen) NSWindows and WKWebViews, which need a GUI (Aqua) login
# session with a window server. GitHub's macOS runners have one; if a machine does not, only the
# suites that never touch AppKit windows run, and the skipped ones are named in the log (and in
# $GITHUB_STEP_SUMMARY), never skipped silently.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/ci-logs
log=build/ci-logs/test.log
session=$(launchctl managername 2>/dev/null || echo unknown)
args=()
if [[ $session != Aqua ]]; then
  headless='SuggestServiceTests|DenHomeTests|FaviconFallbackTests|CoreTests|ExtensionPackageTests|IconTests|LogicTests'
  msg="No GUI login session (launchctl managername: $session). Window/WebKit suites SKIPPED: all of PluginTests, and every DenHostTests suite except $headless."
  echo "::warning title=UI tests skipped::$msg"
  [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || echo "> [!WARNING]\n> $msg" >> "$GITHUB_STEP_SUMMARY"
  args=(--filter "DenHostTests\\.($headless)")
else
  echo "GUI session: $session; running the full suite (UI tests included)"
fi
start=$SECONDS
rc=0
scripts/test.sh "${args[@]}" "$@" 2>&1 | tee "$log" || rc=$?
summary=$(grep -E '^(✔|✘|􁁛|􀢄).*(Test run|tests? in)|Executed [0-9]+ tests' "$log" | tail -3 || true)
echo "tests finished in $(( SECONDS - start ))s, exit $rc"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  { echo "### Tests ($session session, exit $rc, $(( SECONDS - start ))s)"; echo '```'; echo "$summary"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi
exit $rc
