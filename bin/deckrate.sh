#!/usr/bin/env bash
# deckrate — engine speed from the deck's own clock, when the file offset cannot.
#
# bin/enginerate.sh reads the track file's offset and is exact — until the
# application reads the whole file into memory, which it does within about
# thirty seconds in polling mode. Then the offset freezes at EOF while the deck
# plays on, and the oracle correctly refuses to answer (VOID). This answers
# instead, from the deck's elapsed-time readout.
#
# HOW. The readout advances in tenths of a second. Sample its pixels twice a
# second: at real time every sample differs from the last; at 0.05x almost none
# do. The fraction that changed is the engine speed, and it needs no OCR — only
# whether the pixels moved.
#
# Resolution note: this saturates at 1.0 and cannot distinguish 1.0x from 1.2x,
# and below about 0.05x it reports zero changes rather than a small number. It
# is a sanity check on the shape of the fault, not a precision instrument; use
# enginerate when the file offset is still moving.
#
# Usage: bin/deckrate.sh [seconds]     default 30
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SECS="${1:-30}"
TIMEBOX="220x30+590+248"
# RAISE THE APP FIRST. spectacle -f captures the whole screen, so if anything
# else is in front — a terminal, an editor — this measures ITS pixels and
# reports a frozen deck. That happened: a run reported "0 of 27 samples
# advanced, THE ENGINE IS STALLED" while it was photographing a shell prompt.
# A probe that measures the wrong object is the oldest fault in this project.
RB=$(xdotool search --name '^rekordbox$' | head -1)
[ -n "$RB" ] || { echo "deck: rekordbox has no window"; exit 2; }
xdotool windowactivate --sync "$RB" 2>/dev/null; sleep 0.6
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

h() {
  local f="$TMP/t.png"
  rm -f "$f"
  timeout 25 spectacle -f -b -n -o "$f" >/dev/null 2>&1
  [ -s "$f" ] || { echo FAIL; return; }
  magick "$f" -crop "$TIMEBOX" +repage -colorspace Gray -depth 8 txt:- 2>/dev/null | md5sum | cut -c1-12
}

n=0; changed=0; fails=0; prev=""
end=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$end" ]; do
  cur=$(h)
  if [ "$cur" = FAIL ]; then fails=$((fails+1)); else
    if [ -n "$prev" ]; then
      n=$((n+1)); [ "$cur" != "$prev" ] && changed=$((changed+1))
    fi
    prev="$cur"
  fi
  sleep 0.5
done

if [ "$n" -lt 5 ]; then
  echo "deckrate: only $n usable samples ($fails capture failures) — no verdict"
  exit 2
fi
python3 - "$changed" "$n" <<'PY'
import sys
c, n = int(sys.argv[1]), int(sys.argv[2])
r = c / n
print(f"   deck advanced in {c} of {n} samples = {r:.2f} of real time")
if r > 0.9:   print("   -> the engine is keeping real time")
elif r > 0.4: print("   -> the engine is behind but producing")
else:         print(f"   -> THE ENGINE IS STALLED ({100*(1-r):.0f}% of samples frozen)")
PY
