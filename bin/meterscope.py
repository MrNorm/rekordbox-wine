#!/usr/bin/env python3
"""meterscope — timestamp exactly when rekordbox's master-level indicators light.

WHY. The user reports the master level dial in the top-right "flashes up briefly
(<500 ms) then vanishes for many seconds". That is the level meter following the
audio, so it is a free, faithful oracle for the audio fault: when it stops
flashing and stays lit, the fault is fixed. But "flashes" is a description, not a
measurement -- it has no timestamps and cannot be correlated with anything.

This samples the toolbar strip and reports, per named region, when it lights and
for how long, against the same clock as the Wine logs.

CAPTURE. `import -window` reads the window's own pixels through the compositor.
The root-window x11grab that this project used before returns pure black under
XWayland (T00 I1) -- if the mean of the whole strip is 0, the capture is lying
and the run is void. That check is built in.

  meterscope.py [--secs N] [--hz N] [--out FILE]
"""

import os
import re
import subprocess
import sys
import time

# Regions are window-relative, measured off a 1920x1006 rekordbox window.
# Each is (name, x, y, w, h).
REGIONS = [
    ("pcmaster",  1655, 24, 30, 26),   # the blue laptop icon (PC MASTER OUT)
    ("dial",      1684, 24, 28, 26),   # the circular master level dial
    ("meterbars", 1714, 24, 90, 26),   # the two horizontal level meters
    ("bluebar",   1806, 24, 56, 26),   # the small segmented bar
    ("clock",     1868, 24, 46, 26),   # control: a clock that ticks regardless
]


def ddj_card():
    for c in sorted(os.listdir("/proc/asound")):
        if c.startswith("card") and os.path.exists(f"/proc/asound/{c}/id"):
            if open(f"/proc/asound/{c}/id").read().strip() == "DDJ400":
                return c
    return None


def pcm_state(card):
    """The DDJ playback substream, sampled on the SAME clock as the pixels, so
    'the dial flashed while the stream was doing X' needs no clock alignment
    between two tools -- which is where correlation usually goes wrong."""
    if not card:
        return ("nocard", 0)
    p = f"/proc/asound/{card}/pcm0p/sub0/status"
    try:
        txt = open(p).read()
    except OSError:
        return ("closed", 0)
    m = re.search(r"^state:\s*(\S+)", txt, re.M)
    a = re.search(r"^appl_ptr\s*:\s*(\d+)", txt, re.M)
    return (m.group(1) if m else "closed", int(a.group(1)) if a else 0)


def win_id():
    out = subprocess.run(["xdotool", "search", "--name", "^rekordbox$"],
                         capture_output=True, text=True).stdout.split()
    return out[0] if out else None


def sample(win):
    """One capture, all regions, as {name: mean}. Uses a single import call and
    one magick invocation per region to keep the cadence honest."""
    png = "/tmp/meterscope.png"
    r = subprocess.run(["import", "-window", win, png],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None
    args = ["magick", png]
    for _, x, y, w, h in REGIONS:
        args += ["(", "+clone", "-crop", f"{w}x{h}+{x}+{y}", "+repage",
                 "-format", "%[fx:mean] ", "-write", "info:", "+delete", ")"]
    args += ["null:"]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    vals = [float(v) for v in out.split()]
    if len(vals) != len(REGIONS):
        return None
    return dict(zip([r[0] for r in REGIONS], vals))


def main():
    secs = 60.0
    hz = 10.0
    out_path = None
    a = sys.argv[1:]
    if "--secs" in a: secs = float(a[a.index("--secs") + 1])
    if "--hz" in a:   hz = float(a[a.index("--hz") + 1])
    if "--out" in a:  out_path = a[a.index("--out") + 1]

    win = win_id()
    if not win:
        sys.exit("meterscope: no rekordbox window")

    first = sample(win)
    if not first:
        sys.exit("meterscope: capture failed")
    if sum(first.values()) == 0:
        sys.exit("meterscope: every region is pure black -- the capture is "
                 "lying (T00 I1). Run is VOID.")

    names = [r[0] for r in REGIONS]
    card = ddj_card()
    rows = []
    t0 = time.time()
    period = 1.0 / hz
    while time.time() - t0 < secs:
        loop = time.time()
        s = sample(win)
        if s:
            st, appl = pcm_state(card)
            s["_pcm"] = st
            s["_appl"] = appl
            rows.append((round(time.time() - t0, 3), s))
        slack = period - (time.time() - loop)
        if slack > 0:
            time.sleep(slack)

    if out_path:
        with open(out_path, "w") as fh:
            fh.write("t\t" + "\t".join(names) + "\n")
            for t, s in rows:
                fh.write(f"{t}\t" + "\t".join(f"{s[n]:.5f}" for n in names) + "\n")

    # Per region: a "lit" sample is one clearly above that region's own floor.
    print(f"{len(rows)} samples over {rows[-1][0]:.1f}s at ~{hz:g} Hz\n")
    print(f"{'region':<11} {'min':>8} {'max':>8} {'lit%':>6}  behaviour")
    events = {}
    for n in names:
        v = [s[n] for _, s in rows]
        lo, hi = min(v), max(v)
        thr = lo + (hi - lo) * 0.35
        lit = [x > thr for x in v]
        pct = 100.0 * sum(lit) / len(lit)
        # contiguous lit runs
        runs, cur = [], 0
        for x in lit:
            if x: cur += 1
            elif cur: runs.append(cur); cur = 0
        if cur: runs.append(cur)
        events[n] = (lit, runs)
        shape = "steady" if hi - lo < 1e-4 else (
            f"{len(runs)} bursts, longest {max(runs)/hz:.2f}s" if runs else "never lit")
        print(f"{n:<11} {lo:8.5f} {hi:8.5f} {pct:5.1f}%  {shape}")

    print("\ntimeline (# = lit)")
    for n in names:
        lit, _ = events[n]
        line = "".join("#" if x else "." for x in lit)
        print(f"  {n:<11}{line[:110]}")
    print(f"  {'':<11}{'':<0}" + f"(0 to {min(110/hz, rows[-1][0]):.0f}s)")

    # The whole point: line the pixels up against the audio stream.
    print("\n--- the DDJ stream on the same clock ---")
    # A DEAD device looks exactly like a FIXED one from the pixels alone: the
    # indicators stop cycling because nothing is streaming. This bit me once --
    # a build that broke WASAPI entirely made the master level sit "constantly
    # there", which reads as success. Refuse to let that pass silently.
    states = set(s["_pcm"] for _, s in rows)
    if "RUNNING" not in states:
        print("  *** THE DDJ PCM NEVER RAN in this window (states seen: "
              f"{sorted(states)}).")
        print("  *** Steady indicators here mean the audio device is DEAD, not fixed.")
    elif len([1 for i in range(1, len(rows))
              if rows[i][1]["_pcm"] != rows[i-1][1]["_pcm"]]) == 0:
        print("  (no state changes: the stream stayed " + rows[0][1]["_pcm"] +
              " throughout -- if that is RUNNING, the rebuild cycle has stopped)")
    trans = []
    for i in range(1, len(rows)):
        a, b = rows[i-1][1]["_pcm"], rows[i][1]["_pcm"]
        if a != b:
            trans.append((rows[i][0], a, b))
    for t, a, b in trans[:14]:
        print(f"  t={t:6.1f}s  PCM {a} -> {b}")
    if len(trans) > 1:
        opens = [t for t, a, b in trans if b == "RUNNING"]
        if len(opens) > 1:
            print("  stream (re)opens at: " + ", ".join(f"{t:.1f}" for t in opens[:10]))

    # The point of the tool: when does each burst START?
    for n in names:
        if n == "clock":
            continue
        lit, _ = events[n]
        starts = [rows[i][0] for i in range(1, len(lit)) if lit[i] and not lit[i-1]]
        if starts:
            gaps = [round(starts[i]-starts[i-1], 2) for i in range(1, len(starts))]
            print(f"\n{n}: lights at t = " + ", ".join(f"{s:.1f}" for s in starts[:12]))
            if gaps:
                print(f"{'':{len(n)}}  intervals: {gaps[:11]}")


if __name__ == "__main__":
    main()
