#!/usr/bin/env python3
"""teardownmark — timestamp every PC-MASTER-OUT teardown on CLOCK_MONOTONIC.

WHY. Every instrument that wants to say "what was the code doing 5 s into the
quiet stretch" needs the cycle's phase, and the cheapest unambiguous marker of
the teardown is the DDJ substream disappearing: rekordbox closes the exclusive
stream, so /proc/asound/card<N>/pcm0p/sub0/status stops saying "state: RUNNING"
for ~1 s and then comes back.

Polls at ~500 Hz (one 200-byte read, negligible), prints one line per edge with
a CLOCK_MONOTONIC stamp so it can be aligned with `perf record -k CLOCK_MONOTONIC`
and with research/probes/queueburst.py, which uses the same clock.

Usage: bin/teardownmark.py <card> <seconds> [outfile]
"""
import sys, time, os

card = sys.argv[1] if len(sys.argv) > 1 else "0"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
out  = open(sys.argv[3], "w") if len(sys.argv) > 3 else sys.stdout

path = f"/proc/asound/card{card}/pcm0p/sub0/status"

def state():
    try:
        with open(path) as f:
            txt = f.read()
    except OSError:
        return "gone"
    for line in txt.splitlines():
        if line.startswith("state:"):
            return line.split(":", 1)[1].strip()
    return "closed"

t0 = time.monotonic()
print(f"# teardownmark card{card} base={t0:.6f} CLOCK_MONOTONIC", file=out, flush=True)
prev = state()
print(f"{time.monotonic():.6f}\t{prev}", file=out, flush=True)
while time.monotonic() - t0 < secs:
    s = state()
    if s != prev:
        print(f"{time.monotonic():.6f}\t{s}", file=out, flush=True)
        prev = s
    time.sleep(0.002)
print(f"# end {time.monotonic():.6f}", file=out, flush=True)
