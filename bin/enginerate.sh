#!/usr/bin/env bash
# enginerate — how fast is rekordbox's playback engine ACTUALLY running?
#
# WHY THIS EXISTS. Everything measured about the PC MASTER OUT fault so far has
# been measured at the device: silence at the wire, silence in the WASAPI
# buffers, streams rebuilt every 15.8 s. All of it described what the engine
# FAILED to emit. This measures the engine itself.
#
# THE INSIGHT. rekordbox keeps the playing track's file open, and the kernel
# tells us exactly how far it has read: /proc/<pid>/fdinfo/<fd> -> pos. A deck
# playing in real time consumes the file at its bitrate. A deck whose engine is
# stalled consumes it slower, in exact proportion. So one integer, sampled
# read-only with no compositor, no OCR and no recording, gives the engine's
# speed as a fraction of real time.
#
#   40034 B/s on a 320 kbit/s file  ->  1.00x, playing normally
#    2000 B/s on the same file      ->  0.05x, the engine is stalled 95% of the time
#
# It also samples the DDJ substream in the same loop, so the engine rate and the
# stream-rebuild cycle share one clock.
#
# WHY IT IS TRUSTWORTHY. The expected rate comes from ffprobe reading the file's
# own bitrate, not from an assumption. The fd is found by name, so it cannot
# silently measure the wrong file -- a fault this project has already paid for
# (card0/pcm0p was PipeWire's, not rekordbox's). And a deck that is PAUSED reads
# nothing at all, which is indistinguishable from a stalled engine by this
# measure alone -- so the script REFUSES to report a rate if the position never
# moves, and says "paused or stalled dead" instead of "0.00x".
#
# Usage: bin/enginerate.sh [seconds]        (default 40)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SECS="${1:-40}"
OUT="runs/ENGINERATE"; mkdir -p "$OUT"
STAMP=$(date +%Y%m%dT%H%M%S)
LOG="$OUT/$STAMP.log"
say() { echo "$*" | tee -a "$LOG"; }

PID=$(pgrep -f 'rekordbox\.exe' | head -1)
[ -z "$PID" ] && { say "FAULT: rekordbox is not running"; exit 2; }

# The audio file the deck is playing: an fd on a media file outside the prefix.
# (Files inside the prefix are the app's own click/sample assets.)
FD=""; FILE=""
for f in /proc/$PID/fd/*; do
  t=$(readlink "$f" 2>/dev/null) || continue
  case "$t" in
    */prefixes/*) continue ;;
    *.mp3|*.MP3|*.wav|*.WAV|*.aiff|*.aif|*.flac|*.m4a) FD=$(basename "$f"); FILE="$t" ;;
  esac
done
[ -z "$FD" ] && { say "FAULT: no track file is open — load a track and press play first."; exit 2; }

SIZE=$(stat -c %s "$FILE")
DUR=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$FILE" 2>/dev/null)
EXPECT=$(python3 -c "print(f'{$SIZE/max(0.001,${DUR:-0}):.0f}')" 2>/dev/null)

DDJ=""
for c in /proc/asound/card*/usbid; do
  [ "$(cat "$c" 2>/dev/null)" = "2b73:0026" ] && DDJ="$(dirname "$c")/pcm0p/sub0/status"
done
dstate() { awk '/^state:/{print $2; f=1} END{if(!f) print "closed"}' "$DDJ" 2>/dev/null; }
pos() { awk '/^pos:/{print $2}' "/proc/$PID/fdinfo/$FD" 2>/dev/null; }

say "== enginerate $STAMP  (${SECS}s) =="
say "   pid $PID  fd $FD"
say "   track    : $FILE"
say "   duration : ${DUR}s   size $SIZE B   -> real-time rate ${EXPECT} B/s"
say "   ddj      : ${DDJ:-none}   state $(dstate)"
say ""
say "   t       pos          B/s      x realtime   ddj"

P0=$(pos); PP=$P0; T0=$(date +%s.%N); TP=$T0
TRANS=0; PREV=$(dstate)
N=$(python3 -c "print(int($SECS))")
for i in $(seq 1 "$N"); do
  sleep 1
  NOW=$(date +%s.%N); P=$(pos); S=$(dstate)
  [ -z "$P" ] && { say "   track closed mid-run — the deck was unloaded. Void."; exit 2; }
  [ "$S" != "$PREV" ] && { TRANS=$((TRANS+1)); PREV=$S; }
  python3 - "$NOW" "$TP" "$P" "$PP" "$EXPECT" "$S" "$T0" <<'EOF' | tee -a "$LOG"
import sys
now, tp, p, pp, exp, st, t0 = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5]), sys.argv[6], float(sys.argv[7])
rate = (p - pp) / max(1e-6, now - tp)
print(f"  {now-t0:6.1f}  {p:10d}  {rate:9.0f}   {rate/exp if exp else 0:9.2f}x   {st}")
EOF
  PP=$P; TP=$NOW
done

P1=$(pos); T1=$(date +%s.%N)
# A track that REACHES THE END during the window reads at full speed and then
# stops, which averages out to a fraction of real time and reads exactly like a
# stalled engine. Refuse it rather than reporting a rate. (Caught the first time
# it happened: a 0.19x that was simply the last 307 KB of a 2:08 track.)
if [ "$P1" = "$SIZE" ]; then
  say ""
  say "== VOID =="
  say "   the track reached its end during the window (pos = file size)."
  say "   A finished track and a stalled engine are the same shape here."
  say "   Reload the track and re-run."
  exit 2
fi
say ""
say "== RESULT =="
python3 - "$P0" "$P1" "$T0" "$T1" "$EXPECT" "$TRANS" <<'EOF' | tee -a "$LOG"
import sys
p0, p1, t0, t1, exp, trans = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5]), int(sys.argv[6])
d, dt = p1 - p0, t1 - t0
rate = d / dt
print(f"   read {d} B in {dt:.1f} s = {rate:.0f} B/s")
print(f"   real-time rate for this file = {exp:.0f} B/s")
if d == 0:
    print("   THE FILE POSITION NEVER MOVED.")
    print("   That is a PAUSED deck or an engine stalled dead — this measure")
    print("   cannot tell those apart. Check the deck is playing and re-run.")
else:
    x = rate / exp if exp else 0
    print(f"   ENGINE RATE = {x:.2f}x real time")
    if x > 0.9:   print("   -> the engine is running normally.")
    elif x > 0.5: print("   -> the engine is behind real time but producing.")
    else:         print(f"   -> THE ENGINE IS STALLED for {100*(1-x):.0f}% of wall time.")
print(f"   DDJ substream state changes during the run: {trans}")
EOF
say ""
say "   log: $LOG"
