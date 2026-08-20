"""enginethread — which thread is the audio engine, and what is it waiting on?

WHY THIS EXISTS. docs/investigation/THEMES/T10 phase 28: rekordbox's engine service loop
(FUN_140fe3530) does not run for ~13.6 s of every 15.9 s cycle. The pool it
appends to is provably untouched for thirteen seconds at a time (head pointer
sampled at 296 kHz), while the WASAPI feed thread runs flat out shipping
real-time audio made of stale buffer contents. So one thread in this process is
idle for thirteen seconds and then works for one and a half.

The earlier attempt to find it compared CPU at the two ENDS of a window, which
silently drops every thread created inside it -- and rekordbox creates fresh
audio threads at each teardown, exactly where the windows sit. That is the same
instrument fault that once produced a confident and wrong "no thread does any
audio work" in this project. So here the thread set is sampled CONTINUOUSLY and
every increment is attributed to the window it fell in, which works whether or
not the thread survives the run.

WHAT IT MEASURES, read-only:
  * the pool head pointers, to locate the churn windows to the millisecond
  * every thread's run_ns from /proc/<pid>/task/*/schedstat, every sample
  * every thread's wchan, less often -- what the kernel says it is blocked in

and reports the threads whose CPU is concentrated in the churn, then the wchan
each of them sat in while the engine was NOT running.

Usage: research/probes/enginethread.py <pid> [seconds]
"""
import sys, os, time, collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import queuescope as qs

def main():
    pid = int(sys.argv[1])
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 75.0
    mem = qs.Mem(pid)
    task = f"/proc/{pid}/task"

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
    if len(live) < 2:
        print("enginethread: need two live device queues"); sys.exit(1)
    A, B = live

    def head(dev):
        s = mem.u32(dev + 0x60)
        return mem.u64(dev + 0x68 + s * 8) if s is not None and s <= 8 else None
    def run_ns(tid):
        try:
            with open(f"{task}/{tid}/schedstat") as f:
                return int(f.read().split()[0])
        except (OSError, IndexError, ValueError):
            return None
    def rd(tid, what):
        try:
            with open(f"{task}/{tid}/{what}") as f:
                return f.read().strip()
        except OSError:
            return None

    prev = {}                       # tid -> run_ns at the previous sample
    churn_cpu = collections.Counter()
    quiet_cpu = collections.Counter()
    churn_time = 0.0
    quiet_time = 0.0
    wch_quiet = collections.defaultdict(collections.Counter)
    sys_quiet = collections.defaultdict(collections.Counter)
    comms = {}
    last_head = {A: head(A), B: head(B)}
    churn_marks = []
    samples = 0
    t0 = time.monotonic()
    last_t = t0
    while True:
        now = time.monotonic()
        if now - t0 >= secs:
            break
        dt = now - last_t
        last_t = now

        moved = False
        for d in (A, B):
            h = head(d)
            if h is not None and h != last_head[d]:
                moved = True
                last_head[d] = h
        # a sample counts as "churn" if the pool moved within the last 0.6 s
        if moved:
            churn_marks.append(now - t0)
        in_churn = bool(churn_marks) and (now - t0) - churn_marks[-1] < 0.6

        cur = {}
        tids = os.listdir(task)
        for tid in tids:
            v = run_ns(tid)
            if v is None:
                continue
            cur[tid] = v
            if tid in prev and v > prev[tid]:
                d_ns = v - prev[tid]
                (churn_cpu if in_churn else quiet_cpu)[tid] += d_ns
        prev = cur
        if in_churn:
            churn_time += dt
        else:
            quiet_time += dt

        if samples % 8 == 0:
            for tid in tids:
                if tid not in comms:
                    c = rd(tid, "comm")
                    if c:
                        comms[tid] = c
                if not in_churn:
                    w = rd(tid, "wchan")
                    if w:
                        wch_quiet[tid][w] += 1
                    # /proc/.../syscall gives the syscall number and its
                    # arguments, so a blocked futex names its own address
                    # without a debugger -- which matters here because these
                    # threads are destroyed and recreated every cycle and
                    # cannot be inspected after the fact.
                    sc = rd(tid, "syscall")
                    if sc and not sc.startswith("running"):
                        f = sc.split()
                        if f and f[0] == "202" and len(f) > 3:
                            sys_quiet[tid][f"futex(uaddr={f[1]}, op={f[2]}, val={f[3]})"] += 1
                        elif f:
                            sys_quiet[tid][f"syscall {f[0]}"] += 1
        samples += 1
        time.sleep(0.02)

    dur = time.monotonic() - t0
    print(f"== enginethread: pid {pid}")
    print(f"   {samples} samples in {dur:.1f} s   churn {churn_time:.1f} s / "
          f"quiet {quiet_time:.1f} s")
    wins = []
    for c in churn_marks:
        if wins and c - wins[-1][1] < 1.0:
            wins[-1][1] = c
        else:
            wins.append([c, c])
    print(f"   churn windows: {[f'{a:.1f}-{b:.1f}' for a, b in wins if b - a > 0.05]}")

    rows = []
    for tid in set(list(churn_cpu) + list(quiet_cpu)):
        c = churn_cpu[tid] / 1e9 / max(churn_time, 1e-9)   # CPU-seconds per second
        q = quiet_cpu[tid] / 1e9 / max(quiet_time, 1e-9)
        if c < 0.001 and q < 0.001:
            continue
        rows.append((c / max(q, 0.0005), c, q, tid))
    rows.sort(reverse=True)

    print(f"\n   threads by CHURN/QUIET CPU ratio "
          f"(CPU-seconds per second of wall in each phase)")
    print(f"   {'ratio':>9} {'churn':>8} {'quiet':>8}  {'tid':>9}  comm")
    print("   " + "-" * 66)
    for r, c, q, tid in rows[:14]:
        print(f"   {r:>9.1f} {c:>8.4f} {q:>8.4f}  {tid:>9}  {comms.get(tid,'?')}")

    print(f"\n   what the top threads were blocked in while the engine was IDLE:")
    for r, c, q, tid in rows[:6]:
        h = wch_quiet.get(tid)
        if not h:
            continue
        top = ", ".join(f"{k} x{v}" for k, v in h.most_common(4))
        print(f"      {tid:>9} {comms.get(tid,'?'):<18} {top}")
        sq = sys_quiet.get(tid)
        if sq:
            for k, v in sq.most_common(3):
                print(f"                {' ':<18} {k}  x{v}")

if __name__ == "__main__":
    main()
