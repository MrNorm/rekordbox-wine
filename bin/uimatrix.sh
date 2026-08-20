#!/usr/bin/env bash
# uimatrix — run the UI liveness scenario across renderer/patch variants,
# unattended, one variant per run, and print a comparison table.
#
# This is the loop the project needs now. Gate 1 was a single binary question
# ("does the window repaint") and a human could drive it. The main UI fails
# PARTIALLY — some panes live, some dead, some clicks ignored — and that cannot
# be judged by eye across a dozen configurations without someone losing track.
#
# Each variant is one variable against the same scenario. Results land in
# runs/<id>/uiprobe.{json,txt} with a dead-region map per variant.
#
# Usage: bin/uimatrix.sh [variant ...]      (default: all)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
export WINEPREFIX="$ROOT/prefixes/rb7"
APP="$WINEPREFIX/drive_c/Program Files/rekordbox/rekordbox 7.2.18/rekordbox.exe"
SCENARIO="$ROOT/scenarios/main-ui.json"
PATCHED="$ROOT/artifacts/dxgi-patched-native-11.15.dll"

# variant name -> extra WINEDLLOVERRIDES (dxgi=n always loads our patched build)
declare -A VARIANT=(
  [patched-d2d]="dxgi=n"
  [patched-nod2d]="dxgi=n,d2d1=d"
  [stock-dxgi]=""
)
ORDER=(patched-d2d patched-nod2d stock-dxgi)
[[ $# -gt 0 ]] && ORDER=("$@")

# Make sure the patched dll is in place for the variants that ask for it.
cp -f "$PATCHED" "$WINEPREFIX/drive_c/windows/system32/dxgi.dll"

launch_and_probe() { # $1 variant
  local v="$1" ovr="${VARIANT[$v]}"
  local id="$(date +%Y%m%dT%H%M%S)-rb7-ui-$v"
  local dir="$ROOT/runs/$id"
  mkdir -p "$dir"
  echo "=============================================================="
  echo "variant: $v    WINEDLLOVERRIDES='${ovr}'"
  echo "run: $id"

  pkill -f "rekordbox.exe" >/dev/null 2>&1; sleep 1
  wineserver -k >/dev/null 2>&1; sleep 1

  WINEDLLOVERRIDES="$ovr" setsid wine "$APP" >"$dir/wine.log" 2>&1 < /dev/null &
  # Wait for the MAIN window: biggest rekordbox window, ignoring the 14px-wide
  # JUCE drop-shadow helpers that otherwise get picked up by a naive `tail -1`.
  local wid="" best=0 area
  for _ in $(seq 1 40); do
    sleep 3
    best=0; wid=""
    for w in $(xdotool search --onlyvisible --class rekordbox 2>/dev/null); do
      eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)" || continue
      (( WIDTH < 100 || HEIGHT < 100 )) && continue
      area=$(( WIDTH * HEIGHT ))
      (( area > best )) && { best=$area; wid=$w; }
    done
    [[ -n "$wid" ]] && (( best > 400000 )) && break     # main UI is big; login is 682x562
  done
  if [[ -z "$wid" ]]; then
    echo "  no window (or only the login window) — variant unusable"
    echo "{\"verdict\":\"no-window\",\"variant\":\"$v\"}" > "$dir/uiprobe.json"
    return
  fi
  echo "  main window: $wid ($best px)"

  # Wait for the UI to actually DRAW before probing it. The first version of
  # this script started clicking as soon as a big window existed, and probed a
  # completely empty 1920x1006 canvas — every "no response" it reported was our
  # own impatience rather than a defect. Require the content to be non-uniform
  # (something is painted) AND stable across two samples (finished painting).
  local ready=0 prev_sd=-1 sd
  for _ in $(seq 1 40); do
    sleep 3
    xdotool windowactivate --sync "$wid" 2>/dev/null; sleep 0.3
    [[ "$(xdotool getactivewindow 2>/dev/null)" == "$wid" ]] || continue
    timeout 20 spectacle -a -b -n -o "$dir/.ready.png" >/dev/null 2>&1
    [[ -s "$dir/.ready.png" ]] || continue
    sd="$(magick "$dir/.ready.png" -colorspace Gray -format '%[fx:standard_deviation]' info: 2>/dev/null)"
    # non-uniform, and not still changing wildly between samples
    if awk "BEGIN{exit !($sd > 0.05)}" 2>/dev/null; then
      if awk "BEGIN{exit !($prev_sd > 0 && ($sd-$prev_sd < 0.01) && ($prev_sd-$sd < 0.01))}" 2>/dev/null; then
        ready=1; echo "  UI drawn and stable (stddev $sd)"; break
      fi
    fi
    prev_sd="$sd"
  done
  rm -f "$dir/.ready.png"
  if (( ! ready )); then
    echo "  UI NEVER DREW (blank canvas) — recording that, not probing it"
    echo "{\"verdict\":\"blank-main-window\",\"variant\":\"$v\",\"overrides\":\"$ovr\"}" > "$dir/uiprobe.json"
    xdotool windowclose "$wid" 2>/dev/null; sleep 5
    pkill -f "rekordbox.exe" >/dev/null 2>&1; sleep 2; wineserver -k >/dev/null 2>&1
    return
  fi

  python3 "$ROOT/bin/uiprobe.py" "$dir" "$SCENARIO" "$wid" 2>&1 | sed 's/^/  /'
  python3 - "$dir" "$v" "$ovr" <<'PY'
import json,sys
d,v,o=sys.argv[1],sys.argv[2],sys.argv[3]
try:
    r=json.load(open(d+"/uiprobe.json"))
except Exception:
    r={"verdict":"no-data"}
r["variant"]=v; r["overrides"]=o
json.dump(r,open(d+"/uiprobe.json","w"),indent=1)
PY

  # graceful close, so we never truncate the app's settings file
  xdotool windowclose "$wid" 2>/dev/null; sleep 6
  pkill -f "rekordbox.exe" >/dev/null 2>&1; sleep 2
  wineserver -k >/dev/null 2>&1; sleep 1
}

for v in "${ORDER[@]}"; do launch_and_probe "$v"; done

echo
echo "================= SUMMARY ================="
printf "%-16s %-12s %-14s %s\n" VARIANT VERDICT RESPONDING DEAD-CELLS
for v in "${ORDER[@]}"; do
  f="$(ls -t "$ROOT"/runs/*-rb7-ui-"$v"/uiprobe.json 2>/dev/null | head -1)"
  [[ -z "$f" ]] && { printf "%-16s %s\n" "$v" "(no run)"; continue; }
  python3 - "$f" "$v" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]))
print("%-16s %-12s %-14s %s" % (
    sys.argv[2], r.get("verdict","?"),
    "%s/%s" % (r.get("interactions_responded","?"), r.get("interactions_total","?")),
    "%s/%s" % (len(r.get("dead_cells",[])), r.get("grid",[8,6])[0]*r.get("grid",[8,6])[1])))
PY
done
