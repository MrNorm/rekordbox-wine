#!/usr/bin/env bash
# loadplay — get a track playing, unattended, and PROVE it is playing.
#
# WHY THIS EXISTS. Half of this project's audio work needs "a track is playing"
# as a precondition, and every previous attempt to script it has failed in a way
# that looked like a finding: playtest.sh reported "playback SUSTAINED" against a
# frozen deck, and reported "no audio was written at all" when its own drag had
# missed. Today it silently failed again, and the reason turned out to be a
# harness fault worth writing on the wall:
#
#   `spectacle -a` captures the ACTIVE WINDOW PLUS ITS DROP SHADOW -- 2050x1164
#   for a 1920x1006 window. Coordinates read off such a capture are offset by
#   ~65 px horizontally from X coordinates, so every click derived from one
#   lands next to the control it was aimed at. `spectacle -f` is 1:1 with X.
#
# So: all coordinates below are X coordinates, calibrated 2026-08-17 against a
# `spectacle -f` capture of a 1920x1006 window at +0+28, in PERFORMANCE view with
# the waveform panel visible.
#
# THE PROOF. It does not screenshot the deck and guess. It reads the kernel's
# file offset for the track rekordbox has open (/proc/<pid>/fdinfo -> pos) and
# requires it to ADVANCE. A deck that is loaded but paused reads nothing; a deck
# that is playing eats the file at its bitrate. That is the same measure
# bin/enginerate.sh scores, so "it is playing" and "how fast" are the same
# instrument.
#
# Usage: bin/loadplay.sh [row]     row 0 = first library row (default: Demo Track 2)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PID=$(pgrep -f 'rekordbox\.exe' | head -1)
[ -z "$PID" ] && { echo "FAULT: rekordbox is not running"; exit 2; }
W=$(xdotool search --name '^rekordbox$' | head -1)
[ -z "$W" ] && { echo "FAULT: no rekordbox window"; exit 2; }
eval "$(xdotool getwindowgeometry --shell "$W" | tr -d '\r')"
if [ "$WIDTH" != 1920 ] || [ "$HEIGHT" != 1006 ]; then
  echo "WARNING: window is ${WIDTH}x${HEIGHT}, not the 1920x1006 these"
  echo "         coordinates were calibrated against. Re-calibrate before"
  echo "         trusting a failure from this script."
fi

# Library rows, calibrated 2026-08-17 off a `spectacle -f` capture: row 0
# (NOISE) has its centre at y=572.5 and the rows are 15 px apart. Row 4 is
# "Demo Track 2" (2:08) -- the short loop samples further down the list finish
# in a second and make a playback measurement meaningless.
ROW="${1:-4}"
LX=656
LY=$(python3 -c "print(int(572.5 + 15*$ROW))")
DX=400; DY=290          # deck 1 track bar
PX=715; PY=419          # deck 1 play button

trackpos() {
  for f in /proc/$PID/fd/*; do
    t=$(readlink "$f" 2>/dev/null) || continue
    case "$t" in
      */prefixes/*) continue ;;
      *.mp3|*.wav|*.aiff|*.flac|*.m4a)
        awk '/^pos:/{print $2}' "/proc/$PID/fdinfo/$(basename "$f")" 2>/dev/null; return ;;
    esac
  done
}

# Clear rekordbox's startup dialogs first. The update manager and the INFO
# panel sit on top of the library, so a drag aimed at a track lands on a
# dialog and this script reports "the drag did not load anything" — which
# reads like a coordinate bug and is not one.
"$(dirname "${BASH_SOURCE[0]}")/dismiss.sh" --quiet || {
  echo "   FAULT: a dialog is covering the UI (see bin/dismiss.sh). Not"
  echo "          attempting the drag — the result would be meaningless."
  exit 2
}

echo "== loadplay =="
echo "   dragging library row $ROW ($LX,$LY) onto deck 1 ($DX,$DY)"
xdotool windowactivate --sync "$W"; sleep 1
xdotool mousemove $LX $LY; sleep 0.5; xdotool click 1; sleep 0.8
xdotool mousedown 1; sleep 0.6
for i in $(seq 1 20); do
  x=$(( LX - (LX-DX)*i/20 )); y=$(( LY - (LY-DY)*i/20 ))
  xdotool mousemove $x $y; sleep 0.12
done
sleep 0.8; xdotool mouseup 1; sleep 3

# Click play, and KEEP CHECKING. A single click is not reliable: it is swallowed
# if it lands while the track is still loading, and if the deck happens to be
# playing already the same click PAUSES it. Both failures look identical from
# outside — "the deck is not advancing" — and both have voided measurements in
# this project. So: click, verify against the deck's own readout, and try again.
echo "   clicking play at ($PX,$PY)"
DECK="$(dirname "${BASH_SOURCE[0]}")/deckadvancing.sh"
CX=714; CY=372          # deck 1 CUE — returns the playhead to the cue point
for attempt in 1 2 3; do
  # From the second attempt on, send the playhead back to the start first. A
  # deck sitting at the end of a track accepts PLAY and then advances nothing,
  # which is indistinguishable from a click that missed — and it is what
  # actually happened: the drag had failed, the deck still held the finished
  # track, and every retry "played" 0.0 seconds of it.
  if [ "$attempt" -gt 1 ]; then
    xdotool mousemove $CX $CY; sleep 0.4; xdotool click 1; sleep 1
  fi
  xdotool mousemove $PX $PY; sleep 0.5; xdotool click 1; sleep 3
  if "$DECK" 2.5 >/dev/null 2>&1; then
    echo "   PLAYING: the deck readout is advancing (attempt $attempt)"
    exit 0
  fi
  echo "   attempt $attempt did not start the deck; retrying"
done

# The mp3 fd does not necessarily exist the instant play is clicked -- an
# earlier version reported "no track file is open" about a deck that was
# demonstrably playing, because it looked once, too early. Wait for it.
P0=""
for i in $(seq 1 10); do P0=$(trackpos); [ -n "$P0" ] && break; sleep 1; done
sleep 4; P1=$(trackpos)
if [ -z "$P0" ] || [ -z "$P1" ]; then
  echo "   FAULT: no track file is open — the drag did not load anything."
  exit 2
fi
if [ "$P1" -gt "$P0" ]; then
  echo "   PLAYING: file position advanced $((P1-P0)) B in 4 s"
  exit 0
fi

# The file offset is not a sufficient test. In the PC MASTER OUT fault the engine
# advances only once per 15.8 s cycle, so a 4-second window sees nothing and this
# script used to report "NOT PLAYING" about a deck that was playing at 0.05x —
# which would have voided every arm of the buffer matrix. Fall back to the deck's
# own readout, which is true whatever the engine rate.
if "$(dirname "${BASH_SOURCE[0]}")/deckadvancing.sh" 3 >/dev/null 2>&1; then
  echo "   PLAYING: the deck readout is advancing (the file offset is not, which"
  echo "            is itself the signature of the PC MASTER OUT stall)"
  exit 0
fi
echo "   NOT PLAYING: the track is loaded but its file position did not move."
echo "                Either the play click missed, or the engine is stalled"
echo "                dead. bin/enginerate.sh will not be able to tell those"
echo "                apart either — check the deck before believing a 0.00x."
exit 1
