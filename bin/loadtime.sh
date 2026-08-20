#!/usr/bin/env bash
# loadtime — HOW LONG does rekordbox take to load a track, and does the audio
#            configuration change it?
#
# WHY THIS EXISTS. The user's own clue, unexplained since it was reported: "a
# significant delay loading a track, and only when the DDJ-400 is the selected
# audio device". It is not snd_pcm_open (measured at 0.10 ms). Nobody had ever
# put a number on the delay itself.
#
# WHAT IT TIMES. From the moment the drag is released to the moment rekordbox
# opens the audio file — /proc/<pid>/fd, polled every 200 ms. The kernel's own
# record of the file being opened is a harder signal than any pixel: it cannot
# be confused by a UI that has drawn the title but not finished loading.
#
# The deck is chosen with --deck 2 so an already-loaded deck 1 is left alone.
# Run it in both audio configurations and compare; nothing else may change.
#
# Usage: bin/loadtime.sh [row] [--deck 1|2]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROW="${1:-4}"
DECK=2; [ "${2:-}" = "--deck" ] && DECK="${3:-2}"
PID=$(pgrep -f 'rekordbox\.exe' | head -1)
[ -z "$PID" ] && { echo "FAULT: rekordbox is not running"; exit 2; }
W=$(xdotool search --name '^rekordbox$' | head -1)

# Track fd NUMBERS, not a count: reloading the same deck can close one fd and
# open another, and a count would never move. A new number is the event.
# fd:inode pairs, not bare fd numbers: reloading a deck can hand the same fd
# number back for a different file, and a bare-number check then misses the load
# entirely and reports "not opened within 30 s" about a track that loaded fine.
musicfds() { for f in /proc/$PID/fd/*; do t=$(readlink "$f" 2>/dev/null) || continue
               case "$t" in */Music/*) echo -n "$(basename $f):$(stat -Lc %i "$f" 2>/dev/null) ";; esac; done; }
newfd()   { local now="$1" before="$2" f; for f in $now; do case " $before " in *" $f "*) ;; *) return 0 ;; esac; done; return 1; }

LX=656; LY=$(python3 -c "print(int(572.5 + 15*$ROW))")
if [ "$DECK" = 2 ]; then DX=1250; else DX=400; fi
DY=290

# Clear rekordbox's startup dialogs first. The update manager and the INFO
# panel sit on top of the library, so a drag aimed at a track lands on a
# dialog and this script reports "the drag did not load anything" — which
# reads like a coordinate bug and is not one.
"$(dirname "${BASH_SOURCE[0]}")/dismiss.sh" --quiet || {
  echo "   FAULT: a dialog is covering the UI (see research/probes/dismiss.sh). Not"
  echo "          attempting the drag — the result would be meaningless."
  exit 2
}

BEFORE=$(musicfds)
echo "== loadtime: row $ROW -> deck $DECK   (music fds before: ${BEFORE:-none})"
xdotool windowactivate --sync "$W"; sleep 1
xdotool mousemove $LX $LY; sleep 0.5; xdotool click 1; sleep 0.8
xdotool mousedown 1; sleep 0.6
for i in $(seq 1 20); do
  xdotool mousemove $(( LX - (LX-DX)*i/20 )) $(( LY - (LY-DY)*i/20 )); sleep 0.12
done
sleep 0.3; xdotool mouseup 1
T0=$(date +%s.%N)

for i in $(seq 1 150); do
  sleep 0.2
  if newfd "$(musicfds)" "$BEFORE"; then
    python3 -c "print(f'   the file was opened after {$(date +%s.%N)-$T0:.1f} s')"
    exit 0
  fi
done
echo "   NOT OPENED within 30 s — either the drag missed, or the load is worse"
echo "   than this window. Check the deck before reading this as a load time."
exit 1
