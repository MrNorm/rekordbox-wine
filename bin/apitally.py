#!/usr/bin/env python3
"""apitally — count Wine debug-channel calls per time bucket, without a 800 MB log.

WHY THIS EXISTS. The obvious way to find what rekordbox asks Wine for in one
configuration and not the other is `WINEDEBUG=+mmdevapi`. Done naively that
writes 17 MB/s — an unfiltered run produced a 797 MB log in 45 seconds and had
to be deleted. Nothing in that log was wanted except the NAMES of the calls and
WHEN they happened.

So this sits in the pipe: it reads Wine's stderr, extracts the channel and
function of every trace/fixme/err line, and prints a compact tally per bucket.
The full text is never stored.

    setsid env WINEDEBUG=+mmdevapi wine app.exe 2>&1 | bin/apitally.py --bucket 5

Output, one block per bucket:

    [  15.0s] GetBuffer 4531  ReleaseBuffer 4531  GetCurrentPadding 4531  Start 2 ...

A `--rare` list at the end names every function seen fewer than N times in the
whole run, which is where the interesting one usually is: the storm calls are
the same in every configuration, and the fault lives in something called twice.
"""
import re, sys, time
from collections import Counter, defaultdict

BUCKET = 5.0
RARE = 50
args = sys.argv[1:]
if "--bucket" in args: BUCKET = float(args[args.index("--bucket") + 1])
if "--rare" in args: RARE = int(args[args.index("--rare") + 1])

# 0024:trace:mmdevapi:client_GetBuffer (...)     /  0024:fixme:mmdevapi:foo ... - stub
LINE = re.compile(r"^[0-9a-f]{4}:(trace|warn|fixme|err):(\w+):(\w+)")

t0 = time.monotonic()
bucket_end = t0 + BUCKET
cur = Counter()
total = Counter()
kinds = defaultdict(set)


def flush():
    if not cur:
        return
    t = time.monotonic() - t0
    parts = " ".join(f"{k} {v}" for k, v in cur.most_common(12))
    print(f"[{t:7.1f}s] {parts}", flush=True)
    cur.clear()


try:
    for line in sys.stdin:
        m = LINE.match(line)
        if m:
            kind, chan, func = m.groups()
            key = f"{chan}:{func}"
            cur[key] += 1
            total[key] += 1
            kinds[key].add(kind)
        now = time.monotonic()
        if now >= bucket_end:
            flush()
            while bucket_end <= now:
                bucket_end += BUCKET
except KeyboardInterrupt:
    pass
finally:
    flush()
    print("\n== totals ==", flush=True)
    for k, v in total.most_common():
        if v >= RARE:
            print(f"   {v:8d}  {k}  {'/'.join(sorted(kinds[k]))}")
    print(f"\n== called fewer than {RARE} times — the interesting end ==")
    for k, v in sorted(total.items(), key=lambda kv: kv[1]):
        if v < RARE:
            print(f"   {v:8d}  {k}  {'/'.join(sorted(kinds[k]))}")
