#!/bin/zsh
# Rebuilds den's Shields filter lists: Plugins/shields/resources/{ads,trackers,cookies}.json.lzfse
# and the version and rule counts in Plugins/shields/ShieldsLists.swift. Run it before a release.
#   scripts/shields/build-lists.sh               convert on the Linux box `a2` (cargo, many cores)
#   SHIELDS_HOST=<ssh host> …                     another box;  SHIELDS_HOST=local: cargo on this Mac
# Steps: download EasyList, EasyPrivacy and the EasyList Cookie List; convert them to WebKit content
# rules with adblock-rust (scripts/shields/cbconv, MPL-2.0, a build tool only); then, on this Mac,
# compile every list with WebKit (dropping any rule WebKit refuses), split lists over 150,000 rules,
# and LZFSE-compress them (scripts/shields/prepare.swift). Licences: Plugins/shields/resources/NOTICE.md.
set -euo pipefail
cd "$(dirname "$0")/../.."
host=${SHIELDS_HOST:-a2}
work=build/shields-lists
rm -rf $work && mkdir -p $work
urls=(https://easylist.to/easylist/easylist.txt https://easylist.to/easylist/easyprivacy.txt https://secure.fanboy.co.nz/fanboy-cookiemonster.txt)
# ads: network rules + site-specific hiding (EasyList's ~13,600 generic hiding rules would restyle
# every page); trackers: network rules; cookies: everything (its hiding rules are the point).
remote_script='set -e; cd "$1"; cargo build --release -q --manifest-path cbconv/Cargo.toml
for u in '"${urls[*]}"'; do curl -fsSL -o "$(basename $u)" "$u"; done
B=cbconv/target/release/cbconv
$B ads.json --no-generic-cosmetic easylist.txt
$B trackers.json --network-only easyprivacy.txt
$B cookies.json fanboy-cookiemonster.txt
grep -m1 "^! Version:" easylist.txt > version.txt
gzip -kf ads.json trackers.json cookies.json'
if [[ $host == local ]]; then
  cp -R scripts/shields/cbconv $work/cbconv
  zsh -c "$remote_script" _ "$PWD/$work"
else
  dir=den-shields-build
  ssh $host "rm -rf $dir && mkdir -p $dir/cbconv/src"
  scp -q scripts/shields/cbconv/Cargo.toml scripts/shields/cbconv/Cargo.lock $host:$dir/cbconv/
  scp -q scripts/shields/cbconv/src/main.rs $host:$dir/cbconv/src/
  ssh $host "bash -c '$remote_script' _ \$HOME/$dir"
  for f in ads.json.gz trackers.json.gz cookies.json.gz version.txt; do scp -q "$host:$dir/$f" $work/; done
  gunzip -f $work/*.json.gz
fi
# "! Version: 202609271952" -> 2026.09.27
raw=$(sed -E 's/.*Version: *([0-9]{8}).*/\1/' $work/version.txt)
version="${raw[1,4]}.${raw[5,6]}.${raw[7,8]}"
swiftc -O scripts/shields/prepare.swift -o build/shields-prepare
build/shields-prepare $work/out ads=$work/ads.json trackers=$work/trackers.json cookies=$work/cookies.json | tee $work/prepare.log
grep -q -- '-2:' $work/prepare.log && { echo "a list needs more than one part: add the parts to ShieldsLists.swift"; exit 1; }
cp $work/out/{ads,trackers,cookies}.json.lzfse Plugins/shields/resources/
# The WebKit store identifier: the lists' date plus a digest of the files, so any change recompiles.
version="$version-$(cat Plugins/shields/resources/{ads,trackers,cookies}.json.lzfse | shasum -a 256 | cut -c1-8)"
swift_file=Plugins/shields/ShieldsLists.swift
sed -i '' -E "s/static let version = \"[0-9a-f.-]+\"/static let version = \"$version\"/" $swift_file
for n in ads trackers cookies; do
  count=$(grep "^$n:" $work/prepare.log | sed -E 's/.* rules=([0-9]+) .*/\1/')
  pretty=$(printf "%'d" $count | tr ',' '_')
  sed -i '' -E "/static let $n = List\(/s/rules: [0-9_]+/rules: $pretty/" $swift_file
done
echo "lists $version:"; ls -la Plugins/shields/resources/*.lzfse
# What the daily Shields lists workflow publishes (.github/workflows/shields-lists.yml): the lists
# under versioned names plus lists.json, which den fetches every day (ShieldsCore.refreshLists).
pub=$work/publish
rm -rf $pub && mkdir -p $pub
entries=()
for n in ads trackers cookies; do
  f=$n-$version.json.lzfse
  cp Plugins/shields/resources/$n.json.lzfse $pub/$f
  count=$(grep "^$n:" $work/prepare.log | sed -E 's/.* rules=([0-9]+) .*/\1/')
  sum=$(shasum -a 256 $pub/$f | cut -d' ' -f1)
  entries+=("\"$n\":{\"file\":\"$f\",\"rules\":$count,\"bytes\":$(stat -f%z $pub/$f),\"sha256\":\"$sum\"}")
done
print -r -- "{\"version\":\"$version\",\"lists\":{${(j:,:)entries}}}" > $pub/lists.json
cat $pub/lists.json
