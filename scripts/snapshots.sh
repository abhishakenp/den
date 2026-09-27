#!/bin/zsh
# Renders den's own UI (demo data) to docs/screenshots/ with --snapshot (no Screen Recording needed).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -x build/den.app/Contents/MacOS/Den ]] || scripts/bundle.sh
out=docs/screenshots
mkdir -p $out
store=$(mktemp -d)
shot() { # name scenario appearance
  build/den.app/Contents/MacOS/Den --demo --storage "$store" --appearance "$3" --scenario "$2" --snapshot "$out/$1.png" --snapshot-delay "${4:-6}"
}
shot main-light main light
shot main-dark main dark
shot sidebar-hidden hidden light
shot sidebar-hover-reveal reveal light
shot split-view split light
shot command-bar command light
shot command-bar-dark command dark
shot quit-dialog dialog light
shot quit-dialog-dark dialog dark
shot toast toast light
shot peek peek light
shot space-swipe swipe light
# Host components (self-contained scenarios, no --demo): see DenHost/Scenarios/HostScenarios.swift.
host() { # name scenario appearance
  build/den.app/Contents/MacOS/Den --storage "$store" --appearance "$3" --scenario "$2" --snapshot "$out/$1.png" --snapshot-delay 3
}
host theme-picker themePicker light
host theme-picker-dark themePicker dark
host theme-picker-empty-dark themePickerEmpty dark
# Store at 1x (1280 pt wide) to keep the repo small.
for f in $out/*.png; do sips -Z 1280 "$f" --out "$f" >/dev/null; done
