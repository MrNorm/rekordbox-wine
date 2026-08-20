#!/usr/bin/env bash
# snddev — WHICH sound devices does rekordbox actually open, and what does that
#          cost the desktop?
#
# WHY THIS EXISTS. T09 established that one direct `hw:` open can delete a
# device from PipeWire for the rest of the session. Whether that matters to
# rekordbox depends entirely on a question nobody has asked yet: when the PC
# MASTER OUT stream is running, does Wine open PipeWire's cooperative `default`
# PCM, or does it grab the laptop's `hw:0` out from under the desktop?
#
# rekordbox's settings file contains BOTH endpoints —
#   "Speakers (Out: default)"            -> cooperative, goes through PipeWire
#   "Speakers (Out: sof-hda-dsp - )"     -> the raw card, exclusive, a fight
# — and which one is selected has never been recorded in any run manifest.
#
# WHAT IT MEASURES. Every 500 ms, read-only:
#   * every /dev/snd/* fd held by every process in the prefix, by device node
#   * the ALSA state of card 0's and card 1's playback substreams
#   * how many real sinks PipeWire still has  (the desktop's health)
# and afterwards, the journal lines PipeWire and WirePlumber emitted meanwhile.
#
# It prints a timeline of OPEN and CLOSE events rather than a wall of samples,
# because the question is "what happened and when", and a 15.8 s cycle is only
# visible as events.
#
# It launches nothing by itself: start rekordbox however you normally do, then
# run this. Use --launch to have it start rekordbox first (plain launch, the
# same environment authprobe.sh uses).
#
# Usage: bin/snddev.sh [seconds] [--launch]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
PREFIX="${RBW_PREFIX:-$REPO/prefixes/rb7}"
EXE="$("$(dirname "${BASH_SOURCE[0]}")/rbexe.sh")"
SECS="${1:-60}"; [ "$SECS" = "--launch" ] && SECS=60
LAUNCH=0; for a in "$@"; do [ "$a" = "--launch" ] && LAUNCH=1; done
OUT="runs/SNDDEV"; mkdir -p "$OUT"
STAMP=$(date +%Y%m%dT%H%M%S)
LOG="$OUT/$STAMP.log"

say() { echo "$*" | tee -a "$LOG"; }

sinks() { pactl list short sinks 2>/dev/null | grep -vc auto_null; }
substates() {
  # every playback substream on both cards, as card:pcm=state
  for f in /proc/asound/card*/pcm*p/sub0/status; do
    local c p s
    c=$(echo "$f" | sed 's|.*/card\([0-9]*\)/pcm\([0-9]*\)p.*|\1:\2|')
    s=$(awk '/^state:/{print $2; f=1} END{if(!f) print "closed"}' "$f" 2>/dev/null)
    [ "$s" != "closed" ] && printf '%s=%s ' "$c" "$s"
  done
}
# Every /dev/snd node held by anything in this prefix. Scoped by WINEPREFIX in
# the process environment, the same way rbclean.sh scopes its kills -- matching
# on the string "wine" alone would sweep in unrelated processes.
sndfds() {
  local pid env out=""
  for pid in $(pgrep -u "$USER" . 2>/dev/null); do
    [ -r "/proc/$pid/environ" ] || continue
    grep -qz "WINEPREFIX=$PREFIX" "/proc/$pid/environ" 2>/dev/null || continue
    for l in $(ls -l "/proc/$pid/fd" 2>/dev/null | awk '/\/dev\/snd\//{print $NF}'); do
      out="$out $l"
    done
  done
  echo "$out" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '
}

say "== snddev $STAMP  (${SECS}s) =="
say "  prefix : $PREFIX"
say "  sinks before : $(sinks) real sink(s)"
say "  default sink : $(pactl get-default-sink 2>/dev/null)"

CURSOR=$(journalctl --user -n0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')

if [ "$LAUNCH" = 1 ]; then
  "$REPO/bin/rbclean.sh" --quiet >/dev/null 2>&1
  say "  launching rekordbox (plain launch, dxgi=n)"
  ( cd "$REPO" && setsid env WINEPREFIX="$PREFIX" WINEDLLOVERRIDES=dxgi=n \
      wine "$EXE" > "$OUT/$STAMP-wine.log" 2>&1 & )
fi

say
say "  t      event"
PREV=""
T0=$(date +%s.%N)
N=$(python3 -c "print(int($SECS*2))")
for i in $(seq 1 "$N"); do
  sleep 0.5
  NOW=$(sndfds)
  if [ "$NOW" != "$PREV" ]; then
    T=$(python3 -c "print(f'{$(date +%s.%N)-$T0:6.1f}')")
    for d in $NOW;  do case " $PREV " in *" $d "*) ;; *) say "  $T  OPEN   $d" ;; esac; done
    for d in $PREV; do case " $NOW "  in *" $d "*) ;; *) say "  $T  CLOSE  $d" ;; esac; done
    ST=$(substates); [ -n "$ST" ] && say "  $T         alsa: $ST"
    PREV="$NOW"
  fi
done

say
say "  sinks after : $(sinks) real sink(s)   default: $(pactl get-default-sink 2>/dev/null)"
say
say "  what PipeWire and WirePlumber said meanwhile:"
journalctl --user --after-cursor "$CURSOR" --no-pager 2>/dev/null \
  | grep -E 'spa.alsa|pw.node|alsa.lua' | sed 's/^/    /' | tee -a "$LOG" | tail -15

EB=$(journalctl --user --after-cursor "$CURSOR" --no-pager 2>/dev/null | grep -c 'Device or resource busy')
say
say "== RESULT =="
say "  EBUSY lines : $EB"
say "  log: $LOG"
