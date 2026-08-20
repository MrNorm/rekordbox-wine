#!/usr/bin/env bash
# prefspane — open a named Preferences pane and capture it.
#
# Generalises the navigation bin/audiotest.sh does, so any pane can be
# inspected without duplicating the click sequence. Anchors come from
# scenarios/regions.json so there is ONE calibration to maintain.
#
# Usage: bin/prefspane.sh <audio|controller|view|plan|cloud|analysis> [label]
#
# Leaves Preferences OPEN. Closing it with alt+F4 quits rekordbox (measured,
# 5 cycles) -- close it by clicking its titlebar X if you need it shut.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PANE="${1:-controller}"; LABEL="${2:-$PANE}"
OUT="runs/PREFS"; mkdir -p "$OUT"
STAMP=$(date +%Y%m%dT%H%M%S)
REGIONS=scenarios/regions.json

# Sidebar row pitch is 33px from y=92 (PLAN), per the calibration comment in
# regions.json. Rows in order.
row_y() {
  case "$1" in
    plan) echo 92 ;; cloud) echo 125 ;; view) echo 158 ;;
    audio) echo 191 ;; analysis) echo 224 ;; controller) echo 257 ;;
    *) echo "unknown pane: $1" >&2; exit 2 ;;
  esac
}

MAIN=$(xdotool search --name '^rekordbox$' | head -1)
[ -z "$MAIN" ] && { echo "FAULT: rekordbox not running"; exit 2; }
eval "$(xdotool getwindowgeometry --shell "$MAIN" | tr -d '\r')"
MX=$X; MY=$Y; MW=$WIDTH
xdotool windowactivate --sync "$MAIN"; sleep 1

GDX=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['main_window_anchors']['preferences_gear']['dx_from_right'])")
GDY=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['main_window_anchors']['preferences_gear']['dy_from_top'])")
GX=$(( MX + MW - GDX )); GY=$(( MY + GDY ))

PREFS=""
for i in 1 2 3; do
  xdotool mousemove "$GX" "$GY"; sleep 0.4; xdotool click 1; sleep 2
  PREFS=$(xdotool search --name 'Preferences' | head -1)
  [ -n "$PREFS" ] && break
  echo "  gear attempt $i missed, retrying"
done
[ -z "$PREFS" ] && { echo "FAULT: Preferences did not open at ($GX,$GY)"; exit 2; }

eval "$(xdotool getwindowgeometry --shell "$PREFS" | tr -d '\r')"
PX=$X; PY=$Y
xdotool windowactivate --sync "$PREFS"; sleep 1

# Configuration tab, then the requested sidebar row.
xdotool mousemove $((PX+206)) $((PY+40)); sleep 0.3; xdotool click 1; sleep 1
xdotool mousemove $((PX+70)) $((PY+$(row_y "$PANE"))); sleep 0.3; xdotool click 1; sleep 2

SHOT="$OUT/$STAMP-$LABEL.png"
timeout 25 spectacle -a -b -n -o "$SHOT" >/dev/null 2>&1
[ -s "$SHOT" ] || { echo "FAULT: capture failed"; exit 2; }
echo "captured: $SHOT  (prefs ${WIDTH}x${HEIGHT} at +$PX+$PY)"
