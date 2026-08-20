#!/usr/bin/env python3
"""queueburst — where in the 15 s cycle do the threshold crossings actually fall?

WHY THIS EXISTS. THEMES/T10 phase 20 measured, at 114 kHz, that rekordbox's DDJ
queue exceeds the shallowest device's by the engine's trim threshold of 4 in
0.046% of samples. That is one sample every 25 s at 80 Hz, which is why every
slower probe in this investigation missed it and why phase 19 briefly concluded
the threshold was never crossed at all.

The open question is what sets the 15.9 s period. Two possibilities, and this
tells them apart in one run:

  * the crossings are spread UNIFORMLY through the cycle -> there is no 15 s
    trigger to find. The period is simply how long it takes for crossings to
    become dense enough to land 101 trims inside consecutive 100 ms windows,
    which is what makes the engine announce a device change.
  * the crossings BUNCH at the end of each cycle -> something really does happen
    on a ~15 s clock, and the hunt for it continues.

Three sessions of chasing 15000-millisecond constants (all of them refuted:
every live JUCE timer, browse::BrowseBasicView id 4, a
WaitForMultipleObjects(...,15000)) makes the first possibility worth taking
seriously before looking for a fourth constant.

It samples both queue depths as fast as /proc/<pid>/mem allows, recording only
the start of each threshold crossing and each teardown, then histograms the
crossings by their offset into the cycle.

Usage: bin/queueburst.py <pid> [seconds]
"""
import sys, os, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import queuescope as qs

THRESHOLD   = 4      # the engine's own: trim when depth - min(depth) >= 4
TEARDOWN_S  = 0.25   # both queues empty this long = a real teardown, not a dip

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
        print("queueburst: fewer than two live device queues -- is a track "
              "playing with PC MASTER OUT on?")
        sys.exit(1)
    A, B = live
    print(f"== queueburst: pid {pid}, live devices 0x{A:x} (peak {seen[A]}) "
          f"and 0x{B:x} (peak {seen[B]})")

    crossings = []     # start time of each spread>=THRESHOLD excursion
    teardowns = []     # time each sustained both-empty period began
    n = 0
    in_cross = False
    zero_since = None
    in_teardown = False
    t0 = time.monotonic()
    print(f"   CLOCK_MONOTONIC base = {t0:.6f}  "
          f"(perf record -k mono shares this clock)")
    while True:
        now = time.monotonic()
        if now - t0 >= secs:
            break
        x = qs.depth(mem, A)
        y = qs.depth(mem, B)
        if x is None or y is None:
            continue
        n += 1
        if abs(x - y) >= THRESHOLD:
            if not in_cross:
                crossings.append(now - t0)
                in_cross = True
        else:
            in_cross = False
        if x == 0 and y == 0:
            if zero_since is None:
                zero_since = now
            elif not in_teardown and now - zero_since >= TEARDOWN_S:
                teardowns.append(zero_since - t0)
                in_teardown = True
        else:
            zero_since = None
            in_teardown = False

    dur = time.monotonic() - t0
    print(f"   {n} samples in {dur:.1f} s = {n/dur/1000:.0f} kHz")
    print(f"   threshold crossings : {len(crossings)}")
    print(f"   teardowns           : {len(teardowns)}  "
          f"at {[f'{x:.1f}' for x in teardowns]}")
    print(f"   MONO teardowns      : {[f'{t0+x:.6f}' for x in teardowns]}")
    firsts = []
    for i, td in enumerate(teardowns):
        nxt = [c for c in crossings if c > td + 1.0]
        if nxt:
            firsts.append(nxt[0])
    print(f"   MONO first-crossing : {[f'{t0+x:.6f}' for x in firsts]}")
    if len(teardowns) < 2:
        print("   not enough cycles to histogram")
        return
    cyc = [teardowns[i+1] - teardowns[i] for i in range(len(teardowns)-1)]
    print(f"   cycle lengths       : {[f'{c:.2f}' for c in cyc]}")

    # where in the cycle does each crossing fall?
    bins = {}
    used = 0
    for c in crossings:
        prev = [t for t in teardowns if t <= c]
        if not prev:
            continue
        off = c - prev[-1]
        if off > max(cyc) + 1:
            continue
        bins[int(off)] = bins.get(int(off), 0) + 1
        used += 1
    print(f"\n   {used} crossing(s) placed in a cycle, by seconds since the "
          f"teardown that began it:")
    peak = max(bins.values()) if bins else 1
    for s in range(0, int(max(cyc)) + 2):
        v = bins.get(s, 0)
        bar = "#" * int(40.0 * v / peak) if peak else ""
        print(f"      {s:>3}-{s+1:<3}s  {v:>6}  {bar}")

    tail = sum(v for s, v in bins.items() if s >= int(max(cyc)) - 2)
    print(f"\n   in the last 3 s of each cycle: {tail} of {used} "
          f"({100.0*tail/max(used,1):.0f}%)")
    print("   uniform  -> no 15 s trigger exists; the period is the time for")
    print("               crossings to reach the density the watchdog punishes")
    print("   bunched  -> something does fire on a ~15 s clock; keep hunting it")

if __name__ == "__main__":
    main()
