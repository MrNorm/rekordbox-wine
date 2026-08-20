#!/usr/bin/env bash
# reselect-audio — open Preferences > Audio and drop down the Audio Device combo.
#
# Hypothesis under test: the Sample Rate list is empty not because Wine cannot
# probe formats (upstream/wasapitest.exe reports 48/48 exclusive formats
# accepted on the DDJ-400 right now) but because rekordbox is holding a STALE
# device selection. It builds the rate list at device-selection time, so a
# selection that no longer resolves to a live endpoint yields a populated device
# combo -- "DDJ-400 WASAPI" is displayed -- above an empty rate combo.
#
# If that is right, re-picking the device from the dropdown repopulates the
# rates and the whole "regression" is a stale setting, not a Wine bug.
#
# This only OPENS the dropdown and captures it. It does not click an entry,
# because we do not yet know what the entries are and clicking blind in a
# combo list is how you silently select the wrong device and then measure it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="runs/RESELECT"; mkdir -p "$OUT"
STAMP=$(date +%Y%m%dT%H%M%S)

shot() { timeout 25 spectacle -a -b -n -o "$OUT/$STAMP-$1.png" >/dev/null 2>&1; echo "  shot: $OUT/$STAMP-$1.png"; }
geom() { xdotool getwindowgeometry --shell "$1" | tr -d '\r'; }

MAIN=$(xdotool search --name '^rekordbox$' | head -1)
[ -z "$MAIN" ] && { echo "FAULT: rekordbox not running"; exit 2; }
eval "$(geom "$MAIN")"; MX=$X; MY=$Y; MW=$WIDTH
xdotool windowactivate --sync "$MAIN"; sleep 1

# Preferences gear: anchored to the window's RIGHT edge, not scaled.
GX=$(( MX + MW - 261 )); GY=$(( MY + 35 ))
for i in 1 2 3; do
  xdotool mousemove "$GX" "$GY"; sleep 0.3; xdotool click 1; sleep 2
  PREFS=$(xdotool search --name 'Preferences' | head -1)
  [ -n "$PREFS" ] && break
done
[ -z "$PREFS" ] && { echo "FAULT: Preferences did not open"; shot 00-gearmiss; exit 2; }
eval "$(geom "$PREFS")"; PX=$X; PY=$Y
xdotool windowactivate --sync "$PREFS"; sleep 1

# Configuration tab, then the Audio sidebar row.
xdotool mousemove $((PX+206)) $((PY+40));  sleep 0.3; xdotool click 1; sleep 1
xdotool mousemove $((PX+70))  $((PY+191)); sleep 0.3; xdotool click 1; sleep 1.5
shot 01-audio-pane

# Drop down the Audio Device combo (combo spans x 218..757, value row y~126).
xdotool mousemove $((PX+400)) $((PY+126)); sleep 0.4; xdotool click 1; sleep 1.5
shot 02-device-dropdown

echo
echo "Dropdown captured. Inspect 02-device-dropdown.png for the entry list."
echo "Preferences left OPEN deliberately -- closing it with alt+F4 quits"
echo "rekordbox (measured, 5 cycles), and the dropdown state is the evidence."
