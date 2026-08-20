#!/usr/bin/env python3
"""threadscope — is rekordbox's audio PRODUCER blocked while its render thread spins?

THE HYPOTHESIS. rekordbox writes digital silence into both output streams for
~14 s of every 16 s cycle and real audio for ~1 s just before teardown, while
being served ~302 GetBuffer calls a second. Nothing is blocked at the WASAPI
layer -- the render thread is plainly running. But the thread that MIXES audio
into those buffers could be stalled, in which case the render thread faithfully
copies out silence.

WHAT THIS MEASURES. Per thread, every ~250 ms:
  - CPU consumed since the last sample (utime + stime jiffies)
  - the kernel wait channel it is parked on, if any
  - its state (R/S/D)
and, in the same loop, the DDJ playback substream, so every sample is labelled
with which phase of the cycle it belongs to.

THE DISCRIMINATOR. Split each thread's CPU by phase:
  - a thread busy ONLY during the 1 s burst is the producer, and it is being
    gated by something -- find what it waits on the rest of the time;
  - a thread busy throughout while the output is silent is producing silence
    deliberately, which puts the decision above the audio path entirely;
  - a thread parked on the same wait channel for the whole silent phase and
    running during the burst names its own blocker in `wchan`.

  threadscope.py [--secs N] [--hz N] [--top N]
"""

import os
import re
import sys
import time
from collections import defaultdict

CLK = os.sysconf("SC_CLK_TCK")


def pid_of(name="rekordbox.exe"):
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            if open(f"/proc/{p}/comm").read().strip() == name:
                return int(p)
        except OSError:
            continue
    return None


def ddj_card():
    for c in sorted(os.listdir("/proc/asound")):
        if c.startswith("card"):
            try:
                if open(f"/proc/asound/{c}/id").read().strip() == "DDJ400":
                    return c
            except OSError:
                pass
    return None


def pcm_state(card):
    if not card:
        return "nocard"
    try:
        txt = open(f"/proc/asound/{card}/pcm0p/sub0/status").read()
    except OSError:
        return "closed"
    m = re.search(r"^state:\s*(\S+)", txt, re.M)
    return m.group(1) if m else "closed"


def snapshot(pid):
    """{tid: (cpu_jiffies, state, wchan, comm)} for every thread."""
    out = {}
    try:
        tids = os.listdir(f"/proc/{pid}/task")
    except OSError:
        return out
    for tid in tids:
        base = f"/proc/{pid}/task/{tid}"
        try:
            st = open(f"{base}/stat").read()
            # comm can contain spaces/parens; everything after the final ')'
            tail = st[st.rindex(")") + 2:].split()
            state = tail[0]
            utime, stime = int(tail[11]), int(tail[12])
            comm = open(f"{base}/comm").read().strip()
            try:
                wchan = open(f"{base}/wchan").read().strip() or "-"
            except OSError:
                wchan = "-"
            out[tid] = (utime + stime, state, wchan, comm)
        except (OSError, ValueError, IndexError):
            continue
    return out


def main():
    secs, hz, top = 60.0, 4.0, 14
    a = sys.argv[1:]
    if "--secs" in a: secs = float(a[a.index("--secs") + 1])
    if "--hz" in a:   hz = float(a[a.index("--hz") + 1])
    if "--top" in a:  top = int(a[a.index("--top") + 1])

    pid = pid_of()
    if not pid:
        sys.exit("threadscope: rekordbox.exe is not running")
    card = ddj_card()
    print(f"pid {pid}, {len(snapshot(pid))} threads, card {card}, "
          f"{secs:g}s at {hz:g} Hz\n")

    samples = []          # (t, pcm, {tid: dcpu}, {tid: (state, wchan, comm)})
    prev = snapshot(pid)
    t0 = time.time()
    period = 1.0 / hz
    while time.time() - t0 < secs:
        loop = time.time()
        cur = snapshot(pid)
        d = {tid: cur[tid][0] - prev[tid][0] for tid in cur if tid in prev}
        meta = {tid: cur[tid][1:] for tid in cur}
        samples.append((round(time.time() - t0, 2), pcm_state(card), d, meta))
        prev = cur
        slack = period - (time.time() - loop)
        if slack > 0:
            time.sleep(slack)

    # Phase labelling: the audio burst sits in the ~2 s before each close.
    closes = [samples[i][0] for i in range(1, len(samples))
              if samples[i][1] == "closed" and samples[i - 1][1] != "closed"]
    print("PCM closes at: " + (", ".join(f"{c:.1f}" for c in closes) or "none seen"))
    if not closes:
        print("No teardown seen in this window; phase split will be meaningless.\n")

    def phase(t):
        for c in closes:
            if 0 <= c - t <= 2.0:
                return "burst"
        return "silent"

    cpu = defaultdict(lambda: defaultdict(int))   # tid -> phase -> jiffies
    secs_in = defaultdict(float)
    for t, _, d, _ in samples:
        p = phase(t)
        secs_in[p] += 1.0 / hz
        for tid, v in d.items():
            if v > 0:
                cpu[tid][p] += v

    names = {}
    wch = defaultdict(lambda: defaultdict(int))
    for _, _, _, meta in samples:
        for tid, (state, w, comm) in meta.items():
            names[tid] = comm
            wch[tid][w] += 1

    print(f"\nphase coverage: burst {secs_in['burst']:.1f}s, "
          f"silent {secs_in['silent']:.1f}s\n")
    rows = []
    for tid, d in cpu.items():
        b = d.get("burst", 0) / CLK / max(secs_in["burst"], 1e-9)
        s = d.get("silent", 0) / CLK / max(secs_in["silent"], 1e-9)
        rows.append((b + s, tid, b, s))
    rows.sort(reverse=True)

    print(f"{'tid':>8} {'comm':<16} {'%cpu burst':>10} {'%cpu silent':>11} "
          f"{'ratio':>7}  commonest wchan")
    for _, tid, b, s in rows[:top]:
        ratio = (b / s) if s > 0.001 else float("inf")
        w = max(wch[tid].items(), key=lambda kv: kv[1])[0]
        rstr = "  inf" if ratio == float("inf") else f"{ratio:5.2f}"
        print(f"{tid:>8} {names.get(tid,'?'):<16} {100*b:10.2f} {100*s:11.2f} "
              f"{rstr:>7}  {w}")

    print("\nthreads that run ONLY during the burst (ratio > 3) are the producer;")
    print("their wchan during the silent phase is what gates them.")

    # For the strongest candidates, show the wchan distribution split by phase.
    cands = [tid for _, tid, b, s in rows[:top] if s <= 0.001 or (b / max(s, 1e-9)) > 3]
    for tid in cands[:4]:
        per = defaultdict(lambda: defaultdict(int))
        for t, _, _, meta in samples:
            if tid in meta:
                per[phase(t)][meta[tid][1]] += 1
        print(f"\n  tid {tid} ({names.get(tid)}) wait channels by phase:")
        for p in ("silent", "burst"):
            tot = sum(per[p].values()) or 1
            best = sorted(per[p].items(), key=lambda kv: -kv[1])[:3]
            print(f"    {p:<7} " + ", ".join(f"{k} {100*v//tot}%" for k, v in best))


if __name__ == "__main__":
    main()
