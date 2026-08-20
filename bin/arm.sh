#!/usr/bin/env bash
# arm — run ONE clean experimental arm end to end, unattended.
#
# WHY. Every audio arm in this project is the same six steps, and every time
# one of them is skipped the result is void: the settings file must be edited
# with rekordbox CLOSED (it rewrites it every 15 s), the prefix must be clean
# (leaked wineservers lose ntsync), the deck must actually be PLAYING before a
# rate is believed, and the arm must record which settings it actually ran with
# rather than which ones were asked for.
#
# Usage: bin/arm.sh <label> [KEY=VAL ...]
# Leaves rekordbox RUNNING so a profiler can be attached to the same instance.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LABEL="${1:?label}"; shift
OUT="runs/ARM/$(date +%Y%m%dT%H%M%S)-$LABEL"; mkdir -p "$OUT"
say() { echo "$*" | tee -a "$OUT/log"; }

say "== arm $LABEL =="
./bin/rbclean.sh --force >>"$OUT/log" 2>&1
for i in $(seq 1 30); do pgrep -x rekordbox.exe >/dev/null || break; sleep 1; done
for kv in "$@"; do ./bin/rbset.sh "${kv%%=*}" "${kv#*=}" 2>&1 | tee -a "$OUT/log"; done

S=$(ls prefixes/rb7/drive_c/users/*/AppData/Roaming/Pioneer/rekordbox6/rekordbox3.settings)
grep -o 'name="\(PCSpeakerSelected_23\|WasapiExclusive\|WasapiPolling\|WasapiTimeoutCount\|WasapiThresholdCount\|WasapiBufferThreshold\|AudioBufferSize\|MasterOutMode\)" val="[^"]*"' "$S" > "$OUT/settings-as-run.txt"
say "--- settings as run ---"; cat "$OUT/settings-as-run.txt" | tee -a "$OUT/log" >/dev/null; cat "$OUT/settings-as-run.txt"

setsid nohup ./bin/rekordbox >"$OUT/launch.log" 2>&1 </dev/null &
for i in $(seq 1 90); do
  W=$(xdotool search --name '^rekordbox$' 2>/dev/null | head -1)
  [ -n "$W" ] && break
  sleep 2
done
[ -z "${W:-}" ] && { say "FAULT: no window after 180 s"; exit 2; }
sleep 40   # let the library and audio engine settle before touching the UI
./bin/loadplay.sh 2>&1 | tee -a "$OUT/log"

# The deck readout is the only oracle that works in BOTH arms; 25 s so that
# even a 0.04x deck moves a visible tenth of a second.
./bin/deckadvancing.sh 25 2>&1 | tee -a "$OUT/log"

./bin/enginerate.sh 60 2>&1 | tail -12 | tee -a "$OUT/log"
./bin/teardownmark.py 0 40 "$OUT/teardowns.txt" >/dev/null 2>&1
N=$(grep -c 'closed' "$OUT/teardowns.txt" 2>/dev/null || echo 0)
say "teardowns (stream closes) in 40 s: $N"
say "evidence: $OUT"
