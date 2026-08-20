#!/usr/bin/env bash
# soak — is a running rekordbox playing at real time, and does its audio survive?
#
# Two numbers, one window, no assumptions:
#   deck rate      from bin/deckrate.sh (the deck's own clock -- enginerate's
#                  file-offset oracle goes VOID once rekordbox has read the whole
#                  track into memory, which it does in polling mode)
#   teardowns      DDJ substream closes, from bin/teardownmark.py
#
# A gold configuration is 1.00 and 0. Usage: bin/soak.sh [seconds] [library row]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SECS="${1:-120}"; ROW="${2:-3}"
OUT="runs/SOAK"; mkdir -p "$OUT"
ID=$(date +%Y%m%dT%H%M%S); D="$OUT/$ID"; mkdir -p "$D"
pgrep -f 'rekordbox\.exe' >/dev/null || { echo "FAULT: rekordbox is not running"; exit 2; }
./bin/loadplay.sh "$ROW" 2>&1 | tee "$D/loadplay.log" | tail -1
./bin/teardownmark.py 0 $((SECS+15)) "$D/teardowns.txt" >/dev/null 2>&1 &
MK=$!
./bin/deckrate.sh "$SECS" 2>&1 | tee "$D/deckrate.log" | tail -2
wait $MK
N=$(grep -c closed "$D/teardowns.txt")
echo "   teardowns in $((SECS+15)) s: $N"
grep -o 'name="\(AudioBufferSize\|WasapiPolling\|WasapiExclusive\|PCSpeakerSelected_23\)" val="[^"]*"' \
  prefixes/rb7/drive_c/users/*/AppData/Roaming/Pioneer/rekordbox6/rekordbox3.settings | tee "$D/settings.txt"
echo "   evidence: $D"
