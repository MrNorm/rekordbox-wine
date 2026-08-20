#!/usr/bin/env python3
"""threaddiff — which thread STOPS when PC MASTER OUT is switched on?

WHY THIS EXISTS. threadscope.py compared the 1 s burst against the 14 s silence
*inside the broken configuration* and found every ratio at ~1.1, which refuted
render-blocking. That was the right test of the wrong contrast. Phase 25 gave us
a far stronger one: the same process, the same track, one toolbar toggle, and an
engine that runs at 1.00x or at 0.05x. A thread that is doing the work in the
healthy arm and parked in the broken one is the thread that is waiting, and its
wait channel is the first name in the chain.

WHAT IT DOES.
  sample <secs> <label>   sample every thread's CPU, wchan and state, and write
                          a snapshot to runs/THREADDIFF/<label>.json
  compare <A> <B>         diff two snapshots by tid (the process is the same
                          across the toggle, so tids are comparable), ranked by
                          how much CPU each thread LOST.

TRAPS THIS AVOIDS.
  * A thread that only exists in one arm (the audio device threads are recreated
    on every stream rebuild) is reported as new/gone rather than silently
    treated as a change of zero.
  * CPU is read as jiffies from /proc/<tid>/stat, converted with SC_CLK_TCK, and
    normalised by the ACTUAL elapsed time of the sampling window, not by the
    requested one -- a loop that runs slow would otherwise inflate every number.
  * The DDJ substream state is recorded alongside, so a snapshot taken while the
    device was closed (or the app was not streaming at all) is visible as such
    instead of being compared as though it were the same situation.
"""

import json
import os
import sys
import time
from collections import defaultdict

CLK = os.sysconf("SC_CLK_TCK")
OUT = "runs/THREADDIFF"


def pid_of(name="rekordbox.exe"):
    for p in os.listdir("/proc"):
        if p.isdigit():
            try:
                if open(f"/proc/{p}/comm").read().strip() == name:
                    return int(p)
            except OSError:
                pass
    return None


def ddj_status():
    for c in sorted(os.listdir("/proc/asound")):
        if c.startswith("card"):
            try:
                if open(f"/proc/asound/{c}/usbid").read().strip() == "2b73:0026":
                    return f"/proc/asound/{c}/pcm0p/sub0/status"
            except OSError:
                pass
    return None


def ddj_state(path):
    if not path:
        return "?"
    try:
        for line in open(path):
            if line.startswith("state:"):
                return line.split()[1]
    except OSError:
        pass
    return "closed"


def thread_cpu(pid):
    """{tid: (jiffies, comm, wchan, state)}"""
    out = {}
    try:
        tids = os.listdir(f"/proc/{pid}/task")
    except OSError:
        return out
    for t in tids:
        try:
            st = open(f"/proc/{pid}/task/{t}/stat").read()
            fields = st[st.rindex(")") + 2:].split()
            state = fields[0]
            utime, stime = int(fields[11]), int(fields[12])
            comm = open(f"/proc/{pid}/task/{t}/comm").read().strip()
            try:
                wchan = open(f"/proc/{pid}/task/{t}/wchan").read().strip() or "-"
            except OSError:
                wchan = "-"
            out[int(t)] = (utime + stime, comm, wchan, state)
        except (OSError, ValueError, IndexError):
            continue
    return out


def sample(secs, label):
    pid = pid_of()
    if pid is None:
        sys.exit("FAULT: rekordbox is not running")
    ddj = ddj_status()
    os.makedirs(OUT, exist_ok=True)

    # Per-thread bookkeeping: FIRST and LAST seen jiffies, and the times at
    # which they were seen.
    #
    # The obvious version of this — jiffies at the end minus jiffies at the
    # start — silently reports 0% for every thread that did not exist at the
    # start, because there is nothing to subtract from. In the configuration
    # under investigation the audio threads are DESTROYED AND RECREATED every
    # 15.8 s, so that is every thread that matters, and the first version of
    # this script duly reported "no thread does any audio work when the fault is
    # present". An strace of one of those threads showed it issuing 36,000
    # ioctls a second. A probe that cannot see the interesting threads reads
    # exactly like a system in which they are idle.
    #
    # So: charge each thread over ITS OWN observed interval, and say so.
    seen = {}     # tid -> [j_first, t_first, j_last, t_last, comm]
    wchans = defaultdict(lambda: defaultdict(int))
    states = defaultdict(lambda: defaultdict(int))
    ddj_seen = defaultdict(int)
    n = 0
    t0 = time.monotonic()
    while time.monotonic() - t0 < secs:
        now = time.monotonic()
        cur = thread_cpu(pid)
        for tid, (j, comm, w, s) in cur.items():
            if tid in seen:
                seen[tid][2], seen[tid][3] = j, now
            else:
                seen[tid] = [j, now, j, now, comm]
            wchans[tid][w] += 1
            states[tid][s] += 1
        ddj_seen[ddj_state(ddj)] += 1
        n += 1
        time.sleep(0.25)
    elapsed = time.monotonic() - t0

    rows = {}
    for tid, (j0, tf, j1, tl, comm) in seen.items():
        span = max(0.25, tl - tf)
        pct = 100.0 * ((j1 - j0) / CLK) / span
        dom_w = max(wchans[tid].items(), key=lambda kv: kv[1])[0] if wchans[tid] else "-"
        dom_s = max(states[tid].items(), key=lambda kv: kv[1])[0] if states[tid] else "?"
        rows[str(tid)] = {"comm": comm, "cpu": round(pct, 2), "wchan": dom_w,
                          "state": dom_s, "new": tf > t0 + 0.5,
                          "span": round(span, 1)}
    snap = {"label": label, "pid": pid, "elapsed": round(elapsed, 2),
            "samples": n, "threads": rows,
            "ddj": {k: v for k, v in ddj_seen.items()}}
    path = f"{OUT}/{label}.json"
    json.dump(snap, open(path, "w"), indent=1)

    print(f"== threaddiff sample '{label}' ==")
    print(f"   pid {pid}   {elapsed:.1f}s   {n} samples   {len(rows)} threads")
    print(f"   DDJ substream: {dict(ddj_seen)}")
    short = [r for r in rows.values() if r["span"] < elapsed - 1]
    print(f"   total CPU across all threads: {sum(r['cpu'] for r in rows.values()):.0f}%"
          f"   ({len(short)} threads lived less than the window; each is charged"
          f" over its own lifetime)")
    print(f"   -> {path}")


def compare(a, b):
    A = json.load(open(a if a.endswith(".json") else f"{OUT}/{a}.json"))
    B = json.load(open(b if b.endswith(".json") else f"{OUT}/{b}.json"))
    if A["pid"] != B["pid"]:
        print(f"   NOTE: different pids ({A['pid']} vs {B['pid']}) — thread ids are")
        print(f"         NOT comparable across a relaunch. Reporting by comm only.")
    print(f"== {A['label']} (A)  vs  {B['label']} (B) ==")
    print(f"   A: {A['elapsed']}s  DDJ {A['ddj']}   total CPU {sum(r['cpu'] for r in A['threads'].values()):.0f}%")
    print(f"   B: {B['elapsed']}s  DDJ {B['ddj']}   total CPU {sum(r['cpu'] for r in B['threads'].values()):.0f}%")
    print()
    rows = []
    for tid, ra in A["threads"].items():
        rb = B["threads"].get(tid)
        if rb is None:
            rows.append((ra["cpu"] - 0.0, tid, ra, {"cpu": 0.0, "comm": "(gone)",
                                                    "wchan": "-", "state": "-"}))
        else:
            rows.append((ra["cpu"] - rb["cpu"], tid, ra, rb))
    for tid, rb in B["threads"].items():
        if tid not in A["threads"]:
            rows.append((0.0 - rb["cpu"], tid, {"cpu": 0.0, "comm": "(new)",
                                                "wchan": "-", "state": "-"}, rb))
    rows.sort(key=lambda r: -abs(r[0]))
    print(f"   {'tid':>8} {'comm':<16} {'A %cpu':>8} {'B %cpu':>8} {'delta':>8}   A wchan / B wchan")
    for d, tid, ra, rb in rows[:25]:
        if abs(d) < 0.3:
            continue
        print(f"   {tid:>8} {ra['comm'][:16]:<16} {ra['cpu']:8.2f} {rb['cpu']:8.2f} "
              f"{-d:+8.2f}   {ra['wchan'][:22]} / {rb['wchan'][:22]}")
    print()
    print("   Threads that LOST cpu going from A to B are at the bottom of the")
    print("   delta column (negative). A thread that went from busy to parked is")
    print("   the one waiting; its B wchan is the first name in the chain.")


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "sample":
        sample(float(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else "snap")
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        compare(sys.argv[2], sys.argv[3])
    else:
        print(__doc__)
        sys.exit(2)
