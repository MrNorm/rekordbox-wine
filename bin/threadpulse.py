#!/usr/bin/env python3
"""threadpulse — WHICH THREAD is busy at the instant the DDJ hand-off stalls?

WHY THIS EXISTS. THEMES/T10 phases 11-14 narrowed the PC MASTER OUT fault to a
very sharp signature: once every 15.000 s something blocks rekordbox's hand-off
to the DDJ for ~46 ms, its output queue gains 2 buffers on the PC endpoint's,
and rekordbox's own cross-device watchdog responds by destroying and rebuilding
both audio streams. Underneath, the ALSA substream never misses a beat
(bin/alsapulse.py: 0 hw_ptr stalls across 4 cycles).

Hunting the 15 s period through the binary's constants has now failed three
times -- the whole JUCE timer system, BrowseBasicView id 4, and a
WaitForMultipleObjects(15000) were each refuted by a live poke. The period may
not be a literal constant at all. So stop looking for the timer and look at the
symptom: at the moment of the stall, some thread is either burning CPU or
blocked on something.

WHAT IT MEASURES, read-only, no debugger:

  * the two device queue depths (same technique as bin/queuescope.py)
  * every thread's CPU time in NANOSECONDS and its scheduling count, from
    /proc/<pid>/task/*/schedstat -- utime+stime in /stat is quantised to 10 ms
    ticks, which is the same order as the event being hunted, and schedstat also
    counts wakeups, which is what a 46 ms gap with no CPU actually looks like
  * wchan for every thread during an excursion -- what the kernel says they are
    blocked in

and then compares, per thread, the CPU burned in the ~1 s around each collapse
against a quiet baseline window from the same cycle. A thread that only works
when the fault fires is the thread to read.

Usage: bin/threadpulse.py <pid> [seconds]
"""
import sys, os, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import queuescope as qs

HZ = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100

def tids(pid):
    try:
        return os.listdir(f"/proc/{pid}/task")
    except OSError:
        return []

def read_schedstat(pid, tid):
    """(run_ns, wait_ns, timeslices). Nanosecond CPU time and how many times the
    thread was scheduled -- a thread that wakes once every 15 s and does almost
    nothing is invisible in tick-based CPU but obvious in the slice count."""
    try:
        with open(f"/proc/{pid}/task/{tid}/schedstat") as f:
            a = f.read().split()
        return int(a[0]), int(a[1]), int(a[2])
    except (OSError, IndexError, ValueError):
        return None

def read_stat(pid, tid):
    """(state, utime+stime in ticks, comm). Parsed from the right of the comm
    field, because a thread name can contain spaces and parentheses."""
    try:
        with open(f"/proc/{pid}/task/{tid}/stat") as f:
            s = f.read()
    except OSError:
        return None
    r = s.rfind(")")
    if r < 0:
        return None
    comm = s[s.find("(") + 1:r]
    rest = s[r + 2:].split()
    try:
        return rest[0], int(rest[11]) + int(rest[12]), comm, int(rest[19])
    except (IndexError, ValueError):
        return None

def read_wchan(pid, tid):
    try:
        with open(f"/proc/{pid}/task/{tid}/wchan") as f:
            return f.read().strip() or "-"
    except OSError:
        return "-"

def main():
    pid = int(sys.argv[1])
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0

    mem = qs.Mem(pid)
    devs = qs.find_devices(mem, pid)
    if len(devs) < 2:
        print(f"threadpulse: found {len(devs)} device object(s); need 2. "
              "Is a track playing with PC MASTER OUT on?")
        sys.exit(1)
    # Which two are actually in use varies between launches -- find_devices
    # returns stale objects from previous stream generations too, and taking a
    # fixed slice picked the dead pair and reported "not enough cycles".
    if len(devs) > 2:
        seen = {d: 0 for d in devs}
        probe_end = time.time() + 2.0
        while time.time() < probe_end:
            for d in devs:
                v = qs.depth(mem, d)
                if v:
                    seen[d] = max(seen[d], v)
            time.sleep(0.02)
        devs = [d for d, _ in sorted(seen.items(), key=lambda kv: -kv[1])[:2]]
        if not all(seen[d] for d in devs):
            print("threadpulse: fewer than two devices showed any queue activity; "
                  "is a track playing with PC MASTER OUT on?")
            sys.exit(1)
    print(f"== threadpulse: pid {pid}, devices {[hex(d) for d in devs]}, {secs:.0f} s")

    samples = []          # (t, depth_a, depth_b, {tid: ticks})
    wchan_dumps = []      # (t, {tid: (comm, state, wchan)})
    known = {}            # tid -> comm
    born = {}             # tid -> starttime in ticks since boot
    t0 = time.time()
    last_dump = 0.0
    while time.time() - t0 < secs:
        t = time.time() - t0
        ds = [qs.depth(mem, d) for d in devs]
        if any(x is None for x in ds):
            time.sleep(0.02); continue
        cpu = {}
        for tid in tids(pid):
            ss = read_schedstat(pid, tid)
            if ss:
                cpu[tid] = ss          # (run_ns, wait_ns, slices)
                if tid not in known:
                    st = read_stat(pid, tid)
                    if st:
                        known[tid] = st[2]
                        born.setdefault(tid, st[3])
        samples.append((t, ds[0], ds[1], cpu))
        # during an excursion, ask the kernel what everything is blocked in
        if abs(ds[1] - ds[0]) >= 2 and t - last_dump > 0.5:
            last_dump = t
            snap = {}
            for tid in tids(pid):
                st = read_stat(pid, tid)
                if st:
                    snap[tid] = (st[2], st[0], read_wchan(pid, tid))
            wchan_dumps.append((t, snap))
        time.sleep(0.01)

    dur = samples[-1][0] - samples[0][0]
    print(f"   {len(samples)} samples at {len(samples)/dur:.0f} Hz, "
          f"{len(known)} threads seen, {len(wchan_dumps)} excursion snapshot(s)\n")

    # collapses = both queues empty
    coll = []
    prev = False
    for t, a, b, _ in samples:
        z = (a == 0 and b == 0)
        if z and not prev:
            coll.append(t)
        prev = z
    print(f"   collapses at: {[f'{c:.2f}' for c in coll]}")
    if len(coll) < 2:
        print("   not enough cycles to compare windows")
        return

    def cpu_between(t1, t2):
        """ticks burned per thread between two times"""
        lo = min(range(len(samples)), key=lambda i: abs(samples[i][0] - t1))
        hi = min(range(len(samples)), key=lambda i: abs(samples[i][0] - t2))
        if hi <= lo:
            return {}, 0.0
        a, b = samples[lo][3], samples[hi][3]
        out = {}
        for tid, v in b.items():
            if tid in a:
                d = (v[0] - a[tid][0], v[2] - a[tid][2])   # run_ns, slices
                if d[0] > 0 or d[1] > 0:
                    out[tid] = d
        return out, samples[hi][0] - samples[lo][0]

    # The causal instant is the ONSET of the spread, not the collapse: between
    # them lie the trim storm and the teardown, whose work would otherwise be
    # credited to whatever thread performs it. Find the first sample in each
    # cycle where the queues part company.
    onsets = []
    for c in coll:
        o = None
        for t, a, b, _ in samples:
            if t >= c:
                break
            if c - 3.0 < t and abs(b - a) >= 1 and not (a == 0 and b == 0):
                o = t if o is None else o
        if o is not None:
            onsets.append(o)
    print(f"   spread onsets: {[f'{o:.2f}' for o in onsets]}")
    print(f"   onset -> collapse: {[f'{c-o:.2f}' for o, c in zip(onsets, coll[-len(onsets):])]}")

    fault = {}
    quiet = {}
    for c in onsets:
        f, fd = cpu_between(c - 0.5, c + 0.2)      # AT the onset
        q, qd = cpu_between(c - 6.0, c - 4.0)      # mid-cycle, known quiet
        for tid, v in f.items():
            r, sl = fault.get(tid, (0.0, 0.0))
            fault[tid] = (r + v[0] / 1e9, sl + v[1])
        for tid, v in q.items():
            r, sl = quiet.get(tid, (0.0, 0.0))
            quiet[tid] = (r + v[0] / 1e9, sl + v[1])

    n = max(len(onsets), 1)
    rows = []
    for tid in set(list(fault) + list(quiet)):
        fr, fw = fault.get(tid, (0.0, 0.0))
        qr, qw = quiet.get(tid, (0.0, 0.0))
        fr, fw = fr / n * 1000.0, fw / n        # ms of CPU, wakeups, per cycle
        qr, qw = qr / n * 1000.0, qw / n
        rows.append((fr - qr, fr, qr, fw, qw, tid, known.get(tid, "?")))
    rows.sort(reverse=True)

    print(f"\n   ms of CPU and wakeups per cycle, fault window vs quiet window, "
          f"over {n} cycle(s)")
    print(f"   {'excess':>8} {'faultms':>8} {'quietms':>8} {'fwake':>6} {'qwake':>6}"
          f"  {'tid':>8}  thread")
    print("   " + "-" * 74)
    # A thread created inside the measured span has no honest "quiet" figure --
    # this exact artefact once produced a confident "no thread does any audio
    # work" in this project. Flag them rather than ranking them.
    newest = sorted(born.values())[-1] if born else 0
    span_ticks = secs * HZ
    for excess, f, q, fw, qw, tid, comm in rows[:18]:
        if abs(excess) < 0.5 and f < 1.0 and abs(fw - qw) < 1.0:
            continue
        flag = "  <- born mid-measurement" \
            if born.get(tid, 0) > newest - span_ticks else ""
        print(f"   {excess:>+8.1f} {f:>8.1f} {q:>8.1f} {fw:>6.1f} {qw:>6.1f}"
              f"  {tid:>8}  {comm}{flag}")

    # THE SHARP QUERY. The trigger fires once per cycle, so the thread that
    # carries it wakes a handful of times in the whole run -- not more. Find
    # every thread whose scheduling count moved only a few times, and print WHEN
    # it moved. If those moments sit on the onsets, that is the thread.
    print(f"\n   rarely-scheduled threads, and when they ran "
          f"(onsets: {[f'{o:.1f}' for o in onsets]})")
    print("   " + "-" * 74)
    first, last = samples[0][3], samples[-1][3]
    rare = []
    for tid, v in last.items():
        if tid in first:
            moved = v[2] - first[tid][2]
            if 1 <= moved <= 40:
                rare.append((moved, tid))
    rare.sort()
    for moved, tid in rare[:22]:
        when = []
        prev = None
        for t, _, _, cpu in samples:
            if tid not in cpu:
                continue
            if prev is not None and cpu[tid][2] > prev:
                when.append(t)
            prev = cpu[tid][2]
        near = sum(1 for w in when if any(abs(w - o) < 0.6 for o in onsets))
        mark = "  <== ON THE ONSETS" if when and near >= max(2, len(when) * 2 // 3) else ""
        print(f"   {moved:>4} wakeup(s)  {tid:>8}  {known.get(tid,'?'):<18} "
              f"at {[f'{w:.1f}' for w in when[:9]]}{mark}")
    if not rare:
        print("   none -- every thread either never ran or ran constantly")

    if wchan_dumps:
        t, snap = wchan_dumps[len(wchan_dumps) // 2]
        blocked = [(tid, c, s, w) for tid, (c, s, w) in snap.items()
                   if w not in ("-", "0") or s in ("R", "D")]
        print(f"\n   what threads were in at t={t:.2f} s (an excursion), "
              f"{len(blocked)} of {len(snap)} interesting:")
        for tid, c, s, w in sorted(blocked, key=lambda x: x[3])[:18]:
            print(f"      {tid:>8}  {s}  {w:<28} {c}")

if __name__ == "__main__":
    main()
