#!/usr/bin/env bash
# playkeep — keep a deck playing for the length of a soak, and SAY when it stopped.
#
# WHY THIS EXISTS. T08's headline is a per-session frame-rate degradation:
# 55 fps fresh, 37 fps nine minutes later, "resources and clocks flat, so the
# per-frame cost itself grew". Re-running that soak with GPU memory instrumented
# showed the drop is not gradual at all — it happens inside the first minute:
#
#     t=21 s   fps 51.00   p50 22.18 ms
#     t=65 s   fps 38.35   p50 32.87 ms      <- 33 ms is the IDLE FRAME LIMITER
#     t=304 s  fps 36.85   p50 33.06 ms
#
# and the deck's own file position had stopped advancing. rekordbox renders at
# ~58 fps with a track PLAYING and runs its own 33 ms limiter otherwise, so a
# deck that stops mid-soak produces exactly the curve that has been read as
# degradation. The theme's own warning — "soaking an empty session measures the
# limiter, not the lag" — applies just as much to a deck that is loaded but has
# stopped.
#
# WHAT IT DOES. Every 20 s it decides whether the deck is advancing, and if it
# is not, it presses CUE (back to the cue point) and then PLAY, recording the
# event.
#
# HOW IT KNOWS — and why the obvious signal does not work. The first version
# read the track's file offset from /proc/<pid>/fdinfo, which is the same signal
# bin/enginerate.sh uses. That is exact while the file is being read, and then
# it dies: a 5 MB track is read to the end in about two minutes and the offset
# freezes at EOF even though the deck plays on happily from memory. The result
# was a watchdog that "detected a stall" every 13 s and toggled play/pause on a
# perfectly healthy deck for the rest of the soak.
#
# So the signal is the deck's own elapsed-time readout, hashed from two captures
# 1.2 s apart. It costs a screenshot every 20 s, and unlike the file offset it
# stays true for as long as the deck exists. At the end it prints how many times it
# had to intervene — a soak that needed no intervention is a soak whose deck
# played throughout, and only that soak's frame rate means anything.
#
# It deliberately does NOT click when the deck is playing: that would pause it,
# which is how this confound was created in the first place.
#
# Usage: bin/playkeep.sh <seconds>     (run it in the background beside a soak)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SECS="${1:-600}"
PX=715; PY=419          # deck 1 play button, X coordinates (see bin/loadplay.sh)

PID=$(pgrep -x 'rekordbox.exe' | head -1)
[ -z "$PID" ] && { echo "playkeep: rekordbox is not running"; exit 2; }
W=$(xdotool search --name '^rekordbox$' | head -1)

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TIMEBOX="220x30+590+248"        # deck 1 elapsed/remaining, X coords, spectacle -f

# A hash of the time readout. An empty or failed crop hashes to a constant and
# would compare equal for ever, i.e. "frozen", so those cases are reported
# rather than acted on.
timehash() {
  local f="$TMP/t.png" h
  rm -f "$f"
  timeout 25 spectacle -f -b -n -o "$f" >/dev/null 2>&1
  [ -s "$f" ] || { echo CAPTURE_FAILED; return; }
  h=$(magick "$f" -crop "$TIMEBOX" +repage -colorspace Gray -depth 8 txt:- 2>/dev/null | md5sum | cut -c1-12)
  [ -z "$h" ] && { echo CROP_FAILED; return; }
  echo "$h"
}

advancing() {
  local a b
  a=$(timehash); sleep 1.2; b=$(timehash)
  case "$a$b" in *FAILED*) echo FAULT; return ;; esac
  [ "$a" != "$b" ] && echo YES || echo NO
}

echo "playkeep: watching for ${SECS}s"
KICKS=0; FAULTS=0
CX=714; CY=372          # deck 1 CUE button — a track that has reached its end
                        # will not restart on PLAY alone
END=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$END" ]; do
  sleep 20
  case "$(advancing)" in
    YES) ;;
    FAULT)
      FAULTS=$((FAULTS+1))
      echo "playkeep: could not read the deck at $(date +%H:%M:%S) — NOT intervening blindly"
      ;;
    NO)
      KICKS=$((KICKS+1))
      echo "playkeep: deck stopped at $(date +%H:%M:%S) — CUE then PLAY (kick $KICKS)"
      xdotool windowactivate --sync "$W" 2>/dev/null
      sleep 0.5; xdotool mousemove $CX $CY; sleep 0.3; xdotool click 1
      sleep 1;   xdotool mousemove $PX $PY; sleep 0.3; xdotool click 1
      sleep 2
      ;;
  esac
done
echo "playkeep: finished, $KICKS intervention(s), $FAULTS unreadable check(s)"
[ "$KICKS" -eq 0 ] && echo "playkeep: the deck played throughout — the soak beside this is valid"
