#!/bin/zsh
# Publishes a den release on GitHub (docs/updates.md):
#   scripts/release.sh <semver>          e.g. 0.1.0, or 0.1.0-alpha.1 (a "-" suffix = pre-release)
#   scripts/release.sh <semver> --dry-run   build + sign into dist/<semver>, publish nothing
#
# 1. Verified build: a green CI run on HEAD (DEN_RELEASE_LOCAL_TESTS=1: scripts/test.sh locally) + scripts/bundle.sh (DEN_VERSION=<semver>). Refuses a dirty tree.
# 2. dist/<semver>/: den-<semver>.zip (ditto -c -k --keepParent), den-<semver>.dmg, every plugin
#    as <id>.dylib, plugins.json (id, version, abi, hostAPI, sha256, EdDSA signature, url,
#    permissions), release notes (commits since the last tag).
# 3. EdDSA signatures come from Sparkle's sign_update with the private key in the login Keychain
#    (account "den", created by generate_keys --account den). The key never leaves the Keychain.
# 4. gh release create v<semver> (with --prerelease for pre-releases), then updates/appcast.xml and
#    updates/plugins.json are updated on main (the stable URLs den polls) and pushed.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release.sh <semver> [--dry-run]}
DRY=${2:-}
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' ]] || { echo "not semver: $VERSION"; exit 2; }
TAG=v$VERSION
PRE=0; [[ $VERSION == *-* ]] && PRE=1
REPO=abhishakenp/den
BIN=.build/artifacts/sparkle/Sparkle/bin
DIST=dist/$VERSION
[[ -z $(git status --porcelain -- Sources Plugins Package.swift Package.resolved Resources scripts) ]] || { echo "tree is dirty; release from a clean checkout"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG exists"; exit 1; }

if [[ ${DEN_RELEASE_LOCAL_TESTS:-0} != 1 ]]; then
  # Remote build mode (docs/dev.md): the gate is a green CI run on this exact commit, on a clean
  # macos-26 runner. Local runs depend on this Mac's power state, appearance and load.
  HEAD_SHA=$(git rev-parse HEAD)
  echo "== verify: CI on $HEAD_SHA"
  git fetch -q origin main
  [[ $(git rev-parse origin/main) == $HEAD_SHA ]] || git merge-base --is-ancestor HEAD origin/main || { echo "HEAD is not on origin/main: push it first"; exit 1; }
  ok=$(gh run list -R $REPO --commit $HEAD_SHA --workflow CI --json conclusion -q '[.[] | select(.conclusion=="success")] | length')
  (( ok > 0 )) || { echo "no green CI run on $HEAD_SHA: not releasing (DEN_RELEASE_LOCAL_TESTS=1 runs the suite locally instead)"; exit 1; }
  echo "CI green on $HEAD_SHA"
elif ! scripts/test.sh > build/release-test.log 2>&1; then
  # Timing-sensitive tests (WebKit sign-in, latency budgets) can fail on a loaded machine:
  # re-run the failed ones once, on their own. A crashed run (no summary) is not retried.
  failed=(${(f)"$(sed -nE 's/^✘ Test ([A-Za-z0-9_]+)\(.*\) failed.*/\1/p' build/release-test.log | sort -u)"})
  grep -q "Test run with" build/release-test.log && (( ${#failed} )) || { tail -20 build/release-test.log; echo "tests failed: not releasing"; exit 1; }
  echo "re-running ${#failed} failed tests once: ${failed[*]}"
  scripts/test.sh --filter "${(j:|:)failed}" > build/release-retest.log 2>&1 || { tail -20 build/release-retest.log; echo "tests failed: not releasing"; exit 1; }
fi
echo "== bundle $VERSION"
DEN_VERSION=$VERSION scripts/bundle.sh > build/release-bundle.log 2>&1 || { tail -20 build/release-bundle.log; exit 1; }
APP=build/den.app
PL=$APP/Contents/Info.plist
BUILD=$(plutil -extract CFBundleVersion raw -o - $PL)
HOSTAPI=$(plutil -extract DenHostAPI raw -o - $PL)
ABI=$(awk '/#define CORDIS_ABI_VERSION/ {print $3}' .build/checkouts/cordis-swift/Sources/CCordis/include/cordis.h)
COMMIT=$(git rev-parse HEAD)

rm -rf $DIST && mkdir -p $DIST
ditto -c -k --keepParent $APP $DIST/den-$VERSION.zip
hdiutil create -quiet -volname den -srcfolder $APP -ov -format UDZO $DIST/den-$VERSION.dmg
ZIPSIG=$($BIN/sign_update --account den -p $DIST/den-$VERSION.zip)
ZIPLEN=$(stat -f %z $DIST/den-$VERSION.zip)

URLBASE=https://github.com/$REPO/releases/download/$TAG
plugins=()
for f in $APP/Contents/PlugIns/*.dylib; do
  id=${f:t:r}
  cp $f $DIST/$id.dylib
  sha=$(shasum -a 256 $f | cut -d' ' -f1)
  sig=$($BIN/sign_update --account den -p $f)
  perms='[]' extra=''
  side=Plugins/$id/plugin.json
  [[ -f $side ]] || side=Plugins/$id/permissions.json
  if [[ -f $side ]]; then
    perms=$(plutil -extract permissions json -o - $side 2>/dev/null || print '[]')
    # Lazy loading (LazyPlugins.swift) travels with the plugin.
    l=$(plutil -extract launch raw -o - $side 2>/dev/null || true)
    [[ -n $l ]] && extra+=",\"launch\":\"$l\""
    a=$(plutil -extract activation json -o - $side 2>/dev/null || true)
    [[ -n $a ]] && extra+=",\"activation\":$a"
  fi
  plugins+=("{\"id\":\"$id\",\"version\":\"$VERSION\",\"abi\":$ABI,\"hostAPI\":$HOSTAPI,\"sha256\":\"$sha\",\"signature\":\"$sig\",\"url\":\"$URLBASE/$id.dylib\",\"permissions\":$perms$extra}")
done
CHANNEL=stable
ENTRY="{\"version\":\"$VERSION\",\"tag\":\"$TAG\",\"build\":$BUILD,\"hostAPI\":$HOSTAPI,\"commit\":\"$COMMIT\",\"plugins\":[${(j:,:)plugins}]}"

# Notes: commits since the previous tag.
LAST=$(git describe --tags --abbrev=0 2>/dev/null || true)
{ echo "den $VERSION"; echo; echo "Commits${LAST:+ since $LAST}:"; git log -n 100 --no-merges --format='- %s (%h)' ${LAST:+$LAST..}HEAD; } > $DIST/notes.md

# updates/plugins.json and updates/appcast.xml (merged with what main has).
mkdir -p updates
python3 - "$CHANNEL" "$ENTRY" updates/plugins.json $DIST/plugins.json <<'PY'
import json, sys, os
channel, entry, path, dist = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3], sys.argv[4]
doc = json.load(open(path)) if os.path.exists(path) else {"schema": 1, "channels": {}}
doc["channels"][channel] = entry
if channel == "stable":  # pre-release users get a newer stable too
    doc["channels"]["prerelease"] = entry
json.dump(doc, open(path, "w"), indent=1, sort_keys=True)
json.dump({"schema": 1, "channels": {channel: entry}}, open(dist, "w"), indent=1, sort_keys=True)
PY
python3 - updates/appcast.xml "$VERSION" "$BUILD" "$URLBASE/den-$VERSION.zip" "$ZIPSIG" "$ZIPLEN" "$PRE" "https://github.com/$REPO/releases/tag/$TAG" "$DIST/notes.md" <<'PY'
import sys, os, datetime, re
path, ver, build, url, sig, length, pre, notes, notesfile = sys.argv[1:]
head = '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n<channel>\n<title>den</title>\n'
items = ""
if os.path.exists(path):
    m = re.search(r"<title>den</title>\n(.*)</channel>", open(path).read(), re.S)
    items = m.group(1) if m else ""
date = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
chan = "  <sparkle:channel>prerelease</sparkle:channel>\n" if pre == "1" else ""
# The changelog rides in <description> (CDATA): the updates Settings panel shows it as
# "What's new" without a network fetch. Commit subjects only, capped.
desc = ""
if os.path.exists(notesfile):
    lines = [l for l in open(notesfile).read().splitlines() if l.startswith("- ")]
    desc = "<![CDATA[" + "\n".join(lines[:40])[:3500] + "]]>"
item = f"""<item>
  <title>den {ver}</title>
  <pubDate>{date}</pubDate>
{chan}  <sparkle:version>{build}</sparkle:version>
  <sparkle:shortVersionString>{ver}</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
  <sparkle:releaseNotesLink>{notes}</sparkle:releaseNotesLink>
  <description>{desc}</description>
  <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{sig}"/>
</item>
"""
open(path, "w").write(head + item + items + "</channel>\n</rss>\n")
PY
cp updates/appcast.xml $DIST/appcast.xml
echo "== built $DIST (build $BUILD, hostAPI $HOSTAPI, $(ls $DIST | wc -l | tr -d ' ') files)"
if [[ $DRY == --dry-run ]]; then git checkout -- updates 2>/dev/null || true; exit 0; fi

echo "== publish $TAG"
flags=(); (( PRE )) && flags+=(--prerelease)
gh release create $TAG $DIST/den-$VERSION.zip $DIST/den-$VERSION.dmg $DIST/*.dylib $DIST/plugins.json $DIST/appcast.xml \
  --repo $REPO --target $COMMIT --title "den $VERSION" --notes-file $DIST/notes.md $flags
git add updates/appcast.xml updates/plugins.json
git commit -q -m "release: $TAG appcast and plugin manifest" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -q origin HEAD:main || { git pull -q --rebase origin main && git push -q origin HEAD:main; }
echo "released $TAG"
