#!/usr/bin/env python3
"""uiassert — assert the enabled/disabled state of named rekordbox UI controls.

WHY THIS EXISTS
---------------
The project's milestone is "the DDJ-400 is bound", and the user-confirmed tell
is visual: the MIDI indicator stops being greyed out, and the MIX and LEVEL
controls above the library go live. Until now that was checked by a human
looking at the screen, which meant it was checked rarely and never as part of a
regression run. A whole session was spent breaking a working feature without
noticing, because nothing automatically re-checked it.

So this turns "is that control greyed out" into an exit code.

HOW IT DECIDES
--------------
A disabled control in rekordbox's dark skin is dark-grey glyphs on near-black.
An enabled one is bright glyphs on the same near-black. The discriminating
signal is therefore the PEAK brightness inside the region, not the mean: the
mean is dominated by background in both cases, while the peak tracks the
glyphs. Standard deviation is reported too, since a region with no glyphs at
all (control missing entirely, not merely disabled) has both low peak and low
spread, and that is a different failure worth telling apart.

Thresholds are calibrated PER SCREENSHOT against two reference regions -- a
label that is always enabled, and a patch of empty background. Absolute
thresholds rot the moment the skin, compositor, or display profile changes, and
this project has already been burned by an oracle that silently started
returning black frames.

USAGE
    bin/uiassert.py --shot runs/X/main.png                 report all regions
    bin/uiassert.py --shot X.png --expect baseline         assert baseline states
    bin/uiassert.py --shot X.png --expect milestone        assert the MIDI milestone
    bin/uiassert.py --capture --expect baseline            capture, then assert
    bin/uiassert.py --shot X.png --block audio_prefs --json    grade another window

BLOCKS
    By default the reference/region definitions are read from the top level of
    regions.json, which describes the MAIN rekordbox window. `--block NAME`
    reads them from regions.json[NAME] instead, so a second window with its own
    coordinate frame -- the Preferences dialog, say -- can be graded by the same
    calibrated measurement code instead of a parallel copy of it.

Exit: 0 all assertions held, 1 an assertion failed, 2 harness fault
(no window, capture failed, image unreadable) -- deliberately distinct, because
"the test could not run" must never be mistaken for "the test passed".
"""

import argparse
import re
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGIONS = os.path.join(HERE, "scenarios", "regions.json")


def sh(cmd, timeout=60):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def fault(msg):
    print(f"HARNESS FAULT: {msg}", file=sys.stderr)
    sys.exit(2)


def find_window():
    r = sh(["xdotool", "search", "--name", "^rekordbox$"])
    ids = [x for x in r.stdout.split() if x.strip()]
    return ids[0] if ids else None


def capture(path):
    wid = find_window()
    if not wid:
        fault("no window named 'rekordbox' -- is it running?")
    sh(["xdotool", "windowactivate", wid])
    sh(["sleep", "1.5"])
    # Spectacle, not import/xwd: measured 2026-08-12, ImageMagick's `import`
    # returns pure black under this compositor, which would fake a pass.
    r = sh(["timeout", "25", "spectacle", "-a", "-b", "-n", "-o", path], timeout=45)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        fault(f"spectacle produced nothing at {path} (rc={r.returncode})")
    return path


def geometry(png):
    r = sh(["identify", "-format", "%w %h", png])
    if r.returncode != 0:
        fault(f"cannot read {png}: {r.stderr.strip()}")
    w, h = r.stdout.split()
    return int(w), int(h)


PIXEL_RE = re.compile(r"^\d+,\d+:\s*\((\d+)")


def measure(png, W, H, spec):
    """Peak/mean/spread brightness of one fractional region, 0..1.

    Reads actual pixels via `txt:` rather than `-format %[fx:maxima]`. The fx
    route silently reports statistics of the *whole* image regardless of the
    preceding -crop (measured: a pure-black region came back peak=1.000,
    mean=0.500, sd=0.000), which would have made every assertion here
    meaningless while looking perfectly plausible.
    """
    x = int(spec["x"] * W)
    y = int(spec["y"] * H)
    w = max(1, int(spec["w"] * W))
    h = max(1, int(spec["h"] * H))
    r = sh([
        "magick", png, "-crop", f"{w}x{h}+{x}+{y}", "+repage",
        "-colorspace", "Gray", "-depth", "8", "txt:-",
    ])
    if r.returncode != 0:
        fault(f"magick failed on region {x},{y} {w}x{h}: {r.stderr.strip()}")

    vals = [int(m.group(1)) for m in
            (PIXEL_RE.match(ln) for ln in r.stdout.splitlines()) if m]
    if not vals:
        fault(f"no pixels parsed from region {w}x{h}+{x}+{y}")

    n = len(vals)
    mean = sum(vals) / n
    sd = (sum((v - mean) ** 2 for v in vals) / n) ** 0.5
    return {
        "peak": max(vals) / 255.0,
        "mean": mean / 255.0,
        "sd": sd / 255.0,
        "box": f"{w}x{h}+{x}+{y}",
        "n": n,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shot")
    ap.add_argument("--capture", action="store_true")
    ap.add_argument("--expect", help="name of the per-region expectation key to "
                                     "assert (e.g. baseline, milestone, populated)")
    ap.add_argument("--block", help="grade regions.json[BLOCK] instead of the "
                                    "top-level main-window definitions")
    ap.add_argument("--regions", default=REGIONS)
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    if not args.shot and not args.capture:
        ap.error("need --shot or --capture")

    shot = args.shot or os.path.join(HERE, "runs", "uiassert-latest.png")
    if args.capture:
        os.makedirs(os.path.dirname(shot), exist_ok=True)
        capture(shot)
    if not os.path.exists(shot):
        fault(f"no such screenshot: {shot}")

    cfg = json.load(open(args.regions))
    if args.block:
        if args.block not in cfg:
            fault(f"no block '{args.block}' in {args.regions}")
        cfg = cfg[args.block]
    W, H = geometry(shot)

    # --- calibrate against the reference regions -------------------------
    ref = cfg["reference"]
    bright = measure(shot, W, H, ref["bright_text"])
    dark = measure(shot, W, H, ref["dark_background"])

    # A screenshot where the always-enabled label is not clearly brighter than
    # empty background is not a screenshot of a working UI. Refuse to grade it
    # rather than emit confident nonsense -- this is exactly the failure mode
    # that produced a fake `blank-window` verdict earlier in the project.
    if bright["peak"] - dark["peak"] < 0.20:
        fault(
            f"calibration failed: reference bright_text peak={bright['peak']:.3f} "
            f"vs dark_background peak={dark['peak']:.3f}. The window is probably "
            f"occluded, blank, or the regions are miscalibrated. Refusing to grade."
        )

    # Midpoint between a known-enabled glyph and known-empty background.
    threshold = (bright["peak"] + dark["peak"]) / 2.0

    results = {}
    failures = []
    for name, spec in cfg["regions"].items():
        m = measure(shot, W, H, spec)
        state = "active" if m["peak"] >= threshold else "greyed"
        # No glyphs at all: peak barely above background AND almost no spread.
        if m["peak"] < dark["peak"] + 0.06 and m["sd"] < 0.03:
            state = "absent"
        m["state"] = state
        results[name] = m

        if args.expect:
            want = spec.get(args.expect)
            if want and state != want:
                failures.append((name, want, state, m))

    # --- report ----------------------------------------------------------
    if args.json:
        print(json.dumps({
            "shot": shot, "size": [W, H], "threshold": threshold,
            "reference": {"bright": bright, "dark": dark},
            "regions": results,
            "expect": args.expect,
            "failures": [f[0] for f in failures],
        }, indent=2))
    else:
        print(f"shot {shot}  {W}x{H}  threshold peak>={threshold:.3f} "
              f"(bright={bright['peak']:.3f} dark={dark['peak']:.3f})")
        for name, m in results.items():
            want = cfg["regions"][name].get(args.expect) if args.expect else None
            mark = "" if not want else ("  ok" if m["state"] == want else f"  FAIL want={want}")
            print(f"  {name:<18} {m['state']:<7} peak={m['peak']:.3f} "
                  f"mean={m['mean']:.3f} sd={m['sd']:.3f}{mark}")

    if failures:
        print(f"\n{len(failures)} assertion(s) failed against --expect {args.expect}",
              file=sys.stderr)
        return 1
    if args.expect:
        print(f"\nall regions match --expect {args.expect}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
