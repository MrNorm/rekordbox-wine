#!/usr/bin/env bash
# uilag — is the UI responsive, and is anything burning CPU behind it?
#
# WHY: "the UI is extremely laggy" is a real regression and nothing in this
# project measured it. Worse, it is exactly the symptom a badly-tuned audio
# event would produce -- a client woken thousands of times a second starves the
# UI thread and hammers wineserver -- so without a number here it is impossible
# to tell a Wine audio patch that HELPED playback from one that WRECKED the app.
#
# WHAT IT MEASURES
#
#   rekordbox CPU%   the app itself. A DJ app idling with one track loaded
#                    should not be pegged.
#   wineserver CPU%  THE KEY SIGNAL. wineserver arbitrates every cross-process
#                    call and every event object. High wineserver CPU means
#                    something is doing enormous numbers of server round-trips,
#                    which for this project means audio event signalling.
#   click latency    wall-clock from an xdotool click on a library row to the
#                    row's selection highlight actually changing on screen.
#                    Coarse (spectacle costs ~1s a frame) but it catches the
#                    difference between "instant" and "seconds".
#
# Baselines recorded 2026-08-14 with a track loaded and playing:
#   patch 0009 (event fires whenever ANY space is free): rekordbox 150%,
#                                                        wineserver 44%  -- LAGGY
#
# Usage: research/probes/uilag.sh [sample_seconds]     (default 10)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SECS="${1:-10}"
OUT="runs/UILAG"; mkdir -p "$OUT"
STAMP=$(date +%Y%m%dT%H%M%S)

PID=$(pgrep -f 'rekordbox\.exe' | head -1)
[ -z "$PID" ] && { echo "FAULT: rekordbox not running"; exit 2; }
WSPID=$(pgrep -x wineserver | head -1)

# /proc/<pid>/stat fields 14,15 are utime,stime in clock ticks.
cpu_ticks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null; }
HZ=$(getconf CLK_TCK)

echo "== UI responsiveness  $STAMP =="
r0=$(cpu_ticks "$PID"); w0=$(cpu_ticks "${WSPID:-$PID}")
sleep "$SECS"
r1=$(cpu_ticks "$PID"); w1=$(cpu_ticks "${WSPID:-$PID}")

rcpu=$(python3 -c "print(f'{($r1-$r0)/$HZ/$SECS*100:.1f}')")
wcpu=$(python3 -c "print(f'{($w1-$w0)/$HZ/$SECS*100:.1f}')")
printf '  rekordbox.exe CPU : %s%%\n' "$rcpu"
printf '  wineserver    CPU : %s%%\n' "$wcpu"

# --- click latency ------------------------------------------------------
W=$(xdotool search --name '^rekordbox$' | head -1)
eval "$(xdotool getwindowgeometry --shell "$W" | tr -d '\r')"
LX=$((X + $(python3 -c "print(int(0.367*$WIDTH))")))
LY1=$((Y + $(python3 -c "print(int(0.575*$HEIGHT))")))
LY2=$((Y + $(python3 -c "print(int(0.597*$HEIGHT))")))

shot() { timeout 25 spectacle -a -b -n -o "$1" >/dev/null 2>&1; }
# Region covering the two library rows, as a fraction of the capture.
region() { magick "$1" -crop 600x40+700+640 +repage -colorspace Gray -depth 8 txt:- 2>/dev/null | md5sum | cut -c1-8; }

xdotool windowactivate --sync "$W"; sleep 1
xdotool mousemove "$LX" "$LY1"; sleep 0.3; xdotool click 1; sleep 2
shot "$OUT/$STAMP-a.png"; before=$(region "$OUT/$STAMP-a.png")

t0=$(date +%s.%N)
xdotool mousemove "$LX" "$LY2"; sleep 0.2; xdotool click 1
changed=""
for i in $(seq 1 8); do
  shot "$OUT/$STAMP-b.png"
  if [ "$(region "$OUT/$STAMP-b.png")" != "$before" ]; then
    changed=$(python3 -c "import time;print(f'{time.time()-$t0:.2f}')")
    break
  fi
done

if [ -n "$changed" ]; then
  printf '  click -> repaint  : %ss  (includes ~1s capture overhead)\n' "$changed"
else
  printf '  click -> repaint  : NO CHANGE detected in 8 captures -- UI may be frozen\n'
fi

echo
echo "  interpretation:"
echo "    wineserver above ~10%% means excessive server round-trips; for this"
echo "    project that has meant audio event signalling waking the client far"
echo "    too often. Compare against the baselines in the header."
