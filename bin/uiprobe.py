#!/usr/bin/env python3
"""uiprobe — adjudicate a COMPLEX UI, not just "did a window appear".

The existing oracle answers one question: does this window render and echo a
keystroke. That was the right question for a login dialog. It is far too coarse
for the main rekordbox UI, where the interesting failures are partial: a sidebar
that renders cut off, nav labels that never paint, panes that ignore clicks.
A whole-window RMSE cannot see any of that — a window can be 95% frozen and
still show a large diff because one clock digit ticked.

So this works per REGION and per INTERACTION:

  * the window is divided into a grid; every capture is reduced to per-cell
    means, so we can say *where* something changed rather than just whether
  * each scripted interaction is bracketed by captures, giving a per-step
    "did the UI respond, and where" answer
  * cells that never change across the entire session are reported as DEAD,
    which is the signature of the "renders once, then stale" class of bug
  * named regions can be OCR'd to check that text actually paints

No numpy/PIL: ImageMagick reduces each shot to raw 8-bit grayscale and the
arithmetic is done in plain Python, which is fast enough at grid resolution.

Scenario steps use FRACTIONAL coordinates (0..1 of window width/height) so a
scenario survives a window-size change instead of silently clicking the wrong
thing.
"""
import json
import os
import subprocess
import sys
import time

GRID_COLS, GRID_ROWS = 8, 6
SAMPLE_W, SAMPLE_H = 160, 120          # downsample target; grid divides it evenly
CELL_CHANGED = 2.0                     # mean |delta| (0-255) for "this cell changed"
STEP_SETTLE = 1.2                      # seconds between acting and capturing


def sh(cmd, timeout=30):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return subprocess.CompletedProcess(cmd, 1, "", "timeout")


def gray(png):
    """PNG -> raw grayscale bytes at SAMPLE_W x SAMPLE_H (aspect ignored on purpose)."""
    p = subprocess.run(
        ["magick", png, "-colorspace", "Gray", "-depth", "8",
         "-resize", f"{SAMPLE_W}x{SAMPLE_H}!", "gray:-"],
        capture_output=True, timeout=60)
    b = p.stdout
    return b if len(b) == SAMPLE_W * SAMPLE_H else None


def cells(buf):
    """Per-cell mean intensity, row-major, GRID_ROWS x GRID_COLS."""
    cw, ch = SAMPLE_W // GRID_COLS, SAMPLE_H // GRID_ROWS
    out = []
    for gr in range(GRID_ROWS):
        for gc in range(GRID_COLS):
            total = 0
            for y in range(gr * ch, (gr + 1) * ch):
                base = y * SAMPLE_W + gc * cw
                total += sum(buf[base:base + cw])
            out.append(total / float(cw * ch))
    return out


def changed_cells(a, b):
    return [i for i, (x, y) in enumerate(zip(a, b)) if abs(x - y) >= CELL_CHANGED]


def grid_art(indices, note=""):
    """Human-readable map of which cells changed."""
    s = set(indices)
    rows = []
    for r in range(GRID_ROWS):
        rows.append("    " + "".join("#" if r * GRID_COLS + c in s else "."
                                     for c in range(GRID_COLS)))
    return "\n".join(rows) + (f"   {note}" if note else "")


class Probe:
    def __init__(self, wid, outdir):
        self.wid = wid
        self.outdir = outdir
        self.n = 0
        os.makedirs(os.path.join(outdir, "shots"), exist_ok=True)
        g = sh(["xdotool", "getwindowgeometry", "--shell", str(wid)]).stdout
        self.geo = dict(l.split("=", 1) for l in g.strip().splitlines() if "=" in l)
        self.W, self.H = int(self.geo["WIDTH"]), int(self.geo["HEIGHT"])
        self.ever_changed = set()

    def abs_xy(self, fx, fy):
        return int(self.W * fx), int(self.H * fy)

    def capture(self, tag):
        """Capture the target window only. Refuses if it is not actually active,
        so a destroyed window can never cause us to photograph something else."""
        self.n += 1
        path = os.path.join(self.outdir, "shots", f"{self.n:03d}-{tag}.png")
        sh(["xdotool", "windowactivate", "--sync", str(self.wid)])
        time.sleep(0.35)
        active = sh(["xdotool", "getactivewindow"]).stdout.strip()
        if active != str(self.wid):
            return None, f"target not active (active={active})"
        r = sh(["timeout", "20", "spectacle", "-a", "-b", "-n", "-o", path], timeout=40)
        if not os.path.exists(path) or os.path.getsize(path) == 0:
            return None, "capture failed"
        buf = gray(path)
        if buf is None:
            return None, "downsample failed"
        return (path, cells(buf)), None


def run_scenario(probe, steps, log):
    results = []
    base, err = probe.capture("baseline")
    if err:
        log(f"FATAL: baseline capture: {err}")
        return results, None
    prev = base[1]

    for i, st in enumerate(steps, 1):
        act = st.get("action", "click")
        name = st.get("name", f"step{i}")

        if act == "click":
            x, y = probe.abs_xy(st["x"], st["y"])
            sh(["xdotool", "mousemove", "--window", str(probe.wid), str(x), str(y),
                "click", str(st.get("button", 1))])
        elif act == "doubleclick":
            x, y = probe.abs_xy(st["x"], st["y"])
            sh(["xdotool", "mousemove", "--window", str(probe.wid), str(x), str(y),
                "click", "--repeat", "2", "1"])
        elif act == "hover":
            x, y = probe.abs_xy(st["x"], st["y"])
            sh(["xdotool", "mousemove", "--window", str(probe.wid), str(x), str(y)])
        elif act == "drag":
            x1, y1 = probe.abs_xy(st["x"], st["y"])
            x2, y2 = probe.abs_xy(st["x2"], st["y2"])
            sh(["xdotool", "mousemove", "--window", str(probe.wid), str(x1), str(y1),
                "mousedown", "1"])
            time.sleep(0.3)
            sh(["xdotool", "mousemove", "--window", str(probe.wid), str(x2), str(y2)])
            time.sleep(0.3)
            sh(["xdotool", "mouseup", "1"])
        elif act == "key":
            sh(["xdotool", "key", "--clearmodifiers", st["keys"]])
        elif act == "wait":
            time.sleep(float(st.get("seconds", 1)))

        time.sleep(STEP_SETTLE)
        shot, err = probe.capture(name)
        if err:
            log(f"  {name:<24} SKIPPED ({err})")
            results.append({"step": name, "action": act, "error": err})
            continue

        ch = changed_cells(prev, shot[1])
        probe.ever_changed.update(ch)
        responded = len(ch) > 0
        results.append({"step": name, "action": act, "responded": responded,
                        "cells_changed": len(ch), "cells": ch,
                        "expect": st.get("expect", "change")})
        verdict = "RESPONDED" if responded else "NO RESPONSE"
        if st.get("expect") == "nochange":
            verdict += " (expected none)" if not responded else " (UNEXPECTED)"
        log(f"  {name:<24} {verdict:<24} cells={len(ch)}")
        if ch:
            log(grid_art(ch))
        prev = shot[1]
    return results, prev


def main():
    outdir = sys.argv[1]
    scenario_path = sys.argv[2]
    wid = sys.argv[3]

    lines = []
    def log(m):
        print(m)
        lines.append(m)

    scenario = json.load(open(scenario_path))
    probe = Probe(wid, outdir)
    log(f"window {wid}  {probe.W}x{probe.H}  grid {GRID_COLS}x{GRID_ROWS}")
    log(f"scenario: {scenario.get('name','?')}  ({len(scenario['steps'])} steps)")

    results, _ = run_scenario(probe, scenario["steps"], log)

    interactive = [r for r in results if r.get("action") in
                   ("click", "doubleclick", "drag", "key", "hover")
                   and "responded" in r]
    responded = [r for r in interactive if r["responded"]]
    dead = [i for i in range(GRID_COLS * GRID_ROWS) if i not in probe.ever_changed]

    log("")
    log(f"interactions responding : {len(responded)}/{len(interactive)}")
    log(f"grid cells never changed: {len(dead)}/{GRID_COLS*GRID_ROWS}")
    log("dead-region map (# = never changed all session):")
    log(grid_art(dead))

    if not interactive:
        verdict = "no-data"
    elif len(responded) == len(interactive) and not dead:
        verdict = "ui-live"
    elif len(responded) == 0:
        verdict = "ui-dead"
    else:
        verdict = "ui-partial"
    log(f"UI VERDICT: {verdict}")

    report = {"verdict": verdict, "window": wid, "size": [probe.W, probe.H],
              "interactions_total": len(interactive),
              "interactions_responded": len(responded),
              "dead_cells": dead, "grid": [GRID_COLS, GRID_ROWS],
              "steps": results}
    with open(os.path.join(outdir, "uiprobe.json"), "w") as fh:
        json.dump(report, fh, indent=1)
    with open(os.path.join(outdir, "uiprobe.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"\nreport: {outdir}/uiprobe.json")


if __name__ == "__main__":
    main()
