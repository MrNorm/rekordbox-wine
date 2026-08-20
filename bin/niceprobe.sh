#!/usr/bin/env bash
# niceprobe — does lowering the audio threads' nice level reduce stream teardowns?
#
# Matched protocol for both arms, because the earlier numbers were taken with
# different window lengths and are not comparable: arm at a given buffer, play,
# optionally renice the busiest threads, then count DDJ substream closes over a
# fixed window, reloading the track when it runs out (the demo track is 2:52 and
# the window is longer than that).
#
# Usage: bin/niceprobe.sh <label> <buffer> <nice|none> [seconds]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
LABEL="${1:?label}"; BUF="${2:?buffer}"; NICE="${3:?nice level or 'none'}"; SECS="${4:-330}"
D="runs/T12-nice/$LABEL"; mkdir -p "$D"

./bin/arm.sh "nice-$LABEL" WasapiPolling=1 AudioBufferSize="$BUF" PCSpeakerSelected_23=1 >"$D/arm.log" 2>&1
P=$(pgrep -x rekordbox.exe | head -1)
[ -n "$P" ] || { echo "FAULT: rekordbox not running"; exit 2; }
./bin/loadplay.sh 3 >"$D/load.log" 2>&1

# busiest threads = the audio ones; sample over 3 s
declare -A a
for t in /proc/$P/task/*; do a[$(basename $t)]=$(awk '{print $14+$15}' "$t/stat" 2>/dev/null); done
sleep 3
for t in /proc/$P/task/*; do
  tid=$(basename $t); n=$(awk '{print $14+$15}' "$t/stat" 2>/dev/null)
  d=$(( ${n:-0} - ${a[$tid]:-0} )); [ "$d" -gt 2 ] && echo "$d $tid"
done | sort -rn | head -3 > "$D/busy.txt"
echo "busiest threads:"; sed 's/^/  /' "$D/busy.txt"

if [ "$NICE" != none ]; then
  while read -r _ tid; do
    sudo renice -n "$NICE" -p "$tid" >/dev/null 2>&1 \
      && echo "  tid $tid -> nice $(awk '{print $19}' /proc/$tid/stat 2>/dev/null)"
  done < "$D/busy.txt"
fi

./bin/teardownmark.py 0 "$SECS" "$D/teardowns.txt" >/dev/null 2>&1 &
MK=$!
# keep audio flowing for the whole window
end=$((SECONDS + SECS - 20))
while [ $SECONDS -lt $end ]; do
  sleep 30
  kill -0 "$P" 2>/dev/null || { echo "  *** PROCESS DIED at $SECONDS s ***"; break; }
  ./bin/deckadvancing.sh >/dev/null 2>&1 || ./bin/loadplay.sh 3 >>"$D/load.log" 2>&1
done
wait $MK
alive=$(kill -0 "$P" 2>/dev/null && echo yes || echo NO)
n=$(grep -c closed "$D/teardowns.txt" 2>/dev/null)
echo "RESULT $LABEL: buffer=$BUF nice=$NICE window=${SECS}s teardowns=$n alive=$alive"
echo "  evidence: $D"
