#!/usr/bin/env python3
"""filepulse — which files does rekordbox touch, and exactly when?

WHY THIS EXISTS. docs/investigation/THEMES/T10 phase 11 showed the audio teardown is triggered by a
DISCRETE event on a ~15.9 s period, not by accumulating drift: the output queues
sit perfectly balanced for 14.5 s and then fail inside one second. Something
fires on a timer. This finds out whether that something is visible as file I/O
-- phase 5 recorded a settings rewrite on roughly the same cadence.

It polls every file under a directory at 20 Hz and prints a line whenever an
mtime or size changes, stamped with the same wall clock that
`research/probes/queuescope.py --trace` records in its header, so the two logs can be laid
side by side and each write matched against each queue excursion.

Usage: research/probes/filepulse.py <dir> [seconds]
"""
import sys, os, time

def snap(root):
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            try:
                st = os.stat(p)
            except OSError:
                continue
            out[p] = (st.st_mtime, st.st_size)
    return out

def main():
    root = sys.argv[1]
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 60.0
    t0 = time.time()
    print(f"# t0_epoch={t0:.4f}  root={root}")
    print("t_rel\tepoch\tsize\tpath")
    prev = snap(root)
    n = 0
    while time.time() - t0 < secs:
        cur = snap(root)
        now = time.time()
        for p, v in cur.items():
            if prev.get(p) != v:
                n += 1
                print(f"{now-t0:7.2f}\t{now:.3f}\t{v[1]:>10}\t{os.path.basename(p)}", flush=True)
        prev = cur
        time.sleep(0.05)
    print(f"# {n} change event(s) in {time.time()-t0:.0f} s")

if __name__ == "__main__":
    main()
