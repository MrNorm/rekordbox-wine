#!/usr/bin/env bash
# barrierscope — measure rekordbox's start-up rendezvous directly (T10 phase 34).
#
# rekordbox's per-device audio callback FUN_140fe5de0 does NOTHING until every
# output device has completed max(10, 3000/periodMs) callbacks. That barrier is
# the PC MASTER OUT fault: the DDJ's exclusive stream only gets 43 callbacks a
# second under Wine, so three seconds' worth takes fourteen.
#
# Hardware EXECUTE breakpoints, via perf. No debugger, no patching, no cost:
#   0x140fe5e18  callback entry            (one per device per block)
#   0x140fe5e6a  counter increment         (only while the barrier is closed)
#   0x140fe5ea3  THE BARRIER OPENS         (once per cycle in the fault)
#   0x140fe5fca  the real work begins      (only after the barrier)
#
# The image has no ASLR and loads at 0x140000000, so the addresses are constant
# across launches -- but they are specific to rekordbox 7.2.18.
#
# Usage: bin/barrierscope.sh [seconds]        (default 32)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
SECS="${1:-32}"
OUT="runs/BARRIER"; mkdir -p "$OUT"
ID=$(date +%Y%m%dT%H%M%S); D="$OUT/$ID"; mkdir -p "$D"

PID=$(pgrep -f 'rekordbox\.exe' | head -1)
[ -z "$PID" ] && { echo "FAULT: rekordbox is not running"; exit 2; }

./bin/teardownmark.py 0 $((SECS+6)) "$D/teardowns.txt" >/dev/null 2>&1 &
MK=$!
sudo perf record -k CLOCK_MONOTONIC \
     -e mem:0x140fe5e18:x -e mem:0x140fe5e6a:x -e mem:0x140fe5ea3:x -e mem:0x140fe5fca:x \
     -p "$PID" -o "$D/bar.data" -- sleep "$SECS" 2>&1 | tail -2
wait $MK
sudo perf script -i "$D/bar.data" -F tid,time,event 2>/dev/null > "$D/bar.txt"
sudo chown "$(id -u):$(id -g)" "$D/bar.data" "$D/bar.txt" 2>/dev/null

python3 - "$D" "$SECS" <<'PY'
import sys, re, collections
d, secs = sys.argv[1], float(sys.argv[2])
ev = collections.Counter(); per = collections.defaultdict(collections.Counter)
opens = []; span = [None, None]
for line in open(f"{d}/bar.txt"):
    m = re.match(r'\s*(\d+)\s+(\d+\.\d+):\s+mem:0x([0-9a-f]+):x:', line)
    if not m: continue
    tid, t, a = int(m.group(1)), float(m.group(2)), m.group(3)
    ev[a] += 1; per[tid][a] += 1
    span[0] = t if span[0] is None else min(span[0], t)
    span[1] = t if span[1] is None else max(span[1], t)
    if a == '140fe5ea3': opens.append(t)
names = {'140fe5e18': 'entry', '140fe5e6a': 'counter++',
         '140fe5ea3': 'BARRIER OPENS', '140fe5fca': 'work'}
print(f"\n== barrierscope: {secs:.0f} s ==")
for a, n in sorted(ev.items()):
    print(f"   {names.get(a,a):16s} {n:7d}")
tears = [float(l.split()[0]) for l in open(f"{d}/teardowns.txt")
         if not l.startswith('#') and l.split()[1] == 'RUNNING']
print(f"\n   barrier openings : {len(opens)}")
for i, t in enumerate(opens):
    prev = [x for x in tears if x < t]
    since = f"{t-prev[-1]:6.3f} s after the stream started" if prev else ""
    gap = f"  (+{t-opens[i-1]:6.3f} s)" if i else ""
    print(f"      {t:.3f}{gap}   {since}")
print(f"\n   per-thread callback entries (rate over the whole window):")
for tid, c in sorted(per.items(), key=lambda kv: -kv[1]['140fe5e18']):
    if not c['140fe5e18']: continue
    print(f"      tid {tid:<8} entries {c['140fe5e18']:6d}  = {c['140fe5e18']/secs:6.1f}/s"
          f"   counter++ {c['140fe5e6a']:6d}   work {c['140fe5fca']:6d}")
print(f"\n   evidence: {d}")
PY
