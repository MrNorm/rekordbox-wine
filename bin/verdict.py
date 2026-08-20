#!/usr/bin/env python3
"""Adjudicate a run. Turns 'a GUI did something' into a comparable verdict.

The taxonomy maps onto the published failure modes so our results are directly
comparable with the two 2026 AppDB reports:
  no-window     process lives, never maps a window
  blank-window  window maps but renders uniform fill   (AppDB 7.2.8, Dec 2025)
  no-input      window renders, keystrokes not echoed  (AppDB 7.2.14, Jun 2026)
  stale-surface window renders ONE frame, accepts input, never presents again
  window-ok     window renders AND accepts input       -> past Gate 1, new ground

`stale-surface` was added on 2026-08-13 after run 20260813T062048 recovered a
token from a field that run 20260812T201002 had adjudicated `no-input`. On
screen the two are identical; they are told apart only by reading the text back
out of the app. Anything that looks like `no-input` must be checked against it
before it is believed, here or in the published AppDB reports.
"""
import json
import os
import sys

BLANK_STDDEV = 0.02   # greyscale stddev below this == uniform fill. Tune with evidence.


def load(p, default=None):
    try:
        with open(p) as fh:
            return json.load(fh)
    except Exception:
        return default if default is not None else {}


def main():
    R = sys.argv[1]
    input_echoed = sys.argv[2] if len(sys.argv) > 2 else "skipped"
    rc = sys.argv[3] if len(sys.argv) > 3 else "?"
    index_mode = "--index" in sys.argv

    manifest = load(os.path.join(R, "manifest.json"))
    cls = load(os.path.join(R, "classify.json"))

    rows = []
    tl = os.path.join(R, "timeline.tsv")
    if os.path.exists(tl):
        for line in open(tl):
            f = line.rstrip("\n").split("\t")
            if len(f) >= 5:
                rows.append({
                    "t": int(f[0]), "wid": f[1], "exited": f[2] == "1",
                    "stddev": float(f[3].split()[0]) if f[3].split() else 0.0,
                    "text": f[4] if len(f) > 4 else "",
                    "method": f[5] if len(f) > 5 else "unknown",
                })

    saw_window = any(r["wid"] != "-" for r in rows)
    last = rows[-1] if rows else None

    # Only samples that isolate the window can decide "blank". An uncropped
    # full-screen grab measures the whole desktop, so its stddev is high no
    # matter what the app is doing and would mask a genuinely blank window.
    trusted = [r for r in rows if r["method"] in
               ("spectacle-active", "spectacle-full-cropped")]
    peak_stddev = max((r["stddev"] for r in trusted), default=0.0)
    blank_decidable = bool(trusted)
    exited_early = bool(last and last["exited"])
    cats = cls.get("categories", {})
    crashed = any(k in cats for k in ("unhandled_exception", "fastfail", "access_violation"))

    if not rows:
        verdict, headline = "no-data", "harness captured nothing — check wine.log"
    elif not saw_window and exited_early:
        verdict, headline = "early-exit", f"process exited before mapping a window (rc={rc})"
    elif not saw_window:
        verdict, headline = "no-window", "process alive but never mapped a window"
    elif not blank_decidable:
        verdict, headline = "indeterminate", ("window seen but never isolated in a capture "
                                              "(only uncropped full-screen grabs) — cannot judge blankness")
    elif peak_stddev < BLANK_STDDEV:
        verdict, headline = "blank-window", f"window mapped but uniform (stddev {peak_stddev:.4f}) — matches AppDB 7.2.8"
    elif input_echoed == "accepted-not-echoed":
        verdict, headline = "stale-surface", ("window renders one frame and accepts input, but never "
                                              "presents again — input is FINE; presentation is the fault")
    elif input_echoed == "no":
        verdict, headline = "no-input", "window renders, keystrokes not echoed — matches AppDB 7.2.14"
    elif input_echoed == "yes":
        verdict, headline = "window-ok", "window renders AND accepts input — past Gate 1"
    else:
        verdict, headline = "window-rendered", f"window renders (stddev {peak_stddev:.4f}); input probe skipped"

    if crashed and verdict not in ("window-ok", "stale-surface"):
        headline += "; log shows " + ",".join(k for k in cats if k in
                    ("unhandled_exception", "fastfail", "access_violation"))

    out = {
        "run_id": manifest.get("run_id", os.path.basename(R)),
        "recipe": manifest.get("recipe"),
        "driver": manifest.get("driver"),
        "wine_version": manifest.get("wine_version"),
        "winedebug": manifest.get("winedebug"),
        "verdict": verdict,
        "headline": headline,
        "peak_stddev": round(peak_stddev, 5),
        "capture_methods": sorted({r["method"] for r in rows}),
        "blank_decidable": blank_decidable,
        "saw_window": saw_window,
        "input_echoed": input_echoed,
        "exit_rc": rc,
        "failure_categories": cats,
        "surface_tells": {k: v for k, v in cls.get("surface_tells", {}).items() if v},
        "log_lines": cls.get("log_lines", 0),
        "samples": len(rows),
    }

    if index_mode:
        print(json.dumps(out))
        return

    with open(os.path.join(R, "verdict.json"), "w") as fh:
        json.dump(out, fh, indent=1)

    lines = [
        f"VERDICT   {verdict}",
        f"          {headline}",
        f"recipe    {out['recipe']} / driver {out['driver']} / {out['wine_version']}",
        f"window    seen={saw_window}  peak-stddev={peak_stddev:.4f}  input-echoed={input_echoed}",
        f"capture   {', '.join(out['capture_methods'])}" + ("" if blank_decidable else "   << window never isolated; blankness undecidable"),
        f"log       {out['log_lines']} lines" + (f"  categories: {', '.join(cats)}" if cats else ""),
    ]
    for k, v in out["surface_tells"].items():
        lines.append(f"surface   {k}: {', '.join(v[:4])}")
    if last and last["text"].strip():
        lines.append(f"ocr       {last['text'][:110]}")
    txt = "\n".join(lines) + "\n"
    with open(os.path.join(R, "verdict.txt"), "w") as fh:
        fh.write(txt)
    sys.stdout.write(txt)


if __name__ == "__main__":
    main()
