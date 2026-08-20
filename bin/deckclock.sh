#!/usr/bin/env bash
# deckclock — engine speed as a RATIO OF TWO CLOCKS, not a sampling frequency.
#
# WHY THIS EXISTS. bin/deckrate.sh asks "did the readout pixels change since the
# last screenshot", which is a sampling question: a full-screen grab that lands
# late, or twice inside the same tenth of a second, scores a miss the engine
# never made. On a configuration measured healthy by every other instrument
# (0 teardowns, continuous audio at the wire) deckrate has returned 0.74, 0.84,
# 0.87, 0.91, 0.95, 0.96, 0.97 and 1.00 -- so a single sub-1.0 reading from it
# is not evidence of anything. It also saturates at 1.0 and cannot see 1.2x.
#
# This reads the deck's elapsed-time readout with OCR at the start and the end
# of a window and divides by wall clock. Two reads, so jitter in either costs
# one tenth of a second across the whole window rather than one sample in a
# hundred, and it can report above 1.0.
#
# Usage: bin/deckclock.sh [seconds]     default 60
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SECS="${1:-60}"
TIMEBOX="260x26+595+247"   # both deck-1 clocks: remaining, then elapsed

RB=$(xdotool search --name '^rekordbox$' | head -1)
[ -n "$RB" ] || { echo "deckclock: rekordbox has no window"; exit 2; }
# Raise it first: spectacle -f grabs the whole screen, so anything in front is
# what gets measured. A run once reported a stalled engine while photographing a
# shell prompt.
xdotool windowactivate --sync "$RB" 2>/dev/null; sleep 0.6
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Returns the readout as seconds, or nothing if it could not be read.
read_deck() {
  local f="$TMP/g.png"; rm -f "$f"
  timeout 25 spectacle -f -b -n -o "$f" >/dev/null 2>&1
  [ -s "$f" ] || return 1
  local txt
  # A local adaptive threshold, not a global one: the readout is light text on a
  # near-black panel, and every fixed threshold tried here binarised it to a
  # solid block that tesseract read as nothing at all.
  txt=$(magick "$f" -crop "$TIMEBOX" +repage -colorspace Gray -resize 500% \
          -negate -lat 25x25-10% png:- 2>/dev/null \
        | tesseract stdin stdout --psm 7 2>/dev/null)
  # The panel shows TWO clocks: remaining first, with a leading minus, then
  # elapsed. Taking the first match reads the countdown, whose delta is negative
  # for a healthy deck -- so take the elapsed one, and fall back to the only
  # match when a skin shows just one.
  local times; times=$(echo "$txt" | grep -oE '[0-9]+:[0-9]{2}\.[0-9]')
  local n; n=$(echo "$times" | grep -c .)
  { [ "$n" -ge 2 ] && echo "$times" | sed -n 2p || echo "$times" | sed -n 1p; } \
    | awk -F'[:.]' 'NF>=3 { print $1*60 + $2 + $3/10 }'
}

t0_wall=$(date +%s.%N); d0=$(read_deck)
[ -n "${d0:-}" ] || { echo "deckclock: could not read the deck clock (is a track loaded?)"; exit 3; }
# Read the midpoint too. A track that ENDS inside the window leaves the clock
# parked at its length, and two-point arithmetic then reports a fraction of real
# time that looks exactly like a struggling engine -- measured: a healthy 256
# frame arm reported 0.686x purely because a 2:52 track ran out at 172 s of a
# 240 s window. Comparing the halves catches it.
sleep "$(awk -v s="$SECS" 'BEGIN{print s/2}')"
tm_wall=$(date +%s.%N); dm=$(read_deck)
sleep "$(awk -v s="$SECS" 'BEGIN{print s/2}')"
t1_wall=$(date +%s.%N); d1=$(read_deck)
[ -n "${d1:-}" ] || { echo "deckclock: could not read the deck clock at the end"; exit 3; }

if [ -n "${dm:-}" ]; then
  awk -v d0="$d0" -v dm="$dm" -v d1="$d1" 'BEGIN{
    first = dm - d0; second = d1 - dm;
    if (first > 1.0 && second < 0.2) {
      printf "deckclock: VOID -- the clock stopped at %.1fs mid-window; the track ended. Use a longer track or a shorter window.\n", d1;
      exit 4
    }
  }' || exit 4
fi

awk -v d0="$d0" -v d1="$d1" -v w0="$t0_wall" -v w1="$t1_wall" 'BEGIN{
  dd = d1 - d0; ww = w1 - w0;
  # The readout wraps at the end of a track and counts down in some skins; a
  # negative delta means the window spanned a reload, not a stalled engine.
  if (dd < 0) { printf "deckclock: VOID -- the readout went backwards (%.1f -> %.1f), the track was reloaded\n", d0, d1; exit 4 }
  printf "deck %.1fs -> %.1fs = %.1fs of audio in %.1fs of wall clock = %.3fx\n", d0, d1, dd, ww, dd/ww;
}'
