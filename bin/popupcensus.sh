#!/usr/bin/env bash
# popupcensus — which of rekordbox's popups actually open, and which produce nothing?
#
# T04 recorded "the File menu never opens" and treated it as a menu-bar bug. This
# asks the wider question, because a JUCE PopupMenu is a real top-level X window:
# clicking a control that should open one either creates windows or it does not.
# Counts ALL windows, mapped or not -- a popup created and never mapped is a
# different bug from one never created.
#
# SEQUENCING IS THE TRAP. Once a JUCE menu bar is active, moving along it switches
# menus without creating anything, so a probe that follows another probe too
# closely reports a working menu as dead. The reset here is deliberate and slow:
# Escape twice, pointer parked far away, and the "before" count taken twice and
# required to agree before the click is allowed to count.
#
# Usage: bin/popupcensus.sh [passes]      (coordinates are for the 1920x1006 window)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASSES="${1:-3}"
W=$(xdotool search --name '^rekordbox$' | head -1)
[ -n "$W" ] || { echo "FAULT: no rekordbox window"; exit 2; }
xdotool windowactivate --sync "$W"; sleep 0.6

count() { xdotool search --name '.*' 2>/dev/null | wc -l; }

reset() {
  xdotool key Escape; sleep 0.3
  xdotool key Escape; sleep 0.3
  xdotool mousemove 1900 990; sleep 0.9
}

probe_once() { # probe_once <x> <y> -> echoes the window delta, or "void"
  local x="$1" y="$2" a b after
  reset
  a=$(count); sleep 0.4; b=$(count)
  [ "$a" != "$b" ] && { echo void; return; }
  xdotool mousemove "$x" "$y"; sleep 0.4
  xdotool click 1; sleep 1.3
  after=$(count)
  echo $((after - a))
}

probe() { # probe <label> <x> <y>
  local label="$1" x="$2" y="$3" opens=0 voids=0 deltas=""
  for i in $(seq 1 "$PASSES"); do
    d=$(probe_once "$x" "$y")
    if [ "$d" = void ]; then voids=$((voids+1)); deltas="$deltas ?"
    else deltas="$deltas $d"; [ "$d" -gt 0 ] && opens=$((opens+1)); fi
  done
  printf '  %-34s %d/%d opened   deltas:%s%s\n' \
    "$label" "$opens" "$PASSES" "$deltas" \
    "$([ "$voids" -gt 0 ] && echo "  ($voids void)")"
}

echo "== popup census, $PASSES passes each =="
probe "menu bar: File"            23  39
probe "menu bar: View"            73  39
probe "menu bar: Track"          129  39
probe "menu bar: Playlist"       191  39
probe "menu bar: Help"           252  39
probe "toolbar: PERFORMANCE mode" 115  64
probe "deck 1: INT source"        713 337
probe "deck 1: HOT CUE"            97 427
