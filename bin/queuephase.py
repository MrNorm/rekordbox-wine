#!/usr/bin/env python3
"""queuephase — do the two devices' service events drift past each other?

WHY THIS EXISTS. Everything else has been ruled out. THEMES/T10 phases 13-22:
the ~15 s trigger is not a JUCE timer, not a WaitForMultipleObjects timeout, not
any hrtimer (rekordbox never arms one longer than 5 s except two that are
re-armed every few ms), not a Wine audio constant, and no thread wakes or burns
CPU at the onset -- yet the trigger is real and repeatable to 0.3%, with 100% of
threshold crossings in the last 3 s of each cycle (phase 21).

A BEAT explains all of that at once. rekordbox services both output devices from
ONE engine thread. The two devices run on independent clocks -- the DDJ's USB
crystal at 44100 and the PC endpoint's codec at 48000 -- so their service
deadlines drift past one another at a rate set by the difference. When the two
fall due at nearly the same instant, one servicer cannot satisfy both, and the
device it serves second falls behind. That coincidence recurs with the beat
period, exactly, forever, with nothing waking up and nothing burning CPU.

A beat of 15 s from a 23.2 ms buffer period needs a relative error of only
23.2/15000 = 0.155%, which is the order `dualclient` already measured between
these two endpoints (0.05-0.11%, T10 phase 17/T03).

WHAT IT MEASURES. Sampling both queue depths as fast as /proc/<pid>/mem allows,
every change in a device's depth marks a service event for that device. From
those two event streams it derives each device's period and, for each service of
device A, the phase offset to the nearest service of device B. If that offset
ramps linearly and wraps with the cycle, the beat is the trigger.

Usage: bin/queuephase.py <pid> [seconds]
"""
import sys, os, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import queuescope as qs

def main():
    pid = int(sys.argv[1])
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 45.0
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
        print("queuephase: fewer than two live device queues")
        sys.exit(1)
    A, B = live
    print(f"== queuephase: pid {pid}, devices 0x{A:x} and 0x{B:x}, {secs:.0f} s")

    ea, eb = [], []          # service-event timestamps per device
    tds = []                 # teardowns
    lx = ly = None
    zero_since = None
    in_td = False
    n = 0
    t0 = time.monotonic()
    while True:
        now = time.monotonic()
        if now - t0 >= secs:
            break
        x = qs.depth(mem, A)
        y = qs.depth(mem, B)
        if x is None or y is None:
            continue
        n += 1
        if lx is not None and x != lx:
            ea.append(now - t0)
        if ly is not None and y != ly:
            eb.append(now - t0)
        lx, ly = x, y
        if x == 0 and y == 0:
            if zero_since is None:
                zero_since = now
            elif not in_td and now - zero_since >= 0.25:
                tds.append(zero_since - t0)
                in_td = True
        else:
            zero_since = None
            in_td = False

    dur = time.monotonic() - t0
    print(f"   {n} samples in {dur:.1f} s = {n/dur/1000:.0f} kHz")
    print(f"   service events: A {len(ea)}  B {len(eb)}")
    print(f"   teardowns at   : {[f'{x:.1f}' for x in tds]}")
    if len(ea) < 50 or len(eb) < 50:
        print("   too few events")
        return

    def period(ev):
        """median gap, ignoring the sub-millisecond doubles that one depth
        change can produce when it passes through an intermediate value"""
        g = sorted(b - a for a, b in zip(ev, ev[1:]) if b - a > 0.0005)
        return g[len(g) // 2] if g else 0.0

    pa, pb = period(ea), period(eb)
    print(f"   median service period: A {pa*1000:.3f} ms   B {pb*1000:.3f} ms")
    if pa > 0 and pb > 0:
        rel = abs(pa - pb) / max(pa, pb)
        print(f"   relative difference  : {rel*100:.4f}%"
              + (f"  -> beat every {max(pa,pb)/rel:.1f} s" if rel > 1e-9 else ""))

    # phase of the nearest B service to each A service, unwrapped into [0, pb)
    import bisect
    print(f"\n   phase of A's service within B's period, sampled through the run")
    print(f"   {'t':>7}  {'phase ms':>9}  bar")
    step = max(1, len(ea) // 40)
    for i in range(0, len(ea), step):
        ta = ea[i]
        j = bisect.bisect_left(eb, ta)
        if j == 0 or j >= len(eb):
            continue
        ph = ta - eb[j - 1]
        if pb > 0:
            ph = ph % pb
        bar = "#" * int(60.0 * ph / pb) if pb else ""
        mark = ""
        for td in tds:
            if abs(ta - td) < 0.4:
                mark = "  <- teardown"
        print(f"   {ta:7.2f}  {ph*1000:9.3f}  {bar}{mark}")

if __name__ == "__main__":
    main()
