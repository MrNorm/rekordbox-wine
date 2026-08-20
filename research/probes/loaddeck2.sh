#!/usr/bin/env bash
# loaddeck2 — drag a library row onto DECK 2 and start it.
#
# bin/loadplay.sh only ever drives deck 1. A single deck is not a performance
# test: the whole point of the engine work in T10 is that rekordbox services
# several sources into several devices, and two decks playing at once is the
# first configuration that actually loads it.
#
# Coordinates are X coordinates for the 1920x1006 PERFORMANCE-view window that
# bin/loadplay.sh is calibrated against; deck 2 mirrors deck 1.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROW="${1:-5}"
LX=656; LY=$(python3 -c "print(int(572.5 + 15*$ROW))")
DX=1420; DY=290          # deck 2 track bar
PX=1046; PY=419          # deck 2 play button
W=$(xdotool search --name '^rekordbox$' | head -1)
[ -n "$W" ] || { echo "FAULT: no rekordbox window"; exit 2; }
xdotool windowactivate --sync "$W"; sleep 1
xdotool mousemove $LX $LY; sleep 0.5; xdotool click 1; sleep 0.8
xdotool mousedown 1; sleep 0.6
for i in $(seq 1 20); do
  x=$(( LX + (DX-LX)*i/20 )); y=$(( LY - (LY-DY)*i/20 ))
  xdotool mousemove $x $y; sleep 0.12
done
sleep 0.8; xdotool mouseup 1; sleep 3
xdotool mousemove $PX $PY; sleep 0.5; xdotool click 1; sleep 2
echo "deck 2: dragged row $ROW and clicked play at ($PX,$PY)"
