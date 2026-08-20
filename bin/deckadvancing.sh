#!/usr/bin/env bash
# deckadvancing — is deck 1's playhead moving? Answers when the file offset cannot.
#
# WHY. Two signals can say "the deck is playing" and both have blind spots:
#
#   file offset (/proc/<pid>/fdinfo)  exact while the file is being read, but it
#                                     freezes at EOF while the deck plays on from
#                                     memory, AND in the PC MASTER OUT fault it
#                                     only advances once per 15.8 s cycle — so a
#                                     4-second check reports "not playing" about
#                                     a deck that is playing (badly).
#   the deck's own time readout       true whenever the deck exists, at the cost
#                                     of two screenshots.
#
# This is the second one. Exit 0 = advancing, 1 = frozen, 2 = could not read.
# A crop that fails hashes to a constant and would compare equal for ever, i.e.
# "frozen", so that case is reported separately instead of being acted on.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TIMEBOX="220x30+590+248"      # deck 1 elapsed/remaining, X coords, spectacle -f
GAP="${1:-2.5}"               # seconds between the two looks
# RAISE THE APP FIRST. spectacle -f captures the whole screen, so if anything
# else is in front — a terminal, an editor — this measures ITS pixels and
# reports a frozen deck. That happened: a run reported "0 of 27 samples
# advanced, THE ENGINE IS STALLED" while it was photographing a shell prompt.
# A probe that measures the wrong object is the oldest fault in this project.
RB=$(xdotool search --name '^rekordbox$' | head -1)
[ -n "$RB" ] || { echo "deck: rekordbox has no window"; exit 2; }
xdotool windowactivate --sync "$RB" 2>/dev/null; sleep 0.6
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

hash_now() {
  local f="$TMP/t.png" h
  rm -f "$f"
  timeout 25 spectacle -f -b -n -o "$f" >/dev/null 2>&1
  [ -s "$f" ] || return 1
  h=$(magick "$f" -crop "$TIMEBOX" +repage -colorspace Gray -depth 8 txt:- 2>/dev/null | md5sum | cut -c1-12)
  [ -n "$h" ] || return 1
  echo "$h"
}

a=$(hash_now) || { echo "deck: UNREADABLE"; exit 2; }
sleep "$GAP"
b=$(hash_now) || { echo "deck: UNREADABLE"; exit 2; }
if [ "$a" != "$b" ]; then echo "deck: ADVANCING"; exit 0; fi
echo "deck: FROZEN"; exit 1
