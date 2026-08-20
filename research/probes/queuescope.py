#!/usr/bin/env python3
"""queuescope — watch rekordbox's per-device output queues and its trim watchdog.

WHY THIS EXISTS. docs/investigation/THEMES/T10 phase 8 established, at runtime, that the 15.9 s
audio teardown is not triggered by anything outside rekordbox. The engine's
per-device service loop (0x140fe3530) keeps every output device's queue within
3 buffers of the SHALLOWEST device's queue; when a device is deeper than that it
unlinks the excess, and if it has had to do that 101 times with less than 100 ms
between trims it announces a device-list change -- which tears both streams down
and reopens them a second later.

With one device, depth - min(depth) is always 0, so it can never fire. That is
why PC MASTER OUT off is healthy and PC MASTER OUT on is not.

WHAT IT MEASURES, read-only through /proc/<pid>/mem, with no breakpoints:

    per device:  queue depth (walking the +0x128 chain)
                 trim_count  (dev+0x98)  -- climbs to 101, then resets
                 last_trim   (dev+0x88)  -- ms timestamp of the most recent trim

A breakpoint cannot be used here: the watchdog is made of timing, and a
breakpoint on a site hit ~100 times per cycle would create the very storm it is
trying to detect. This probe only reads memory.

HOW TO GET THE ENGINE ADDRESS. It is allocated on the heap, so it differs every
launch. Break once at the announce call site and read it from r8:

    break *0x140fe442f     ->  engine = r8 - 0x3f0

(see runs/GDB/*-engine.log). Delete breakpoints BEFORE detaching or the
inferior does not survive.

FINDING THE DEVICES WITHOUT A DEBUGGER. Attaching gdb to rekordbox is not free
-- one attach/detach cycle in this investigation left the app in a Wine crash
dialog, which then reads as "the queues are empty" when in fact the app is dead.
So the default mode takes no debugger at all: both device objects share a vtable
pointer at +0x00, and scanning the process's writable anonymous memory for it
finds them directly. The engine object is not needed.

Usage: research/probes/queuescope.py <pid> [seconds]              # scan for the devices
       research/probes/queuescope.py <pid> <engine-hex> [seconds] # or via a known engine

Add --trace <file.tsv> to log EVERY sample (~50 Hz), not just one line a
second. The per-second view shows that the queues diverge; only the trace shows
HOW -- a straight ramp means the two devices genuinely consume at different
rates, a staircase means one of them stalls in discrete events. Those are
different Wine bugs.
"""
import sys, time, struct

OFF_DEVARRAY   = 0x3c8   # engine: pointer to array of device pointers
OFF_NDEVICES   = 0x3d4   # engine: how many
OFF_SLOT       = 0x60    # device: which queue slot is live
OFF_QUEUE      = 0x68    # device: queue head is at +0x68 + slot*8
OFF_LASTTRIM   = 0x88    # device: ms timestamp of the last trim
OFF_TRIMCOUNT  = 0x98    # device: consecutive rapid trims, fires at >100
NEXT_PTR       = 0x128   # queue entry: next
MAX_WALK       = 4096    # a corrupt/racing read must not spin for ever
DEV_VTABLE     = 0x145550178   # rekordbox 7.2.18: the vtable both output
                               # device objects carry at +0x00

class Mem:
    def __init__(self, pid):
        self.f = open(f"/proc/{pid}/mem", "rb", 0)
    def read(self, addr, n):
        try:
            self.f.seek(addr)
            return self.f.read(n)
        except (OSError, ValueError, OverflowError):
            return None
    def u64(self, addr):
        b = self.read(addr, 8)
        return struct.unpack("<Q", b)[0] if b and len(b) == 8 else None
    def u32(self, addr):
        b = self.read(addr, 4)
        return struct.unpack("<I", b)[0] if b and len(b) == 4 else None
    def i64(self, addr):
        b = self.read(addr, 8)
        return struct.unpack("<q", b)[0] if b and len(b) == 8 else None

def depth(mem, dev):
    """Length of this device's queue. Read live and without a lock, so a torn
    read is possible; that shows up as a one-sample spike, not a trend."""
    slot = mem.u32(dev + OFF_SLOT)
    if slot is None or slot > 64:
        return None
    head = mem.u64(dev + OFF_QUEUE + slot * 8)
    if head is None:
        return None
    n, p, seen = 0, head, set()
    while p and n < MAX_WALK:
        if p in seen:
            break                      # a cycle means we raced a writer
        seen.add(p)
        p = mem.u64(p + NEXT_PTR)
        if p is None:
            break
        n += 1
    return n

def writable_regions(pid):
    """Anonymous read/write mappings -- where the heap objects live. The big
    file-backed mappings are skipped: they cannot hold a heap device object and
    scanning them costs seconds."""
    out = []
    for line in open(f"/proc/{pid}/maps"):
        parts = line.split()
        rng, perms = parts[0], parts[1]
        path = parts[5] if len(parts) > 5 else ""
        if "w" not in perms or "s" in perms:
            continue
        if path and not path.startswith("["):
            continue
        a, b = (int(x, 16) for x in rng.split("-"))
        if b - a > (1 << 30):
            continue
        out.append((a, b))
    return out

def find_devices(mem, pid):
    """Every address holding the device vtable, filtered to objects that look
    like a live output device (a sane slot index and a plausible ms clock)."""
    import numpy as np
    needle = np.uint64(DEV_VTABLE)
    hits = []
    for a, b in writable_regions(pid):
        blob = mem.read(a, b - a)
        if not blob or len(blob) < 8:
            continue
        n = (len(blob) // 8) * 8
        arr = np.frombuffer(blob[:n], dtype=np.uint64)
        for idx in np.nonzero(arr == needle)[0]:
            hits.append(a + int(idx) * 8)
    strict, loose = [], []
    for h in hits:
        slot = mem.u32(h + OFF_SLOT)
        last = mem.u64(h + OFF_LASTTRIM)
        if slot is None or last is None or slot > 8:
            continue
        loose.append(h)
        if last >= (1 << 30):         # a plausible millisecond clock
            strict.append(h)
    # A device that has NEVER been trimmed has a zero last-trim timestamp, which
    # is exactly the healthy arm -- so the timestamp cannot be required. Prefer
    # the trimmed ones when they exist, fall back to all plausible objects.
    return strict if strict else loose

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    pid = int(sys.argv[1])
    engine = None
    rest = sys.argv[2:]
    if rest and rest[0].startswith("0x"):
        engine = int(rest[0], 16)
        rest = rest[1:]
    secs = float(rest[0]) if rest else 60.0

    trace = None
    if "--trace" in rest:
        i = rest.index("--trace")
        trace = open(rest[i + 1], "w")
        trace.write(f"# t0_epoch={time.time():.4f}\n")
        trace.write("t\t" + "\t".join(f"depth{j}\ttrim{j}" for j in range(8)) + "\n")
        rest = rest[:i] + rest[i + 2:]
    secs = float(rest[0]) if rest else 60.0

    mem = Mem(pid)
    if engine is not None:
        n = mem.u32(engine + OFF_NDEVICES)
        arr = mem.u64(engine + OFF_DEVARRAY)
        if not n or not arr or n > 16:
            print(f"queuescope: engine 0x{engine:x} does not look right "
                  f"(ndevices={n}, devarray={arr}) -- wrong address, or the process died")
            sys.exit(1)
        devs = [mem.u64(arr + i * 8) for i in range(n)]
        print(f"== queuescope: pid {pid}, engine 0x{engine:x}, {n} device(s)")
    else:
        devs = find_devices(mem, pid)
        n = len(devs)
        if n == 0:
            print("queuescope: found no output device objects. Either rekordbox is not "
                  "running audio, or this is not 7.2.18 (the vtable constant would differ).")
            sys.exit(1)
        print(f"== queuescope: pid {pid}, {n} device object(s) found by vtable scan")
    for i, d in enumerate(devs):
        print(f"   device {i}: 0x{d:x}")
    print("\n   t       depths        spread  trim_count(s)     events")
    print("   ------  ------------  ------  ---------------  ------")

    t0 = time.time()
    maxdepth = [0] * n
    prev_tc = [None] * n
    prev_lt = [mem.u64(d + OFF_LASTTRIM) for d in devs]
    trim_events = [0] * n
    trims_seen = [0] * n
    announces = 0
    max_spread = 0
    samples = 0
    resets = 0
    last_print = 0.0
    while time.time() - t0 < secs:
        ds = [depth(mem, d) for d in devs]
        tcs = [mem.u32(d + OFF_TRIMCOUNT) for d in devs]
        if any(x is None for x in ds) or any(x is None for x in tcs):
            time.sleep(0.05)
            continue
        for i in range(n):
            if ds[i] > maxdepth[i]:
                maxdepth[i] = ds[i]
        samples += 1
        # Only the devices that are actually in use. find_devices also returns
        # stale objects from earlier stream generations, which sit at 0 for
        # ever; including them made every reading look like a spread of 5 when
        # the live pair had barely parted company. See T10 phase 19.
        live = [ds[i] for i in range(n) if maxdepth[i] > 0] or ds
        spread = max(live) - min(live)
        if spread > max_spread:
            max_spread = spread
        ev = ""
        for i in range(n):
            lt = mem.u64(d_ + OFF_LASTTRIM) if False else mem.u64(devs[i] + OFF_LASTTRIM)
            if lt is not None and prev_lt[i] is not None and lt != prev_lt[i]:
                trim_events[i] += 1
                prev_lt[i] = lt
            if prev_tc[i] is not None:
                if tcs[i] > prev_tc[i]:
                    trims_seen[i] += tcs[i] - prev_tc[i]
                elif tcs[i] < prev_tc[i] and prev_tc[i] > 50:
                    resets += 1
                    announces += 1
                    ev = f"<- dev{i} trim_count RESET after {prev_tc[i]} (ANNOUNCE)"
            prev_tc[i] = tcs[i]
        t = time.time() - t0
        if trace:
            trace.write(f"{t:.4f}\t" + "\t".join(f"{ds[j]}\t{tcs[j]}" for j in range(n)) + "\n")
        if ev or t - last_print >= 1.0:
            last_print = t
            print(f"   {t:6.1f}  {str(ds):<12}  {spread:>6}  {str(tcs):<15}  {ev}")
        time.sleep(0.02)

    if trace:
        trace.close()
    print(f"\n== RESULT after {time.time()-t0:.0f} s, {samples} samples ==")
    print(f"   max spread between LIVE device queues : {max_spread}")
    print(f"   peak depth per device                : {maxdepth}")
    print(f"   trims counted per device         : {trims_seen}")
    print(f"   last-trim timestamp changes      : {trim_events}")
    print(f"   trim_count resets (= announces)  : {announces}")
    if max_spread >= 4:
        print("   The spread between live devices reached 4. Note this is NOT by")
        print("   itself proof of the trim threshold -- see T10 phase 19.")
    elif max_spread == 0:
        print("   The queues never diverged. Either only one device is live, or the")
        print("   trim threshold is not what is firing -- reopen the hypothesis.")

if __name__ == "__main__":
    main()
