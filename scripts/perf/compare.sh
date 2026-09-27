#!/bin/zsh
# Measures den against reference browsers with one identical method (scripts/perf/perfprobe.swift).
# usage: scripts/perf/compare.sh <outdir> name=/path/App.app[@arg,arg...] ...
#   e.g. scripts/perf/compare.sh /tmp/perf den=/Applications/den.app@--storage,/tmp/st dia=/x/Dia.app arc=/x/Arc.app
#   ROUNDS=12  launch rounds (after 1 discarded warm-up round)
#   MEMREPS=3  memory repetitions per state
#   RESET_<name>='shell cmd'  run before every launch of <name> (e.g. restore den's storage from a template,
#                             so opening a URL in one run cannot change what the next run restores)
# Launches are interleaved round-robin (den, dia, arc, den, dia, arc, ...) so background load
# hits every app equally. An app with an instance already running (started by anyone else) is
# skipped, never touched. Raw logs land in <outdir>; a summary is printed at the end.
set -uo pipefail
cd "$(dirname "$0")/../.."
out=$1; shift
mkdir -p $out
rounds=${ROUNDS:-12}
memreps=${MEMREPS:-3}
probe=$out/perfprobe
swiftc -O scripts/perf/perfprobe.swift -o $probe || exit 2

typeset -A apppath extra
names=()
for spec in "$@"; do
  n=${spec%%=*}; rest=${spec#*=}
  apppath[$n]=${rest%%@*}
  [[ $rest == *@* ]] && extra[$n]=${rest#*@} || extra[$n]=""
  names+=$n
done

busy() { # 0 if any process with the app's executable name runs (any copy: Chromium apps would hand our launch to it)
  local exe; exe=$(defaults read "${apppath[$1]:A}/Contents/Info.plist" CFBundleExecutable)
  pgrep -x "$exe" >/dev/null
}
quiet() { # waits (up to QUIET_WAIT s, default 1800) for 1-min load < MAXLOAD (default 4) and no Swift build
  local waited=0 max=${QUIET_WAIT:-1800} l
  (( ${gave_up:-0} )) && max=60   # once the machine never got quiet, don't wait 30 min per batch again
  while :; do
    l=$(sysctl -n vm.loadavg | awk '{print $2}')
    if awk "BEGIN{exit !($l < ${MAXLOAD:-4})}" && ! pgrep -f 'swift-build|swift-frontend|cordis-build' >/dev/null; then
      echo "quiet load=$l after ${waited}s $(date +%T)" >> $out/gate.log; return 0; fi
    if (( waited >= max )); then echo "TAINTED load=$l builds=$(pgrep -f 'swift-build|swift-frontend|cordis-build' | wc -l | tr -d ' ') gave up after ${waited}s $(date +%T)" | tee -a $out/gate.log; gave_up=1; return 1; fi
    sleep 20; (( waited += 20 ))
  done
}
run() { # name mode logfile opts...
  local n=$1 mode=$2 log=$3; shift 3
  if [[ $n != den ]] && busy $n; then echo "skip $n: instance already running" | tee -a $log; return; fi
  local r="RESET_$n"; [[ -n ${(P)r:-} ]] && eval "${(P)r}"
  local a=(); [[ -n ${extra[$n]} ]] && a=(-- ${(s:,:)extra[$n]})
  $probe $mode ${apppath[$n]} "$@" $a >> $log 2>&1
}

{ echo "date $(date)"; sysctl -n hw.model; sw_vers | tr '\n' ' '; echo; pmset -g batt | head -2; sysctl -n hw.ncpu hw.memsize; } > $out/env.txt
quiet
for n in $names; do run $n launch $out/launch-$n.log --runs 1 --warmup 0; done       # warm-up round, discarded
for n in $names; do : > $out/launch-$n.log; done
for r in $(seq 1 $rounds); do
  quiet
  for n in $names; do run $n launch $out/launch-$n.log --runs 1 --warmup 0; done
done
for r in $(seq 1 $memreps); do
  for n in $names; do quiet; run $n mem $out/idle-$n.log --settle 10 --cpu 30 --shot $out/shot-idle-$n-$r.png; done
  for n in $names; do quiet; run $n mem $out/page-$n.log --settle 10 --url https://example.com --shot $out/shot-page-$n-$r.png; done
done

stat() { sort -n | awk '{a[NR]=$1} END {if(!NR){print "n=0"; exit} m=(NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2; i=int(0.9*(NR-1)); if(i<0.9*(NR-1)) i++; printf "n=%d median=%.1f p90=%.1f min=%.1f max=%.1f\n", NR, m, a[i+1], a[1], a[NR]}'; }
field() { grep -o "$1=[0-9.]*" | cut -d= -f2; }
for n in $names; do
  echo "== $n"
  echo "launch reqMs   $(grep '^run ' $out/launch-$n.log | field reqMs | stat)"
  echo "launch startMs $(grep '^run ' $out/launch-$n.log | field startMs | stat)"
  echo "mem idle MB    $(grep '^mem.totalMB' $out/idle-$n.log | awk '{print $2}' | stat)"
  echo "mem page MB    $(grep '^mem.totalMB' $out/page-$n.log | awk '{print $2}' | stat)"
  echo "cpu idle %     $(grep '^cpu.idlePct' $out/idle-$n.log | awk '{print $2}' | stat)"
  echo "wakeups/s      $(grep '^cpu.idlePct' $out/idle-$n.log | awk '{for(i=1;i<=NF;i++) if($i=="wakeups/s") print $(i+1)}' | stat)"
  echo "load during idle cpu: $(grep '^cpu.idlePct' $out/idle-$n.log | grep -o 'load=[0-9.]*' | cut -d= -f2 | stat)"
  echo "load during launches: $(grep '^run ' $out/launch-$n.log | grep -o 'load=[0-9.]*' | cut -d= -f2 | stat)"
done | tee $out/summary.txt
