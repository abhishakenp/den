#!/bin/zsh
# Scratch only (never on main): MediaTests 8 times in a row; every pass runs, failures counted.
fails=0
for i in {1..8}; do echo "== MediaTests pass $i"; scripts/test.sh --filter MediaTests || { fails=$((fails+1)); echo "== pass $i FAILED"; }; done
echo "== MediaTests failed passes: $fails of 8"
(( fails == 0 ))
