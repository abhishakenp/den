#!/bin/zsh
# den follows main (developer channel): a user LaunchAgent that keeps the installed den on the
# latest pushed commit of origin/main. docs/updates.md explains the whole update system.
#
#   scripts/updater.sh install     clone ~/.den/src, install + start the LaunchAgent
#   scripts/updater.sh uninstall   stop and remove the LaunchAgent (keeps ~/.den/src)
#   scripts/updater.sh check       one check (what launchd runs every 150 s; den's
#                                  "Check for Updates…" kickstarts it)
#   scripts/updater.sh status      state, agent, last log lines
#
# A check costs one `git ls-remote` when nothing changed, then exits (launchd keeps nothing
# running between checks). On a new commit it builds ONLY that pushed commit, in ~/.den/src:
#   Plugins/** only   -> cordis-build the affected plugins + their tests, then place them in
#                        ~/.den/updates/plugins/<id>.dylib (+ <id>.json: hostAPI, permissions);
#                        the running den hot-swaps them
#   host / package    -> swift test + scripts/bundle.sh, install to /Applications/den.app, drop
#                        the managed plugins the new bundle supersedes; den shows "restart to
#                        apply" and relaunches when you're not using it (the updates plugin)
#   anything fails    -> nothing deployed; logged in ~/.den/logs/updater.log; that commit is
#                        not retried until main moves
# The agent runs at nice 10, so the user's apps get the CPU first. Throttled I/O is not used:
# with ProcessType=Background (taskpolicy -b) or LowPriorityIO, a plugin build that takes 12 s
# got ~20 s of CPU in 11-12 minutes while other processes kept the disk busy (load ~350).
# DEN_UPDATER_PROCESS_TYPE=Background at install time opts into it anyway.
set -uo pipefail

SELF=${0:A}
LABEL=io.github.abhishakenp.den.updater
DEN=${DEN_HOME:-$HOME/.den}
SRC=$DEN/src
UPD=$DEN/updates
BIN=$UPD/bin
STAGE=$UPD/stage
MANAGED=$UPD/plugins
STATE=$UPD/state.json
LOG=$DEN/logs/updater.log
APP=${DEN_APP_DEST:-/Applications/den.app}
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
INTERVAL=${DEN_UPDATER_INTERVAL:-150}
HOST_RE='^(Sources/|Package\.swift$|Package\.resolved$|Resources/|scripts/bundle\.sh$)'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$PATH

log() { mkdir -p ${LOG:h}; print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> $LOG; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
short() { print -r -- ${1[1,7]}; }

# state.json (read with plutil, written atomically so den never sees half a file).
state_get() { [[ -f $STATE ]] && plutil -extract "$1" raw -o - $STATE 2>/dev/null || true; }
state_write() { # key=value ... (strings)
  mkdir -p $UPD
  /usr/bin/python3 - $STATE "$@" <<'PY'
import json, os, sys
path, pairs = sys.argv[1], sys.argv[2:]
try: d = json.load(open(path))
except Exception: d = {}
for kv in pairs:
    k, _, v = kv.partition("=")
    d[k] = v
tmp = os.path.join(os.path.dirname(path), ".state.json.tmp")
json.dump(d, open(tmp, "w"), indent=1, sort_keys=True)
os.replace(tmp, path)
PY
}

# True when the machine is too busy for timing-sensitive tests to mean anything (1-min load
# above 2x the cores). A failure then isn't held against the commit: the next check retries it.
overloaded() {
  local l=$(sysctl -n vm.loadavg | awk '{print int($2)}') n=$(sysctl -n hw.ncpu)
  (( l > 2 * n ))
}

failed_at() { # sha deployed
  if overloaded; then
    state_write lastCheck=$(now_iso) lastResult="Tests failed at $(short $1) under load $(sysctl -n vm.loadavg | awk '{print $2}'); retrying"
    log "NOT deployed $(short $1) (load $(sysctl -n vm.loadavg | awk '{print $2}')): will retry at the next check"
  else
    state_write lastFailed=$1 lastCheck=$(now_iso) lastResult="Tests failed at $(short $1); kept $(short $2)"
    log "NOT deployed $(short $1): kept $(short $2)"
  fi
}

channel() { # [updates] channel in config.toml, if set
  [[ -f $DEN/config.toml ]] || return
  awk '/^\[updates\]/{s=1;next} /^\[/{s=0} s && /^[[:space:]]*channel[[:space:]]*=/{gsub(/.*=[[:space:]]*"|".*/,""); print; exit}' $DEN/config.toml
}

cmd_install() {
  local repo=${1:-$(git -C "${SELF:h}/.." remote get-url origin 2>/dev/null || echo https://github.com/abhishakenp/den.git)}
  mkdir -p $UPD $BIN $STAGE $MANAGED ${LOG:h} ${PLIST:h}
  if [[ ! -d $SRC/.git ]]; then
    git clone -q "$repo" $SRC || { print "clone of $repo failed"; return 1; }
  fi
  cp "$SELF" $BIN/updater.sh && chmod +x $BIN/updater.sh
  # Start from what /Applications/den.app was built from (a clean commit), so the next check
  # deploys only what came after it. Otherwise the first check does a full host install.
  local built=$(plutil -extract DenCommit raw -o - $APP/Contents/Info.plist 2>/dev/null || true)
  if [[ $built =~ '^[0-9a-f]{40}$' ]]; then
    state_write channel=follow-main deployed=$built deployedAt=$(now_iso) installedCommit=$built lastFailed= lastResult="Following main from $(short $built)"
  else
    state_write channel=follow-main deployed= installedCommit= lastFailed= lastResult="Waiting for the first build"
  fi
  cat > $PLIST <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$BIN/updater.sh</string><string>check</string></array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>${DEN_UPDATER_PROCESS_TYPE:-Standard}</string>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin</string></dict>
</dict>
</plist>
EOF
  launchctl bootout gui/$UID/$LABEL 2>/dev/null
  launchctl bootstrap gui/$UID $PLIST && print "installed $LABEL (every ${INTERVAL}s); source $SRC; log $LOG"
  log "agent installed (repo $repo, every ${INTERVAL}s)"
}

cmd_uninstall() {
  launchctl bootout gui/$UID/$LABEL 2>/dev/null
  rm -f $PLIST
  log "agent uninstalled"
  print "removed $LABEL (kept $SRC and $UPD)"
}

cmd_status() {
  launchctl print gui/$UID/$LABEL 2>/dev/null | grep -E "state =|last exit|runs =" | sed 's/^[[:space:]]*/agent: /'
  [[ -f $STATE ]] && cat $STATE && print
  tail -5 $LOG 2>/dev/null
}

# swift test [filter]. UI and WebKit tests can be flaky under heavy load, so: a run that
# crashed (no summary) is run again whole, once; then tests that failed are re-run once on their
# own. Deploys need every test to pass by then.
# Tests go through scripts/test.sh when the commit has it: it holds a machine-wide lock so only
# one `swift test` runs at a time (concurrent runs starve each other's timing-sensitive tests).
swift_test() { if [[ -x $SRC/scripts/test.sh ]]; then $SRC/scripts/test.sh "$@"; else swift test "$@"; fi; }

run_tests() {
  local out=$STAGE/test.log filter=${1:-} args=()
  [[ -n $filter ]] && args=(--filter "$filter")
  mkdir -p $STAGE
  (cd $SRC && swift_test $args > $out 2>&1); local rc=$?
  cat $out >> $LOG
  (( rc == 0 )) && return 0
  if ! grep -q "Test run with" $out; then
    log "test run did not finish; running it again once"
    (cd $SRC && swift_test $args > $out 2>&1); rc=$?
    cat $out >> $LOG
    (( rc == 0 )) && return 0
    grep -q "Test run with" $out || return 1
  fi
  local failed=(${(f)"$(sed -nE 's/^✘ Test ([A-Za-z0-9_]+)\(.*\) failed.*/\1/p' $out | sort -u)"})
  (( ${#failed} )) || return 1
  log "re-running failed tests once: ${failed[*]}"
  (cd $SRC && swift_test --filter "${(j:|:)failed}" >> $LOG 2>&1)
}

# Test suites for a plugin id: Tests/PluginTests/<Id>Tests.swift (case-insensitive).
suites_for() {
  local id=$1 f
  for f in $SRC/Tests/PluginTests/*Tests.swift(N); do
    [[ ${${f:t:r}:l} == ${id:l}tests ]] && print -r -- ${f:t:r}
  done
}

deploy_plugins() { # sha ids...
  local sha=$1; shift
  local id cb=$SRC/.build/checkouts/cordis-swift/Scripts/cordis-build filter=() gen
  [[ -x $cb ]] || (cd $SRC && swift package resolve >> $LOG 2>&1) || return 1
  rm -rf $STAGE && mkdir -p $STAGE
  for id in "$@"; do
    [[ -d $SRC/Plugins/$id ]] || continue
    "$cb" --id $id --out $STAGE/$id.dylib $SRC/Plugins/$id/*.swift $SRC/Plugins/Shared/*.swift >> $LOG 2>&1 || { log "build failed: $id"; return 1; }
    filter+=($(suites_for $id))
  done
  if (( ${#filter} )); then
    run_tests "${(j:|:)filter}" || { log "tests failed: ${filter[*]}"; return 1; }
    log "tests passed: ${filter[*]}"
  else
    log "no plugin tests for: $*"
  fi
  gen=$(git -C $SRC rev-list --count $sha -- Sources Package.swift Package.resolved)
  mkdir -p $MANAGED
  for id in "$@"; do
    if [[ ! -d $SRC/Plugins/$id ]]; then rm -f $MANAGED/$id.dylib $MANAGED/$id.json; log "removed $id"; continue; fi
    local perms='[]'
    [[ -f $SRC/Plugins/$id/permissions.json ]] && perms=$(plutil -extract permissions json -o - $SRC/Plugins/$id/permissions.json 2>/dev/null || print '[]')
    print -r -- "{\"id\":\"$id\",\"version\":\"$(short $sha)\",\"commit\":\"$sha\",\"hostAPI\":$gen,\"source\":\"follow-main\",\"permissions\":$perms}" > $MANAGED/.$id.json.tmp
    mv -f $MANAGED/.$id.json.tmp $MANAGED/$id.json
    # Same volume: rename is atomic, den sees one complete new file.
    cp $STAGE/$id.dylib $MANAGED/.$id.dylib.tmp && mv -f $MANAGED/.$id.dylib.tmp $MANAGED/$id.dylib
    log "deployed plugin $id @ $(short $sha) (hostAPI $gen)"
  done
}

deploy_host() { # sha
  local sha=$1
  run_tests || { log "swift test failed"; return 1; }
  log "swift test passed"
  (cd $SRC && scripts/bundle.sh >> $LOG 2>&1) || { log "bundle.sh failed"; return 1; }
  rm -rf $APP.new
  ditto $SRC/build/den.app $APP.new && codesign --verify --strict $APP.new || { log "copy/verify failed"; rm -rf $APP.new; return 1; }
  rm -rf $APP.old
  [[ -d $APP ]] && mv $APP $APP.old
  mv $APP.new $APP && rm -rf $APP.old
  # The bundle has every plugin as of this commit: every managed build (follow-main or an older
  # release) is superseded.
  rm -f $MANAGED/*.dylib(N) $MANAGED/*.json(N)
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $APP >/dev/null 2>&1
  mdimport $APP >/dev/null 2>&1
  log "installed host @ $(short $sha) (hostAPI $(plutil -extract DenHostAPI raw -o - $APP/Contents/Info.plist))"
}

cmd_check() {
  mkdir -p $UPD ${LOG:h}
  local c=$(channel)
  if [[ -n $c && $c != follow-main ]]; then return 0; fi
  # One check at a time.
  if ! mkdir $UPD/.lock 2>/dev/null; then
    local holder=$(cat $UPD/.lock/pid 2>/dev/null)
    if [[ -n $holder ]] && kill -0 $holder 2>/dev/null; then return 0; fi
    rm -rf $UPD/.lock; mkdir $UPD/.lock || return 0
  fi
  print $$ > $UPD/.lock/pid
  trap 'rm -rf $UPD/.lock' EXIT
  local requested=0
  [[ -f $UPD/check-requested ]] && { requested=1; rm -f $UPD/check-requested; }

  [[ -d $SRC/.git ]] || { log "no $SRC (run scripts/updater.sh install)"; return 1; }
  local remote=$(git -C $SRC ls-remote origin refs/heads/main 2>/dev/null | cut -f1)
  local deployed=$(state_get deployed) failed=$(state_get lastFailed)
  if [[ -z $remote ]]; then
    (( requested )) && state_write lastCheck=$(now_iso) lastResult="Couldn't reach GitHub"
    log "ls-remote failed"; return 0
  fi
  if [[ $remote == $deployed || $remote == $failed ]]; then
    # Nothing new: den isn't woken unless someone asked.
    (( requested )) && state_write lastCheck=$(now_iso) lastResult="Up to date at $(short ${deployed:-$remote})"
    return 0
  fi
  local t0=$(date +%s)
  log "new commit $(short $remote) (deployed $(short ${deployed:-none}))"
  git -C $SRC fetch -q origin main && git -C $SRC checkout -q --force --detach $remote && git -C $SRC clean -qfdx -e .build -e build \
    || { log "fetch/checkout failed"; return 1; }

  local files=() host=0 ids=() f id
  if [[ -n $deployed ]] && git -C $SRC merge-base --is-ancestor $deployed $remote 2>/dev/null; then
    files=(${(f)"$(git -C $SRC diff --name-only $deployed $remote)"})
  else
    host=1
  fi
  for f in $files; do
    if [[ $f =~ $HOST_RE ]]; then host=1
    elif [[ $f == Plugins/Shared/* ]]; then ids+=(${${(f)"$(cd $SRC && ls -d Plugins/*/ | xargs -n1 basename)"}:#Shared})
    elif [[ $f == Plugins/*/* ]]; then id=${${f#Plugins/}%%/*}; ids+=($id)
    fi
  done
  ids=(${(u)ids})

  local result
  if (( host )); then
    if deploy_host $remote; then
      result="Installed $(short $remote) — restart to apply"
      state_write deployed=$remote deployedAt=$(now_iso) installedCommit=$remote lastCheck=$(now_iso) lastResult="$result" lastFailed=
    else
      failed_at $remote $deployed; return 1
    fi
  elif (( ${#ids} )); then
    if deploy_plugins $remote $ids; then
      result="Updated ${(j:, :)ids} to $(short $remote)"
      state_write deployed=$remote deployedAt=$(now_iso) lastCheck=$(now_iso) lastResult="$result" lastFailed=
    else
      failed_at $remote $deployed; return 1
    fi
  else
    result="Nothing to deploy in $(short $remote)"
    state_write deployed=$remote deployedAt=$(now_iso) lastCheck=$(now_iso) lastResult="Up to date at $(short $remote)" lastFailed=
  fi
  log "$result ($(( $(date +%s) - t0 )) s)"
  # Next run uses the updater from this commit.
  [[ -f $SRC/scripts/updater.sh ]] && cp $SRC/scripts/updater.sh $BIN/updater.sh.new && mv -f $BIN/updater.sh.new $BIN/updater.sh
}

case ${1:-} in
  install) shift; cmd_install "$@" ;;
  uninstall) cmd_uninstall ;;
  check) cmd_check ;;
  status) cmd_status ;;
  *) sed -n '2,20p' "$SELF"; exit 2 ;;
esac
