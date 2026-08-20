"""popcount — how often is a buffer actually taken off the pool?

WHY THIS EXISTS. docs/investigation/THEMES/T10 phase 27 found the append site and measured its
condition: it is unconditional, taken 100% of the time on both devices. The
conclusion drawn was that the pool depth must be set by the consumer. But every
0x130-sized free in the audio engine turns out to be a DRAIN loop
(`while (head) { head = head->next; free }`) belonging to a destructor or reset
path -- `FUN_140fe46f0` even reinstalls the device vtable at `*param_1` -- not a
per-buffer pop.

So before hunting further for a consumer, check whether one exists at all. The
test is direct: the head pointer at `device + 0x68 + slot*8` changes on every
pop. Sample it as fast as /proc/<pid>/mem allows and count the changes.

    pops ~172/s per device   the pool churns; there IS a consumer, and its rate
                             against the onsets says whether it falls behind
    pops ~0                  the pool is STATIC -- the same three buffers, never
                             taken and never replaced -- and the whole
                             producer/consumer reading is wrong

Phase 23 already found that the queue DEPTH never changes between faults, which
is consistent with either. The head pointer distinguishes them.

Usage: research/probes/popcount.py <pid> [seconds]
"""
import sys, os, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import queuescope as qs

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
        print("popcount: fewer than two live device queues")
        sys.exit(1)
    names = {}
    for d in live:
        sub = mem.u64(d + 0x18); nm = "?"
        if sub:
            p = mem.u64(sub + 8)
            if p:
                bb = mem.read(p, 80)
                if bb:
                    nm = bb.split(b"\x00")[0].decode("latin1", "replace")
        names[d] = nm
    A, B = live
    print(f"== popcount: pid {pid}")
    print(f"   A 0x{A:x}  {names[A]!r}")
    print(f"   B 0x{B:x}  {names[B]!r}\n")

    def head(dev):
        slot = mem.u32(dev + 0x60)
        if slot is None or slot > 8:
            return None
        return mem.u64(dev + 0x68 + slot * 8)

    pops = {A: [], B: []}          # timestamps of head changes
    tds = []
    last = {A: head(A), B: head(B)}
    zero_since = None; in_td = False
    n = 0
    t0 = time.monotonic()
    while True:
        now = time.monotonic()
        if now - t0 >= secs:
            break
        n += 1
        both_zero = True
        for d in (A, B):
            h = head(d)
            if h is None:
                continue
            if h != last[d]:
                pops[d].append(now - t0)
                last[d] = h
            if h != 0:
                both_zero = False
        if both_zero:
            if zero_since is None:
                zero_since = now
            elif not in_td and now - zero_since >= 0.25:
                tds.append(zero_since - t0); in_td = True
        else:
            zero_since = None; in_td = False

    dur = time.monotonic() - t0
    print(f"   {n} samples in {dur:.1f} s = {n/dur/1000:.0f} kHz")
    print(f"   teardowns at: {[f'{x:.1f}' for x in tds]}\n")
    for d in (A, B):
        p = pops[d]
        print(f"   {names[d][:26]:<26} head changed {len(p):>7} times = "
              f"{len(p)/dur:>8.1f} /s")
    if not any(pops.values()):
        print("\n   NO head changes at all: the pool is static. Nothing is popped.")
        return

    # pops per second, marked against the teardowns
    print(f"\n   pops per second, per device (T = a teardown began in this second)")
    print(f"   {'t':>5}  {'A':>7}  {'B':>7}")
    for s in range(int(dur)):
        a = sum(1 for x in pops[A] if s <= x < s + 1)
        b = sum(1 for x in pops[B] if s <= x < s + 1)
        mark = "  T" if any(s <= td < s + 1 for td in tds) else ""
        print(f"   {s:>5}  {a:>7}  {b:>7}{mark}")

if __name__ == "__main__":
    main()
