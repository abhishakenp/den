#!/bin/zsh
# Renders den's own UI (demo data) to docs/screenshots/ with --snapshot (no Screen Recording needed).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x build/den.app/Contents/MacOS/den ]] || scripts/bundle.sh
out=docs/screenshots
mkdir -p $out
store=$(mktemp -d)
shot() { # name scenario appearance — a fresh store each time, so the plugins' first-run seed shows
  build/den.app/Contents/MacOS/den --no-den-home --storage "$(mktemp -d)" --appearance "$3" --scenario "$2" --snapshot "$out/$1.png" --snapshot-delay "${4:-6}"
}
shot main-light main light
shot main-dark main dark
shot sidebar-hidden hidden light
shot sidebar-hover-reveal reveal light
shot space-2 space2 light
shot toast toast light 4.5
shot space-swipe swipe light
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
# Host components (self-contained scenarios, no --demo): see DenHost/Scenarios/HostScenarios.swift.
host() { # name scenario appearance
  build/den.app/Contents/MacOS/den --no-den-home --storage "$store" --appearance "$3" --scenario "$2" --snapshot "$out/$1.png" --snapshot-delay 3
}
host theme-picker themePicker light
host theme-picker-dark themePicker dark
host theme-picker-empty-dark themePickerEmpty dark
host peek-card peekCard light
host peek-card-dark peekCard dark
host split-view-chrome splitView light
host drop-indicator-dark dropIndicator dark
host library library light
host library-dark library dark
host library-clear-dark libraryClear dark
host little-arc littleArc light
host little-arc-dark littleArc dark
host quit-dialog dialogQuit light
host quit-dialog-dark dialogQuit dark
# Hover previews and the Library sheet, on the real plugin sidebar (PreviewScenarios.swift).
for sc in GitHub Calendar Page Folder; do
  n=$(echo $sc | tr A-Z a-z)
  shot preview-$n preview$sc light 5
  shot preview-$n-dark preview$sc dark 5
done
shot library-footer libraryFooter light 4
shot library-footer-dark libraryFooter dark 4
for v in DeleteSpace DeleteFolder ClearArchive; do
  n=$(echo $v | sed -E 's/([a-z])([A-Z])/\1-\2/g' | tr A-Z a-z)
  host dialog-$n dialog$v light
  host dialog-$n-dark dialog$v dark
done
# Connections + briefing: real plugins against the local fake Slack/GitHub (MockServices), private profile.
# The briefing waits for Foundation Models (plain lists when Apple Intelligence is unavailable).
if [[ -f build/den.app/Contents/PlugIns/briefing.dylib ]]; then
  host briefing-empty briefingEmpty light
  shot connect-toast connectToast light 1.5
  shot connections-settings connectionsSettings light 6
  shot briefing briefing light 30; shot briefing-dark briefing dark 30; shot briefing-feed briefingFeed light 32
fi
# Native menus are separate windows: open one and capture it through its own window id.
menu() { # name appearance
  build/den.app/Contents/MacOS/den --no-den-home --storage "$store" --appearance "$2" --scenario contextMenu --stay &
  local pid=$!; sleep 3.5
  local id=$(swift -e 'import CoreGraphics; let p = Int32(CommandLine.arguments[1])!; for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]] where w[kCGWindowOwnerPID as String] as? Int32 == p && w[kCGWindowLayer as String] as? Int == 101 { print(w[kCGWindowNumber as String]!) }' $pid | head -1)
  [[ -n $id ]] && screencapture -o -x -l$id "$out/$1.png"
  kill $pid
}
menu context-menu light
menu context-menu-dark dark
# Store at 1x (1280 pt wide) to keep the repo small.
for f in $out/*.png; do sips -Z 1280 "$f" --out "$f" >/dev/null; done
