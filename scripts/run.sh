#!/bin/zsh
# Bundle and launch den. Extra args go to the app, e.g. scripts/run.sh --demo
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh
exec build/den.app/Contents/MacOS/Den "$@"
