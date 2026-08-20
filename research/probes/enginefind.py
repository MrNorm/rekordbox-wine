#!/usr/bin/env python3
"""enginefind — locate rekordbox's live audio-engine object, and watch its lock.

The engine object is the one that owns the output devices: a pointer to an array
of device pointers at +0x3c8 and the count at +0x3d4 (offsets from the engine
service loop FUN_140fe3530). The devices themselves are findable by their shared
vtable, so the chain is: vtable -> device -> the array that holds it -> the
object that holds the array.

Everything this investigation now cares about hangs off the engine:

    +0x138  WaitableEvent the producer waits on (5 ms, the buffer period)
    +0x1ed  stop flag
    +0x2c2  bool the render path requires before it will produce audio
    +0x2d8  CRITICAL_SECTION the render path takes with TryEnterCriticalSection
            -- and skips the whole audio graph when it cannot get it (phase 34)

`--watch <seconds>` samples that CRITICAL_SECTION as fast as it can and reports
who owns it and for how long. RTL_CRITICAL_SECTION is
{DebugInfo, LockCount, RecursionCount, OwningThread, LockSemaphore, SpinCount};
OwningThread is a Windows thread id, so it is reported raw.

Usage: research/probes/enginefind.py <pid> [--watch SECONDS]
"""
import sys, struct, re, time, collections

DEV_VTABLE = 0x145550178
OFF_DEVARRAY, OFF_NDEV = 0x3c8, 0x3d4
OFF_CS, OFF_FLAG, OFF_STOP = 0x2d8, 0x2c2, 0x1ed
CH = 1 << 24

pid = int(sys.argv[1])
watch = 0.0
if "--watch" in sys.argv:
    watch = float(sys.argv[sys.argv.index("--watch") + 1])
mem = open(f"/proc/{pid}/mem", "rb", 0)

def regions():
    out = []
    for line in open(f"/proc/{pid}/maps"):
        m = re.match(r'([0-9a-f]+)-([0-9a-f]+) (\S+)', line)
        if m and 'w' in m.group(3):
            out.append((int(m.group(1), 16), int(m.group(2), 16)))
    return out

def scan(values):
    """chunked scan -- a whole-region read fails on this process's big heaps and
    a silent skip there cost an hour: the engine lived in one of them."""
    pats = {struct.pack('<Q', v): v for v in values}
    hits = collections.defaultdict(list)
    for a, b in regions():
        p = a
        while p < b:
            n = min(CH, b - p)
            try:
                mem.seek(p); buf = mem.read(n)
            except OSError:
                p += n; continue
            for pat, v in pats.items():
                i = buf.find(pat)
                while i >= 0:
                    hits[v].append(p + i)
                    i = buf.find(pat, i + 1)
            p += n
    return hits

def rd(a, n):
    mem.seek(a); return mem.read(n)
def u32(a): return struct.unpack('<i', rd(a, 4))[0]
def u64(a): return struct.unpack('<Q', rd(a, 8))[0]

devs = scan([DEV_VTABLE])[DEV_VTABLE]
print("device objects:", " ".join(hex(x) for x in devs))
arrs = scan(devs)
cand = set()
for d, places in arrs.items():
    cand.update(places)
holders = scan(sorted(cand))
engine = None
for arr, places in holders.items():
    for p in places:
        base = p - OFF_DEVARRAY
        try:
            n = u32(base + OFF_NDEV)
        except OSError:
            continue
        if 1 <= n <= 8:
            ds = [u64(arr + i*8) for i in range(n)]
            if all(x in devs for x in ds):
                print(f"ENGINE 0x{base:x}  ndev={n} devarray=0x{arr:x} "
                      f"devs={[hex(x) for x in ds]}")
                engine = base
if engine is None:
    sys.exit("no engine found (the device objects may have been rebuilt mid-scan)")

def cs(e):
    dbg, lock, rec, own, sem, spin = struct.unpack('<QiiQQQ', rd(e + OFF_CS, 0x28))
    return lock, rec, own
lock, rec, own = cs(engine)
print(f"stop(+0x1ed)={rd(engine+OFF_STOP,1)[0]} flag(+0x2c2)={rd(engine+OFF_FLAG,1)[0]}")
print(f"CS(+0x2d8): LockCount={lock} Recursion={rec} OwningThread={own}")
print(f"watch addresses:  flag=0x{engine+OFF_FLAG:x}  lockcount=0x{engine+OFF_CS+8:x}  "
      f"owner=0x{engine+OFF_CS+0x10:x}")

if watch:
    t0 = time.monotonic(); n = 0
    held = collections.Counter(); runs = []
    prev_own, prev_t = None, t0
    prev_flag = rd(engine+OFF_FLAG, 1)[0]
    while time.monotonic() - t0 < watch:
        lock, rec, own = cs(engine)
        flag = rd(engine+OFF_FLAG, 1)[0]
        t = time.monotonic()
        n += 1
        if own != prev_own or flag != prev_flag:
            if prev_own is not None:
                runs.append((prev_t - t0, t - prev_t, prev_own, prev_flag))
            prev_own, prev_flag, prev_t = own, flag, t
        held[own] += 1
    runs.append((prev_t - t0, time.monotonic() - prev_t, prev_own, prev_flag))
    print(f"\n{n} samples in {watch:.0f}s ({n/watch:.0f}/s)")
    print("owner occupancy:", held.most_common(8))
    print(f"\n{'start':>8} {'held s':>9}  owner      flag")
    for s, d, o, f in runs:
        if d >= 0.02:
            print(f"{s:8.3f} {d:9.4f}  {o:<10} {f}")
