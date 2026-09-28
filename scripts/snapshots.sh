#!/bin/zsh
# Renders den's own UI (demo data) to docs/screenshots/ with --snapshot (no Screen Recording needed).
# Every run is --background: no Dock icon, never activated, windows off every display, and it quits
# by itself (den_bounded kills it if not). Only the native-menu shots need a window on screen:
# MENUS=1 adds them. The app is build/den.app built with the Scenarios trait (DEN_SCENARIOS=1).
# SNAPSHOT_APPEARANCE=dark: every shot renders dark as <name>-dark.png (a "-light" suffix is dropped
# first; each output is rendered once), the theming grid as theming-grid-dark.png (dark rows only),
# and a failed or hung shot warns instead of stopping the run. The CI snapshot job uses it
# (docs/dev.md), so dark variants never need a local build.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/launch.zsh
[[ $(plutil -extract DenScenarios raw -o - build/den.app/Contents/Info.plist 2>/dev/null) == true ]] || DEN_SCENARIOS=1 scripts/bundle.sh
den_check_app build/den.app
trap 'den_leftovers build/den.app' EXIT
den=(den_bounded 120 build/den.app/Contents/MacOS/den --background)
out=docs/screenshots
mkdir -p $out
store=$(mktemp -d)
dark_only=0
[[ ${SNAPSHOT_APPEARANCE:-} == dark ]] && dark_only=1
typeset -A rendered
made=()
# Sets _n (output name) and _ap (appearance) for a call; returns 1 when dark mode already rendered it.
resolve() { # name appearance
  _n=$1 _ap=$2
  (( dark_only )) || return 0
  _n=${_n%-light}
  [[ $_n == *-dark ]] || _n=$_n-dark
  _ap=dark
  [[ -z ${rendered[$_n]:-} ]] || return 1
  rendered[$_n]=1
  made+=("$out/$_n.png")
}
# One bounded launch, logged with the elapsed time. In dark mode a failure only warns.
run() {
  print -u2 "[$(( SECONDS / 60 ))m$(( SECONDS % 60 ))s] den ${(j: :)@}"
  $den "$@" && return 0
  local rc=$?
  (( dark_only )) && { print -u2 "warning: den exited $rc: ${(j: :)@}"; return 0; }
  return $rc
}
# Shots added for the guide (docs/guide/_screenshots-todo.md) warn instead of stopping the run:
# several need the network, and a few are self-checks that exit on their own.
soft() { "$@" || print -u2 "warning: snapshot failed: $*"; }
shot() { # name scenario appearance [delay] — a fresh store each time, so the plugins' first-run seed shows
  resolve "$1" "$3" || return 0
  run --no-den-home --storage "$(mktemp -d)" --appearance "$_ap" --scenario "$2" --snapshot "$out/$_n.png" --snapshot-delay "${4:-6}"
}
# ONLY=cards scripts/snapshots.sh: hover cards, the PR peek, the ⇧-hover link card and the
# auto-connect toast (PreviewScenarios, ConnectionScenarios), light and dark, invisible (--background).
card() { # name scenario appearance [delay]
  build/den.app/Contents/MacOS/den --no-den-home --background --storage "$(mktemp -d)" --appearance "$3" --scenario "$2" --snapshot "$out/$1.png" --snapshot-delay "${4:-6}"
}
if [[ ${ONLY:-} == cards ]]; then
  for pair in card-tab:previewTab card-pinned:previewPinned card-split:previewSplit card-playing:previewPlaying \
              pr-peek-passing:prPassing pr-peek-failing:prFailing pr-peek-conflicts:prConflicts pr-peek-private:prPrivate \
              link-card:linkCard connected-toast:autoConnectToast; do
    n=${pair%%:*}; sc=${pair#*:}
    card $n $sc light; card $n-dark $sc dark
  done
  for f in $out/card-*.png $out/pr-peek-*.png $out/link-card*.png $out/connected-toast*.png; do sips -Z 1280 "$f" --out "$f" >/dev/null; done
  exit 0
fi
# ONLY=new scripts/snapshots.sh: just the space menu, Settings and theming shots.
if [[ -z ${ONLY:-} ]]; then
shot main-light main light
shot main-dark main dark
shot sidebar-hidden hidden light
shot sidebar-hover-reveal reveal light
shot space-2 space2 light
shot empty-space emptySpace light
shot toast toast light 4.5
shot space-swipe swipe light
# Media (NowPlayingScenarios, MediaScenarios): the now-playing dock with a row's hover playback
# buttons, a web panel beside the tab, and the mini player's extras (host chip, keep on top, CC).
if [[ -f build/den.app/Contents/PlugIns/media.dylib ]]; then shot now-playing nowPlaying light 5; shot now-playing-dark nowPlaying dark 5; fi
if [[ -f build/den.app/Contents/PlugIns/panels.dylib ]]; then shot web-panel webPanel light 6; shot web-panel-dark webPanel dark 6; fi
snapMiniShot() { # name appearance
  resolve "$1" "$2" || return 0
  soft run --no-den-home --storage "$(mktemp -d)" --appearance "$_ap" --scenario miniExtras --snapshot "$out/$_n.png" --snapshot-delay 9
}
snapMiniShot mini-player-extras light
snapMiniShot mini-player-extras-dark dark
# These need the commandbar, quit and peek plugins; the PNGs in docs/screenshots predate them.
if [[ -f build/den.app/Contents/PlugIns/peek.dylib ]]; then shot split-view split light; shot split-grid split3 light; shot peek peek light; shot little-arc-link littleArcLink light; fi
if [[ -f build/den.app/Contents/PlugIns/commandbar.dylib ]]; then shot command-bar command light; shot command-bar-dark command dark; shot command-bar-edit commandEdit light; shot command-bar-actions commandActions light; shot command-bar-actions-dark commandActions dark; fi
# The bar as a launcher, with a stand-in settings registry (CommandBarScenarios.launcher).
if [[ -f build/den.app/Contents/PlugIns/commandbar.dylib ]]; then
  for q in extensions settings "dark mode" dl; do
    n=launcher-${q// /-}
    shot $n "launcher:$q" light 3
    shot $n-dark "launcher:$q" dark 3
  done
fi
if [[ -f build/den.app/Contents/PlugIns/theme.dylib ]]; then shot theme-picker-live themeLive light; shot theme-picker-live-dark themeLive dark; fi
if [[ -f build/den.app/Contents/PlugIns/quit.dylib ]]; then shot quit-dialog dialog light; shot quit-dialog-dark dialog dark; fi
# Onboarding (the tips plugin): the tour card, a tour step and a tip toast.
if [[ -f build/den.app/Contents/PlugIns/tips.dylib ]]; then
  for p in tourCard:tour-card tourStep:tour-step tipToast:tip-toast; do
    soft shot ${p##*:} ${p%%:*} light 3
    soft shot ${p##*:}-dark ${p%%:*} dark 3
  done
fi
# Host components (self-contained scenarios, no --demo): see DenHost/Scenarios/HostScenarios.swift.
host() { # name scenario appearance [delay]
  resolve "$1" "$3" || return 0
  run --no-den-home --storage "$store" --appearance "$_ap" --scenario "$2" --snapshot "$out/$_n.png" --snapshot-delay "${4:-3}"
}
host theme-picker themePicker light
host theme-picker-dark themePicker dark
host theme-picker-empty-dark themePickerEmpty dark
host peek-card peekCard light
host peek-card-dark peekCard dark
host split-view-chrome splitView light
host drop-indicator-dark dropIndicator dark
host drop-on-tab dropOnTab light
host drop-on-tab-dark dropOnTab dark
host tab-audio tabAudio light
host tab-audio-dark tabAudio dark
host library library light
host library-dark library dark
host library-clear-dark libraryClear dark
host little-arc littleArc light
host little-arc-dark littleArc dark
host quit-dialog dialogQuit light
host quit-dialog-dark dialogQuit dark
host find-bar findBar light
host find-bar-dark findBar dark
# Hover previews and the Library sheet, on the real plugin sidebar (PreviewScenarios.swift).
# The favorites grid filling the sidebar width with 1, 2, 3, 4, 5 and 12 favorites (Arc).
for n in 1 2 3 4 5 12; do shot favorites-$n-dark "favorites:$n" dark 4; done
# The tab and split cards also render here, so the CI dark run catches a broken card icon.
shot card-tab-dark previewTab dark 6
shot card-split-dark previewSplit dark 6
for sc in Calendar Folder Gmail; do  # the other tab cards and the PR peek: ONLY=cards
  n=$(echo $sc | tr A-Z a-z)
  shot preview-$n preview$sc light 5
  shot preview-$n-dark preview$sc dark 5
done
shot library-footer libraryFooter light 4
# The link status pill (Arc): a plain hover over a link, after the full address shows.
soft shot link-status linkStatus light 6
shot library-footer-dark libraryFooter dark 4
# Library ▸ Downloads with the sidebar's download ring, and the upload picker (DownloadScenarios.swift).
shot downloads downloads light 4
shot downloads-dark downloads dark 4
host upload-picker uploadPicker light
host upload-picker-dark uploadPicker dark
# Web page prompts and error pages (PromptScenarios.swift).
for sc in jsAlert jsPrompt httpAuth permissionCamera errorHost errorOffline errorSecure; do
  n=$(echo $sc | sed -E 's/([a-z])([A-Z])/\1-\2/g' | tr A-Z a-z)
  host $n $sc light
  host $n-dark $sc dark
done
for v in DeleteSpace DeleteFolder ClearArchive; do
  n=$(echo $v | sed -E 's/([a-z])([A-Z])/\1-\2/g' | tr A-Z a-z)
  host dialog-$n dialog$v light
  host dialog-$n-dark dialog$v dark
done
# Shields: the per-site panel over a real page (it waits for the lists to compile in the fresh store),
# and the HTTPS-first and lookalike interstitials, reached by real navigations. Invisible windows.
if [[ -f build/den.app/Contents/PlugIns/shields.dylib ]]; then
  shields_shot() { # name scenario appearance delay
    resolve "$1" "$3" || return 0
    run --no-den-home --storage "$store/shields" --appearance "$_ap" --scenario "$2" --snapshot "$out/$_n.png" --snapshot-delay "$4"
  }
  shields_shot shields-panel shieldsPanel light 45
  shields_shot shields-panel-dark shieldsPanel dark 30
  shields_shot shields-https shieldsHTTPS light 14
  shields_shot shields-https-dark shieldsHTTPS dark 14
  shields_shot shields-lookalike shieldsLookalike light 6
  shields_shot shields-lookalike-dark shieldsLookalike dark 6
fi
# Connections + briefing: real plugins against the local fake Slack/GitHub (MockServices), private profile.
# The briefing waits for Foundation Models (plain lists when Apple Intelligence is unavailable).
if [[ -f build/den.app/Contents/PlugIns/briefing.dylib ]]; then
  host briefing-empty briefingEmpty light
  shot connect-toast connectToast light 1.5
  shot connections-settings connectionsSettings light 6
  shot briefing briefing light 30; shot briefing-dark briefing dark 30; shot briefing-feed briefingFeed light 32
  soft shot connections-sheet connectionsSettings light 8; soft shot connections-sheet-dark connectionsSettings dark 8
  soft shot meeting-reminder meetingReminder light 8; soft shot meeting-reminder-dark meetingReminder dark 8
  soft shot live-folder liveFolder light 10; soft shot live-folder-dark liveFolder dark 10
fi
# Shots for the user guide (docs/guide/_screenshots-todo.md), as light/dark pairs.
# Password vault (VaultScenarios: MockServices login pages, in-memory store, scripted Touch ID).
for v in Save Suggest Fill Generate Sheet; do
  soft shot vault-${(L)v} vault$v light 6
  soft shot vault-${(L)v}-dark vault$v dark 6
done
# Page prompts: fileUpload is a self-check that opens the real file panel as a sheet and exits
# after ~4 s, so it is captured while the sheet is up.
soft host js-confirm jsConfirm light
soft host js-confirm-dark jsConfirm dark
soft host file-upload fileUpload light 2.5
soft host file-upload-dark fileUpload dark 2.5
# The command bar with den's real settings, a site keyword and the shortcuts row.
if [[ -f build/den.app/Contents/PlugIns/commandbar.dylib ]]; then
  for q in "search suggestions:settings" "yt:keyword" "keyboard shortcuts:shortcuts"; do
    soft shot command-bar-${q##*:} "commandBar:${q%:*}" light 3
    soft shot command-bar-${q##*:}-dark "commandBar:${q%:*}" dark 3
  done
fi
# Little Arc, then Cmd-O into the space. littleArcCmdO checks itself and exits ~2.3 s after the
# first frame, so the snapshot is taken just before that (network: swift.org).
if [[ -f build/den.app/Contents/PlugIns/peek.dylib ]]; then
  soft shot little-arc-cmd-o littleArcCmdO light 2
  soft shot little-arc-cmd-o-dark littleArcCmdO dark 2
fi
# Dark mode for websites: a normally light page (network: example.com), always in a dark space.
page() { # name url appearance delay
  resolve "$1" "$3" || return 0
  run --no-den-home --storage "$(mktemp -d)" --appearance "$_ap" --scenario page --url "$2" --snapshot "$out/$_n.png" --snapshot-delay "$4"
}
soft page dark-mode-site https://example.com dark 6
# Page tools (PageToolsScenarios, network: Wikipedia, MDN). Translation needs macOS's on-device
# language models; where they aren't installed the page stays untranslated.
if [[ -f build/den.app/Contents/PlugIns/pagetools.dylib ]]; then
  for p in reader:reader:12 translate:translated:40 zap:zap:10 highlightLink:highlight-link:14; do
    sc=${p%%:*} rest=${p#*:}
    soft shot pagetools-${rest%:*} $sc light ${rest##*:}
    soft shot pagetools-${rest%:*}-dark $sc dark ${rest##*:}
  done
  # Share and clipboard: the QR code popover and a copy toast (network: example.com).
  soft shot qr-code qrCode light 9
  soft shot qr-code-dark qrCode dark 9
  soft shot copy-toast copyToast light 3.2
  soft shot copy-toast-dark copyToast dark 3.2
fi
# Extensions (ExtensionScenarios.extensionsVerify, network: Chrome Web Store, Firefox Add-ons):
# installs real extensions and writes its own PNGs to $DEN_SNAPSHOT_DIR, then exits; capped at 10 min.
exts() { # appearance
  local d=$(mktemp -d) f n
  DEN_SNAPSHOT_DIR=$d den_bounded 600 build/den.app/Contents/MacOS/den --background --no-den-home --storage "$(mktemp -d)" --appearance $1 --scenario extensionsVerify ||
    print -u2 "warning: extensionsVerify ($1) failed; some extensions-*.png may be missing"
  for f in $d/*.png(N); do
    n=${f:t:r}
    [[ $1 == dark ]] && n=$n-dark
    mv "$f" "$out/$n.png"
    if (( dark_only )); then made+=("$out/$n.png"); fi
  done
}
if [[ -f build/den.app/Contents/PlugIns/extensions.dylib ]]; then
  (( dark_only )) || exts light
  exts dark
fi
fi  # ONLY=new
# Native menus are separate windows AppKit puts on a display: open one and capture it through its
# own window id. These are the only shots with a window on screen, so they run only with MENUS=1.
menu() { # name appearance [scenario] — the space menu needs the plugins' first-run seed, so a fresh store
  [[ -n ${MENUS:-} ]] || return 0
  resolve "$1" "$2" || return 0
  build/den.app/Contents/MacOS/den --no-den-home --storage "$(mktemp -d)" --appearance "$_ap" --scenario "${3:-contextMenu}" --exit-after 8 &
  local pid=$!; sleep 3.5
  local id=$(swift -e 'import CoreGraphics; let p = Int32(CommandLine.arguments[1])!; for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] where w[kCGWindowOwnerPID as String] as? Int32 == p && w[kCGWindowLayer as String] as? Int == 101 { print(w[kCGWindowNumber as String]!) }' $pid | head -1)
  if [[ -n $id ]]; then screencapture -o -x -l$id "$out/$_n.png" || print -u2 "warning: screencapture failed for $_n"; else print -u2 "warning: no window to capture for $_n"; fi
  kill -9 $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
}
if [[ -z ${ONLY:-} ]]; then menu context-menu light; menu context-menu-dark dark; fi
menu space-menu light spaceMenu
menu space-menu-dark dark spaceMenu
# Spaces: the icon picker, inline rename, and the footer's live drag-reorder (mid-drag).
for sc in IconPicker Rename Reorder; do
  n=$(echo $sc | sed -E 's/([a-z])([A-Z])/\1-\2/g' | tr A-Z a-z)
  shot space-$n space$sc light 3
  shot space-$n-dark space$sc dark 3
done
# Emoji tab and folder icons (Change Icon… / an emoji typed first), and the picker on a tab.
shot tab-emoji-icons tabEmojiIcons light 3
shot tab-emoji-icons-dark tabEmojiIcons dark 3
shot tab-icon-picker tabIconPicker light 3
shot tab-icon-picker-dark tabIconPicker dark 3
# Settings (⌘,): each section, from the real plugins. The Settings window draws blank through
# cacheDisplay, so it's captured by its window id (den's own window only; off-display works too).
win() { # name scenario appearance width
  resolve "$1" "$3" || return 0
  build/den.app/Contents/MacOS/den --background --no-den-home --storage "$(mktemp -d)" --appearance "$_ap" --scenario "$2" --exit-after 10 &
  local pid=$!; sleep 5
  local id=$(swift -e 'import CoreGraphics; let p = Int32(CommandLine.arguments[1])!; let w = Double(CommandLine.arguments[2])!; for x in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] where x[kCGWindowOwnerPID as String] as? Int32 == p { let b = x[kCGWindowBounds as String] as! [String: Any]; if abs((b["Width"] as! Double) - w) < 2 { print(x[kCGWindowNumber as String]!) } }' $pid $4 | head -1)
  if [[ -n $id ]]; then screencapture -o -x -l$id "$out/$_n.png" || print -u2 "warning: screencapture failed for $_n"; else print -u2 "warning: no window to capture for $_n"; fi
  kill -9 $pid 2>/dev/null || true; wait $pid 2>/dev/null || true
}
for sc in "" Tabs Search Connections Briefing; do
  if [[ -n $sc ]]; then n=settings-${(L)sc}; else n=settings; fi
  win $n settings$sc light 740
  win $n-dark settings$sc dark 740
done
# Theming: every surface follows the space. Four themes x light/dark x six surfaces, composed
# into one grid (scripts/lib/grid.swift); each surface opens through its real path.
# (Dark mode: only the dark rows, as theming-grid-dark.png.)
tdir=$(mktemp -d)
cells=()
aps=(light dark) grid=theming-grid
(( dark_only )) && aps=(dark) grid=theming-grid-dark
tshot() { # name scenario appearance delay — the cells, named as is in either mode
  $den --no-den-home --storage "$(mktemp -d)" --appearance "$3" --scenario "$2" --snapshot "$out/$1.png" --snapshot-delay "$4"
}
for t in sandy purple nearBlack pastel; do
  for ap in $aps; do
    cells+=("label:$t $ap")
    for sf in alert confirm quit command toast hover; do
      tshot _theme-$t-$ap-$sf "themeSample:$t:$sf" $ap 3 || tshot _theme-$t-$ap-$sf "themeSample:$t:$sf" $ap 4 || true  # retry once under load
      [[ -f $out/_theme-$t-$ap-$sf.png ]] || { print -u2 "warning: no _theme-$t-$ap-$sf.png"; continue; }
      mv "$out/_theme-$t-$ap-$sf.png" "$tdir/$t-$ap-$sf.png"
      case $sf in
        alert|confirm|quit) crop=0.3,0.28,0.7,0.68 ;;
        command) crop=0.18,0.2,0.82,0.62 ;;
        toast) crop=0.58,0.0,1.0,0.16 ;;
        hover) crop=0.12,0.38,0.44,0.98 ;;
      esac
      cells+=("$tdir/$t-$ap-$sf.png" "$crop")
    done
  done
done
swift scripts/lib/grid.swift "$out/$grid.png" 6 300 190 "${cells[@]}"
(( dark_only )) && made+=("$out/$grid.png")
# Store at 1x (1280 pt wide) to keep the repo small.
files=($out/*.png)
[[ -n ${ONLY:-} ]] && files=($out/space-*.png $out/settings*.png $out/theming-grid.png)
(( dark_only )) && files=(${^made}(N))
for f in $files; do sips -Z 1280 "$f" --out "$f" >/dev/null; done
