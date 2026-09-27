#!/bin/zsh
# CI entry point for the test suite: runs scripts/test.sh, logging to build/ci-logs/test.log.
# Most suites open real (off-screen) NSWindows and WKWebViews, which need a GUI (Aqua) login
# session with a window server. GitHub's macOS runners have one; if a machine does not, only the
# suites that never touch AppKit windows run, and the skipped ones are named in the log (and in
# $GITHUB_STEP_SUMMARY), never skipped silently.
# CI_ISOLATE_SUITES (a regex of suite names) runs those suites in a second pass, after the parallel
# run: they drive several WebKit processes against local mock servers with wall-clock timeouts,
# which a 3-core runner can't meet while ~35 other suites run beside them. Nothing is skipped.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/ci-logs
log=build/ci-logs/test.log
: > "$log"
session=$(launchctl managername 2>/dev/null || echo unknown)
isolate=${CI_ISOLATE_SUITES:-}
passes=()
if [[ $session != Aqua ]]; then
  headless='SuggestServiceTests|DenHomeTests|FaviconFallbackTests|CoreTests|ExtensionPackageTests|IconTests|LogicTests'
  msg="No GUI login session (launchctl managername: $session). Window/WebKit suites SKIPPED: all of PluginTests, and every DenHostTests suite except $headless."
  echo "::warning title=UI tests skipped::$msg"
  [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || print -r -- $'> [!WARNING]\n> '"$msg" >> "$GITHUB_STEP_SUMMARY"
  passes=(--filter "DenHostTests\\.($headless)")
elif [[ -n $isolate ]]; then
  echo "GUI session: $session; full suite (UI tests included), with $isolate in a second pass"
  passes=(--skip "\\.($isolate)/" --filter "\\.($isolate)/")
else
  echo "GUI session: $session; running the full suite (UI tests included)"
  passes=(--all "")
fi
start=$SECONDS
rc=0 summary=""
test_cmd=(${(z)${CI_TEST_CMD:-scripts/test.sh}})  # CI_TEST_CMD=echo: dry run of the passes
for flag pattern in "${passes[@]}"; do
  args=()
  [[ $flag == --all ]] || args=($flag "$pattern")
  echo "== scripts/test.sh ${args[*]}" | tee -a "$log"
  t=$SECONDS prc=0
  $test_cmd "${args[@]}" "$@" 2>&1 | tee -a "$log" || prc=$?
  line=$(grep -E '^(✔|✘).*Test run with' "$log" | tail -1 || true)
  summary+="${args[*]:-full suite}: exit $prc, $(( SECONDS - t ))s"$'\n'"  $line"$'\n'
  (( prc == 0 )) || rc=$prc
done
print -r -- "$summary"
echo "tests finished in $(( SECONDS - start ))s, exit $rc"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
  { echo "### Tests ($session session, exit $rc, $(( SECONDS - start ))s)"; echo '```'; print -r -- "$summary"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi
exit $rc
