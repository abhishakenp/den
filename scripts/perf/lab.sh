#!/bin/zsh
# Memory lab: repeated per-scenario memory numbers for one den.app, plus heap / vmmap / footprint
# of the live process, so builds can be compared (bisected) by their numbers. Runs on the CI
# runner through .github/workflows/perf-lab.yml (a busy laptop's numbers are noise).
#   scripts/perf/lab.sh <den.app> <outdir> [scenario...]
#   scenarios (default: empty tabs200 seeded):
#     empty    zero tabs (den alone, no WebKit process)
#     emptyload  the same, launched and measured while busy loops load every core
#     emptycompile  the same with no compiled content rule lists (shields compiles at launch)
#     tabs200  200 never-loaded tabs, nothing selected (per discarded tab = (tabs200 - empty) / 200)
#     seeded   den's first-run store (its pages load)
#     page     zero tabs + https://example.com, 45 s settle
#     ubo      page, with uBlock Origin Lite installed (downloaded from the Chrome Web Store)
#   LAB_REPS=5    repetitions per scenario (median reported); LAB_SETTLE overrides the settle time
# Every run uses a throwaway --storage copy. The app is re-signed with get-task-allow so heap and
# vmmap can read it (a lab copy only; never a shipped bundle).
set -euo pipefail
here=${0:A:h}
app=${1:?den.app}; out=${2:?outdir}; shift 2
scenarios=(${@:-empty tabs200 seeded})
reps=${LAB_REPS:-5}
mkdir -p $out
out=${out:A}
bin=$(mktemp -d)
for tool in perfprobe denstore; do swiftc -O $here/$tool.swift -o $bin/$tool; done
probe=$bin/perfprobe denstore=$bin/denstore

ent=$bin/ent.plist
codesign -d --entitlements - --xml $app > $ent 2>/dev/null || true
plutil -lint -s $ent >/dev/null 2>&1 || plutil -create xml1 $ent
# PlistBuddy: plutil reads the dots in the key as a key path.
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" $ent >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" $ent
codesign --force --deep --options runtime --entitlements $ent --sign - $app
codesign -d --entitlements - --xml $app 2>/dev/null | grep -q get-task-allow && echo "re-signed with get-task-allow"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$bin"' EXIT
mkdir -p $tmp/seeded
# 20 s, so the first launch finishes compiling the shields rule lists into the template (every
# scenario but emptycompile then starts with them compiled, like any launch after the first).
$probe mem $app --settle 20 -- --storage $tmp/seeded > /dev/null
echo "template: $(ls $tmp/seeded/contentrules 2>/dev/null | wc -l | tr -d " ") compiled rule list files"
cp -R $tmp/seeded $tmp/empty && $denstore empty-tabs $tmp/empty > /dev/null
cp -R $tmp/seeded $tmp/tabs200 && $denstore tabs 200 $tmp/tabs200 > /dev/null
if (( ${scenarios[(Ie)ubo]} )); then
  # uBlock Origin Lite from the Chrome Web Store, unpacked the way den installs it.
  id=ddkjiahejlhfcafbddmgiahcphecmpfh
  cp -R $tmp/empty $tmp/ubo
  ext=$tmp/ubo/extensions
  mkdir -p $ext/$id
  curl -fsSL -o $tmp/ubol.crx "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=140.0&acceptformat=crx2,crx3&x=id%3D$id%26installsource%3Dondemand%26uc"
  (cd $ext/$id && unzip -q $tmp/ubol.crx 2>/dev/null || true)
  [[ -f $ext/$id/manifest.json ]] || { echo "uBOL download/unpack failed"; exit 1; }
  /usr/bin/python3 - $ext $id <<'PY'
import json, sys, time, os
ext, id = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(ext, id, "manifest.json")))
perms = [p for p in m.get("permissions", []) if isinstance(p, str)]
pats = m.get("host_permissions", []) + m.get("optional_host_permissions", [])
json.dump([{"id": id, "name": "uBlock Origin Lite", "version": m["version"], "source": "chrome", "storeId": id,
            "dir": os.path.join(ext, id), "enabled": True, "pinned": True, "siteAccess": "all", "sites": [],
            "granted": perms, "grantedPatterns": pats, "installedAt": time.time() * 1000}],
          open(os.path.join(ext, "extensions.json"), "w"))
print("uBOL", m["version"], "permissions", perms, "hosts", pats)
PY
fi
fresh() { rm -rf $tmp/store; cp -R $tmp/$1 $tmp/store; }
median() { sort -n | awk '{a[NR]=$1} END {if (NR==0) {print "-"; exit}; print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'; }

summary=$out/summary.txt
for s in $scenarios; do
  hosts=() totals=()
  settle=${LAB_SETTLE:-10} url=()
  [[ $s == page || $s == ubo ]] && { settle=${LAB_SETTLE:-45}; url=(--url https://example.com); }
  # Compiles run in the background: measure once they are over (and relieved).
  [[ $s == emptycompile ]] && settle=${LAB_SETTLE:-40}
  [[ $s == ubo ]] && settle=${LAB_SETTLE:-90}
  src=$s; [[ $s == page || $s == emptyload || $s == emptycompile ]] && src=empty
  for i in $(seq 1 $reps); do
    fresh $src
    # emptycompile: no compiled content rule lists, so shields compiles its lists at launch (a
    # first launch, or the first after a list update).
    [[ $s == emptycompile ]] && rm -rf $tmp/store/contentrules
    # The ubo store's extensions.json points at its own folder: rewrite for the copy.
    [[ -f $tmp/store/extensions/extensions.json ]] && sed -i '' "s#$tmp/ubo/#$tmp/store/#g" $tmp/store/extensions/extensions.json
    exec_args=()
    # First run: heap, vmmap, footprint, and the power assertions held while den idles.
    (( i == 1 )) && exec_args=(--exec "heap -s \$PERF_PID > '$out/$s.heap.txt' 2>&1; vmmap -summary \$PERF_PID > '$out/$s.vmmap.txt' 2>&1; footprint -p \$PERF_PID > '$out/$s.footprint.txt' 2>&1; pmset -g assertions > '$out/$s.assertions.txt' 2>&1; true")
    # emptyload: the empty store while 3x ncpu busy loops load the machine (launch-time races that
    # only show on a busy Mac: the 2026-09-28 noTabs regression was measured at load 5-800).
    burners=()
    if [[ $s == emptyload ]]; then
      for _ in $(seq 1 $(( $(sysctl -n hw.ncpu) * 3 ))); do yes > /dev/null & burners+=($!); done
    fi
    $probe mem $app --settle $settle $url $exec_args -- --storage $tmp/store > $tmp/log 2>&1 || true
    (( ${#burners} )) && kill $burners 2>/dev/null; wait $burners 2>/dev/null || true
    cat $tmp/log >> $out/$s.log
    hosts+=($(awk '$1 == "mem.hostMB" {print $2}' $tmp/log)) totals+=($(awk '$1 == "mem.totalMB" {print $2}' $tmp/log))
  done
  printf "%-8s host median %s MB [%s]  total median %s MB [%s]\n" $s \
    "$(print -l $hosts | median)" "${(j:, :)hosts}" "$(print -l $totals | median)" "${(j:, :)totals}" | tee -a $summary
done
echo "$(sysctl -n machdep.cpu.brand_string), load at end: $(sysctl -n vm.loadavg)" | tee -a $summary
