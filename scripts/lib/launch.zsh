# Safe automated den launches. Source it from the repo root (scripts/snapshots.sh, measure-memory.sh, perf.sh).
#   den_refuse_installed <app>        refuse an installed den (/Applications, ~/Applications) unless
#                                     DEN_ALLOW_INSTALLED=1
#   den_check_app <app>               that, and refuse a den built before invisible --background
#                                     (it would run on with a visible window)
#   den_bounded <seconds> <cmd...>    run cmd; SIGKILL it (and wait) if it is still running after <seconds>
#   den_leftovers <app>               print and SIGKILL any process of <app> still running; nonzero if any
# Automated launches use --background (no Dock icon, never activated, windows off every display)
# and quit by themselves (--snapshot, --exit-after); den_bounded is the backstop.

den_refuse_installed() {
  local app=${1:A}
  if [[ $app == /Applications/* || $app == $HOME/Applications/* ]] && [[ -z ${DEN_ALLOW_INSTALLED:-} ]]; then
    print -u2 "refusing the installed $app for automation (build one: scripts/bundle.sh; override: DEN_ALLOW_INSTALLED=1)"
    return 2
  fi
}

den_check_app() {
  local app=${1:A}
  den_refuse_installed $app || return 2
  [[ -x $app/Contents/MacOS/den ]] || { print -u2 "no den at $app (run scripts/bundle.sh)"; return 2; }
  # Checked without launching it (an older den would open a visible window): bundles built since
  # --background became invisible carry DenScenarios in Info.plist. Such a den also exits 2 on any
  # flag it doesn't know.
  if ! plutil -extract DenScenarios raw -o - "$app/Contents/Info.plist" >/dev/null 2>&1; then
    print -u2 "$app predates invisible --background; rebuild it with scripts/bundle.sh"
    return 2
  fi
}

den_bounded() {
  local secs=$1; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 $pid 2>/dev/null; do
    if (( waited >= secs * 10 )); then
      print -u2 "den_bounded: $1 still running after ${secs}s, killing $pid"
      kill -9 $pid 2>/dev/null
      wait $pid 2>/dev/null
      return 124
    fi
    sleep 0.1
    (( waited += 1 ))
  done
  wait $pid
}

den_leftovers() {
  local app=${1:A} pids
  pids=($(pgrep -f "^$app/Contents/MacOS/den" || true))
  (( ${#pids} == 0 )) && return 0
  print -u2 "left running (killed): $(ps -o pid=,command= -p ${(j:,:)pids})"
  kill -9 $pids 2>/dev/null
  return 1
}
