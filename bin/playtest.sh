#!/usr/bin/env bash
# playtest — does a track actually PLAY, and if it stops, when and why?
#
# WHY THIS EXISTS. Every audio check so far stops at "the Sample Rate dropdown
# populates". That says the device negotiated; it says nothing about sustained
# playback, which is the thing that keeps failing. Asking a human to press play
# and describe what happened is not a measurement and cannot be run in a loop.
#
# WHAT IT MEASURES. /proc/asound/cardN/pcm0p/sub0/status exposes two counters:
#
#   appl_ptr   frames the APPLICATION has written into the ALSA ring
#   hw_ptr     frames the HARDWARE has consumed out of it
#
# Those separate the two failure modes that look identical from the UI:
#
#   appl_ptr advancing, hw_ptr advancing   -> audio genuinely flowing
#   appl_ptr STALLED,   hw_ptr advancing   -> the CLIENT stopped feeding.
#                                             Wine is not waking rekordbox.
#   appl_ptr advancing, hw_ptr stalled     -> the hardware stopped consuming
#   both stalled, state XRUN               -> the stream collapsed
#
# The first sample after pressing play already showed appl_ptr=1024 and then
# nothing: rekordbox wrote exactly ONE period and was never signalled again.
#
# Also samples the controller's MIDI Tx counter, because a rebuild loop shows up
# there as steadily climbing bytes with nothing being touched -- that is what
# the user sees as an LED flashing.
#
# IMPORTANT: an idle open stream reports XRUN by design (start_threshold 1,
# stop_threshold 4096), so `state:` alone proves nothing. The pointer deltas are
# the evidence.
#
# Usage: bin/playtest.sh [seconds]        (default 20)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SECS="${1:-20}"
OUT="runs/PLAYTEST"; mkdir -p "$OUT"
STAMP=$(date +%Y%m%dT%H%M%S)

card() { for c in /proc/asound/card*/usbid; do
           [ "$(cat "$c" 2>/dev/null)" = "2b73:0026" ] && dirname "$c" && return; done; }
D=$(card); [ -z "$D" ] && { echo "FAULT: DDJ-400 not found in /proc/asound"; exit 2; }
ST="$D/pcm0p/sub0/status"

W=$(xdotool search --name '^rekordbox$' | head -1)
[ -z "$W" ] && { echo "FAULT: rekordbox not running"; exit 2; }
eval "$(xdotool getwindowgeometry --shell "$W" | tr -d '\r')"
WX=$X; WY=$Y; WW=$WIDTH; WH=$HEIGHT

field() { grep -E "^$1" "$ST" 2>/dev/null | awk '{print $NF}'; }
state() { head -1 "$ST" 2>/dev/null; }
tx()    { awk '/Tx bytes/{print $NF}' "$D/midi0" 2>/dev/null; }
rx()    { awk '/Rx bytes/{print $NF}' "$D/midi0" 2>/dev/null; }

echo "== playback test  $STAMP =="
echo "   window ${WW}x${WH} at +$WX+$WY   pcm $ST"
echo "   pre-play state: $(state)"

# Load a track first. Every restart empties the decks, so pressing play on an
# empty deck measures nothing -- an earlier run of this script reported
# "no audio was written at all" for exactly that reason, which is a harness
# fault masquerading as a finding. Double-click the first library row.
# A double-click only SELECTS the row -- verified by screenshot, both decks still
# read "Not Loaded" afterwards. rekordbox loads a deck by drag and drop, so drag
# the row onto deck 1's track bar.
LX=$(python3 -c "print(int($WX + 0.367*$WW))")
LY=$(python3 -c "print(int($WY + 0.597*$WH))")
DX=$(python3 -c "print(int($WX + 0.217*$WW))")
DY=$(python3 -c "print(int($WY + 0.238*$WH))")
echo "   loading a track: drag library row ($LX,$LY) -> deck 1 ($DX,$DY)"
xdotool windowactivate --sync "$W"; sleep 1
xdotool mousemove "$LX" "$LY"; sleep 0.4
xdotool mousedown 1; sleep 0.4
# move in steps: a single jump is often not seen as a drag
for f in 0.25 0.5 0.75 1.0; do
  mx=$(python3 -c "print(int($LX + ($DX-$LX)*$f))")
  my=$(python3 -c "print(int($LY + ($DY-$LY)*$f))")
  xdotool mousemove "$mx" "$my"; sleep 0.25
done
sleep 0.4; xdotool mouseup 1; sleep 5

# Deck 1 play button. Calibrated 2026-08-14 against runs/CLEAN-main.png: the
# green play circle sits at window-relative (713,420) in a 1920x1006 window.
PX=$(python3 -c "print(int($WX + 0.3714*$WW))")
PY=$(python3 -c "print(int($WY + 0.4175*$WH))")
echo "   clicking deck 1 play at screen ($PX,$PY)"
xdotool windowactivate --sync "$W"; sleep 1
xdotool mousemove "$PX" "$PY"; sleep 0.3; xdotool click 1

# THE AUTHORITATIVE CHECK. appl_ptr advances whether rekordbox is playing a
# track or writing silence into an idle stream, so it CANNOT tell playback from
# a paused deck -- an earlier version of this script reported "playback
# SUSTAINED 120/120" while the deck sat frozen at 00:00.6. The deck's elapsed
# time readout is the only honest signal. Hash it: if the pixels change, the
# playhead moved.
# Elapsed-time readout, verified against runs/DECKFULL.png: "00:00.0" sits at
# capture x=727..765, y=303..318. Box padded slightly.
TIMEBOX="120x24+700+298"
EMPTY_MD5=d41d8cd98f          # md5 of NOTHING -- see the guard below
timehash() {
  local f="$OUT/$STAMP-t.png" h
  rm -f "$f"
  timeout 25 spectacle -a -b -n -o "$f" >/dev/null 2>&1
  if [ ! -s "$f" ]; then echo "CAPTURE_FAILED"; return; fi
  h=$(magick "$f" -crop "$TIMEBOX" +repage -colorspace Gray -depth 8 txt:- 2>/dev/null | md5sum | cut -c1-10)
  # An empty crop hashes to the md5 of the empty string and silently compares
  # unequal to everything, which reads as "the deck is advancing". That exact
  # false pass happened. Refuse it.
  if [ -z "$h" ] || [ "$h" = "$EMPTY_MD5" ]; then echo "CROP_FAILED"; return; fi
  echo "$h"
}
xdotool windowactivate --sync "$W" >/dev/null 2>&1; sleep 1
TH0=$(timehash)
sleep 4
TH1=$(timehash)
case "$TH0$TH1" in
  *CAPTURE_FAILED*|*CROP_FAILED*) DECK="UNKNOWN" ;;
  *) [ "$TH0" != "$TH1" ] && DECK="ADVANCING" || DECK="FROZEN" ;;
esac
echo "   deck time readout: $DECK  ($TH0 -> $TH1)"

LOG="$OUT/$STAMP.tsv"
printf '# t\tstate\tappl_ptr\thw_ptr\td_appl\td_hw\tTx\td_Tx\tRx\n' > "$LOG"
pa=$(field appl_ptr); ph=$(field hw_ptr); ptx=$(tx)
pa=${pa:-0}; ph=${ph:-0}; ptx=${ptx:-0}
stall=0; flow=0

for i in $(seq 1 $((SECS*2))); do
  sleep 0.5
  a=$(field appl_ptr); h=$(field hw_ptr); t=$(tx); r=$(rx)
  a=${a:-0}; h=${h:-0}; t=${t:-0}; r=${r:-0}
  da=$((a-pa)); dh=$((h-ph)); dt=$((t-ptx))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(python3 -c "print(f'{$i*0.5:.1f}')")" "$(state)" "$a" "$h" "$da" "$dh" "$t" "$dt" "$r" >> "$LOG"
  [ "$da" -gt 0 ] && flow=$((flow+1)) || stall=$((stall+1))
  pa=$a; ph=$h; ptx=$t
done

echo
echo "== RESULT =="
awk -F'\t' 'NR>1{printf "  t=%-5s %-16s appl+%-7s hw+%-7s Tx+%-5s\n", $1, $2, $5, $6, $8}' "$LOG" | head -20
echo
echo "  samples where the app wrote data : $flow"
echo "  samples where it wrote nothing   : $stall"
TXTOT=$(awk -F'\t' 'NR>1{s+=$8} END{print s+0}' "$LOG")
RXD=$(awk -F'\t' 'NR>1{last=$9} NR==2{first=$9} END{print last-first}' "$LOG")
echo "  total MIDI Tx during test        : $TXTOT bytes"
echo "  total MIDI Rx during test        : $RXD bytes"
echo "  full log: $LOG"
echo
if [ "$flow" -eq 0 ]; then
  echo "  VERDICT: no audio was written at all. Either play did not engage"
  echo "           (check the click landed) or the client is never signalled."
elif [ "$stall" -gt "$flow" ]; then
  echo "  VERDICT: playback STALLS. The app fed audio in only $flow of"
  echo "           $((flow+stall)) samples -- it is being starved, not stopping"
  echo "           by choice. A climbing Tx alongside means rekordbox is"
  echo "           rebuilding the stream, which is the flashing LED."
else
  if [ "$DECK" = "UNKNOWN" ]; then
    echo "  HARNESS FAULT: could not read the deck time readout, so whether a"
    echo "                 track is playing is UNKNOWN. Do not treat the audio"
    echo "                 counters below as evidence of playback."
  elif [ "$DECK" = "FROZEN" ]; then
    echo "  VERDICT: MISLEADING PASS. The app fed audio in $flow of $((flow+stall))"
    echo "           samples, but the deck time readout did NOT advance -- so it is"
    echo "           writing SILENCE into an idle stream, not playing a track."
    echo "           The audio path is healthy; playback is not running."
  else
    echo "  VERDICT: playback SUSTAINED -- the app fed audio in $flow of"
    echo "           $((flow+stall)) samples AND the deck time readout advanced."
  fi
fi
