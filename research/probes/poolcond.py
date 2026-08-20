#!/usr/bin/env python3
"""poolcond — watch the condition that decides whether rekordbox appends a buffer.

WHY THIS EXISTS. docs/investigation/THEMES/T10 phase 27 found the insert site. `FUN_140fe51a0`,
called once per device at the top of the engine's service loop, decides between
two paths:

    if (device->[0x2c] != 0) {
        if (   *(double*)(device+0x108) == *(double*)(device+0xf0)
            || *(int*)(device+0x11c)    != *(int*)(device+0x2c) / 2 )
        {
            entry = operator new(0x130);   /* a 0x130-byte audio buffer */
            ...copy the source buffer in...
            walk the +0x128 chain to its tail and APPEND    <-- the pool grows
        } else {
            ...resample/mix in place, no allocation...
        }
    }

Two doubles compared for **exact equality** pick the branch. That is the shape of
a rate check -- "is the source rate the destination rate?" -- and exact equality
on doubles is brittle by construction. If one of those numbers drifts or is
recomputed, the branch flips, and the pool starts growing.

Phases 25-26 proved nothing outside the process changes at the onset: Wine hands
both streams ~44,100 frames every second, with no anomaly in the onset seconds.
So the trigger has to be a number rekordbox computes for itself. These are the
numbers that gate the only code that grows the pool.

WHAT IT MEASURES, read-only through /proc/<pid>/mem: the four fields of the
condition and the queue depth, per device, and it prints a line whenever any of
them changes, plus a summary of how the condition evaluated over time.

Usage: research/probes/poolcond.py <pid> [seconds]
"""
import sys, os, time, struct

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import queuescope as qs

OFF_CHANNELS = 0x2c    # int   -- the "/2" is compared against +0x11c
OFF_D1       = 0xf0    # double
OFF_D2       = 0x108   # double
OFF_I11C     = 0x11c   # int

def fields(mem, dev):
    b = mem.read(dev + 0x2c, 0x100)
    if not b or len(b) < 0x100:
        return None
    ch   = struct.unpack_from("<i", b, 0)[0]
    d1   = struct.unpack_from("<d", b, OFF_D1 - 0x2c)[0]
    d2   = struct.unpack_from("<d", b, OFF_D2 - 0x2c)[0]
    i11c = struct.unpack_from("<i", b, OFF_I11C - 0x2c)[0]
    return ch, d1, d2, i11c

def main():
    pid = int(sys.argv[1])
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    mem = qs.Mem(pid)

    devs = qs.find_devices(mem, pid)
    seen = {d: 0 for d in devs}
    t = time.monotonic()
    while time.monotonic() - t < 3:
        for d in devs:
            v = qs.depth(mem, d)
            if v:
                seen[d] = max(seen[d], v)
        time.sleep(0.01)
    live = [d for d, _ in sorted(seen.items(), key=lambda kv: -kv[1])[:2]]
    if len(live) < 2 or not all(seen[d] for d in live):
        print("poolcond: fewer than two live device queues")
        sys.exit(1)

    names = {}
    for d in live:
        sub = mem.u64(d + 0x18)
        nm = "?"
        if sub:
            p = mem.u64(sub + 8)
            if p:
                bb = mem.read(p, 80)
                if bb:
                    nm = bb.split(b"\x00")[0].decode("latin1", "replace")
        names[d] = nm
    print(f"== poolcond: pid {pid}")
    for d in live:
        print(f"   0x{d:x}  {names[d]!r}")
    print(f"\n   APPEND happens when:  d(+0x108) == d(+0xf0)   OR   "
          f"i(+0x11c) != i(+0x2c)/2\n")

    t0 = time.monotonic()
    prev = {}
    changes = 0
    stats = {d: {"append": 0, "resample": 0} for d in live}
    while time.monotonic() - t0 < secs:
        now = time.monotonic() - t0
        for d in live:
            f = fields(mem, d)
            if not f:
                continue
            ch, d1, d2, i11c = f
            append = (d2 == d1) or (i11c != ch // 2)
            stats[d]["append" if append else "resample"] += 1
            key = (ch, d1, d2, i11c)
            if prev.get(d) != key:
                if d in prev:
                    changes += 1
                    dep = qs.depth(mem, d)
                    print(f"   t={now:7.3f}  {names[d][:22]:<22} "
                          f"ch={ch:<3} +0xf0={d1!r:<22} +0x108={d2!r:<22} "
                          f"+0x11c={i11c:<6} -> {'APPEND' if append else 'resample'} "
                          f"depth={dep}")
                prev[d] = key
        time.sleep(0.005)

    print(f"\n== RESULT after {time.monotonic()-t0:.0f} s, {changes} change(s)")
    for d in live:
        s = stats[d]
        tot = s["append"] + s["resample"] or 1
        print(f"   {names[d][:28]:<28} append {100.0*s['append']/tot:5.1f}%  "
              f"resample {100.0*s['resample']/tot:5.1f}%")
    if changes == 0:
        print("   The condition never changed. Either it is not what flips, or the")
        print("   flip is briefer than this sampling -- try the burst approach.")

if __name__ == "__main__":
    main()
