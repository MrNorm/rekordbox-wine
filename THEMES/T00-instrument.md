# T00 — The instrument itself

**Status:** RESOLVED (validated 2026-08-12) · **Re-verify:** after any Wine, KDE,
ImageMagick or tesseract upgrade, and before trusting any negative verdict.

Not about rekordbox. This theme exists because every bug below would have
produced a *confident wrong answer* about rekordbox, and two of them would have
looked exactly like the failure we are hunting.

## Why a positive control exists at all

An oracle that has never returned `window-ok` is unvalidated, and a negative
result from an unvalidated instrument is worth nothing. `rbw selftest` drives
`winecfg` and `notepad` through the identical run path and asserts the oracle
can return `window-ok`. It must pass before any rekordbox verdict is believed.

## Faults found and fixed

### I1 — X11 capture is unusable under XWayland
`import` (ImageMagick 7.1.2-29) fails outright: *"missing an image filename"*
even given an explicit `-display :0`, with the permissive default policy and the
`x` delegate present. Worse, `ffmpeg -f x11grab` of the XWayland root **succeeds
and returns stddev 0.0 — pure black**, because the root holds no composited
content and X11 toplevels are redirected.

**Impact if unfixed:** every run reports `blank-window`. That is indistinguishable
from the genuine AppDB 7.2.8 symptom we are investigating. We would have "confirmed"
a bug that wasn't there.

**Fix:** capture via `spectacle` (KWin). Asks the compositor what is actually on
screen, so it is also correct for the `winewayland` driver, where no X window
exists and every X-side tool would see nothing.

### I2 — Window discovery matched the wrong pid
The harness backgrounds a subshell, so `$!` is the subshell, while the window's
`_NET_WM_PID` is the wine child. Measured: subshell `70157` vs notepad window pid
`70235`. `xdotool search --pid` therefore never matched, and the fallback searched
for the class `rekordbox`, which no control window has.

**Impact if unfixed:** `no-window` for every run, including healthy ones.

**Fix:** match on `WM_CLASS`, which Wine sets from the exe basename, with a diff
against a pre-launch window snapshot as an app-agnostic backstop.

### I3 — OCR silently returned nothing
Tesseract read **zero characters** from native-resolution captures. The same image
at 3× with sharpening reads cleanly: *"Untitled - Notepad / File Edit Format View
Help"*.

**Impact if unfixed:** every text assertion fails open. This is what made the first
selftest report that synthetic typing was broken — the typing was fine all along
(verified independently: XTEST, XSendEvent and click-then-type all land text in
notepad). One root cause, two apparent failures.

**Fix:** `-colorspace Gray -resize 300% -sharpen 0x1 -normalize` before tesseract.

### I4 — The probe token contained a newline
`date +%s | tail -c 5` retains the trailing newline, which `xdotool type` sends as
Enter. Harmless in notepad, potentially a form submission in a login dialog.

**Fix:** `tr -d '\n'` before truncating.

### I5 — Full-screen fallback was photographing the desktop
With no window found, the capture fell back to a full-screen grab every poll,
storing PNGs and OCR of whatever else was on screen — in the first failed control
run that included browser tab titles and a WhatsApp window title.

**Impact:** a privacy leak that would accumulate silently over a long project, and
useless for adjudication anyway, since a whole-desktop stddev is high regardless
of what the app is doing and would *mask* a genuinely blank window.

**Fix:** full-screen capture is retained only if it can be cropped to the window
rectangle; otherwise it is deleted and the sample is marked `no-window-isolated`.
Uncropped grabs require an explicit `ALLOW_FULLSCREEN_CAPTURE=1`. Only
window-isolated samples may decide blankness; a run with none returns
`indeterminate` rather than a confident wrong answer.

### I6 — The input oracle could not tell "dropped" from "never redrawn"

**The worst one so far, because it produced a wrong verdict that we published to
ourselves and believed for a day.**

The probe typed a token and OCR'd a screenshot. If the token was not on screen,
it recorded `no-input`. But a window that ignores every keystroke and a window
that accepts them and never repaints look *exactly* the same. Run
`20260812T201002` was adjudicated `no-input`; run `20260813T062048` typed a
token blind into that same field and read it straight back out. The keystrokes
had been there all along.

Two compounding faults, both fixed:

1. The probe did `activate → Tab → type` and never clicked, so on a dialog whose
   first control is not a text field it might genuinely have focused nothing.
   It now clicks into the window before typing.
2. OCR was the *only* oracle. There is now an authoritative one that does not
   involve the screen at all: select-all, copy, and read the value back through
   Wine's clipboard bridge (`qdbus6` → klipper), with a sentinel written first
   so a stale clipboard cannot be mistaken for a successful read.

The two oracles together distinguish three states where there used to be two,
and `verdict.py` gained `stale-surface` for the new one:

| accepted | echoed | verdict |
|---|---|---|
| yes | yes | `window-ok` |
| yes | no  | `stale-surface` — input fine, presentation broken |
| no  | no  | `no-input` |

**Generalisable lesson, and the second time this project has been bitten by it:**
every oracle here reads pixels, and pixels are downstream of the exact subsystem
under investigation. When the thing you are measuring is the display, the
display cannot be the only witness. Prefer a channel the bug does not sit on.

## Calibration, measured not assumed

| Control | Verdict | Peak stddev | Input |
|---|---|---|---|
| winecfg | `window-rendered` | 0.46473 | n/a |
| notepad | `window-ok` | 0.41156 | echoed |

`BLANK_STDDEV = 0.02` sits an order of magnitude below both known-good windows,
so it is safe. Before this it was a number invented with no evidence, and a
sparse white window could plausibly have fallen under it.

## Known remaining limitation

Input injection is XTEST, so it is **X11-only**. A `--driver wayland` run can be
captured (spectacle works) but cannot be typed into; those runs must use
`--no-input` and can only ever return `window-rendered`, never `window-ok`.
Closing that needs `ydotool` (uevent daemon) or `kdotool`. Do not read a missing
`window-ok` on a wayland row as an application failure.

## 2026-08-17 (evening) — four more instrument faults, and one of them cost an hour

### 1. `spectacle -a` is NOT a screen capture, and its coordinates are not X coordinates

`spectacle -a -b -n -o file.png` — the form used by `bin/playtest.sh`,
`bin/uiprobe.py`, `bin/meterscope.py` and everything else in this repo that
takes a picture — captures the **active window plus its drop shadow**. For a
1920x1006 window at +0+28 that is a **2050x1164** image, offset by roughly 65 px
horizontally, and the offsets are not the same on both axes.

So a coordinate read off such a capture and handed to `xdotool` lands next to
the control it was aimed at. That is why the deck's play button "would not
respond" for the better part of an hour: every click was ~65 px off, and the app
was behaving perfectly.

    spectacle -f -b -n -o file.png     # full screen, 1920x1080, 1:1 with X

**Rule: coordinates come from `-f` captures. `-a` is for pictures to look at,
never for pictures to measure.** Anything cropping a fixed rectangle out of an
`-a` capture is also cropping a moving target — the shadow size is a compositor
property, not ours.

### 2. A per-thread CPU probe that cannot see threads born mid-window

`bin/threaddiff.py` computed CPU as (jiffies at the end - jiffies at the start),
which reports **0%** for any thread that did not exist at the start. The threads
under investigation are recreated every 15.8 s. Result: "no thread does any audio
work when the fault is present", stated out loud, and refuted minutes later by an
`strace` of one of those threads showing 36,000 ioctls a second. Fixed by
charging each thread over its own observed lifetime.

### 3. A probe whose own cost changes the thing it measures

`WINEDEBUG=+mmdevapi` on this application emits ~200,000 lines a second: an
unfiltered run wrote a **797 MB log in 45 seconds**. Piping it into an aggregator
does not help — the pipe applies backpressure and rekordbox is then throttled by
its own logging, so the timings, the rates and the fault itself are all
distorted. `bin/apitally.py` exists and is useful for RARE calls, but any run of
it is void as evidence about timing. For hot paths, instrument inside Wine and
count, do not log.

### 4. A rate measured across the end of the input

`bin/enginerate.sh` derives playback speed from the track file's read position.
A track that **reaches its end** during the window reads at full speed and then
stops, averaging to a fraction of real time — indistinguishable from a stalled
engine. It scored 0.19x on a perfectly healthy engine once before the guard was
added. It now refuses the run when `pos == file size`.

## Instrument fault — `perf record -e 'syscalls:sys_enter_*'` deadlocked the kernel

**2026-08-19. This one wedged the machine, and it needs a reboot to clear.**

Trying to trace one of the 68 freshly created audio threads from birth
(T10 phase 31), I ran:

    sudo perf record -k mono -e 'syscalls:sys_enter_*' -e sched:sched_process_fork -p <pid>

The glob expands to roughly **400 tracepoints**, and `-p` attaches to every
thread — rekordbox has **196**. That is on the order of **78,000 perf event
descriptors** created at once. It captured 13.4 M samples into a 1.4 GB file and
then never terminated:

    perf   D state   /proc/<pid>/stack:
        perf_event_ctx_lock_nested.isra.0+0x49/0x90
        perf_read+0x90/0x350
        vfs_read / ksys_read / do_syscall_64

A deadlock on perf's own event-context lock, inside `perf_read`. **`SIGKILL`
does not clear a D state**, so neither perf nor its target could be killed:
rekordbox stayed alive at 196 threads and could not be shut down, the DDJ
substream was left in `XRUN` with rekordbox still its owner, and the load
average went to **199**.

Symptoms that were misread first, and cost two further runs:

- `bin/queueburst.py` reported "0 threshold crossings, 0 teardowns" and its
  sample rate collapsed from 60-130 kHz to 2-3 kHz. That reads exactly like *the
  fault stopped*, i.e. like a fix. It was the machine dying.
- `kill -KILL` on rekordbox appeared to do nothing, and a relaunch returned the
  **same pid** — which reads like "the launch failed" rather than "the old
  process cannot die".

### Rules that follow

1. **Never use a tracepoint glob with `perf` on this process.** Name the handful
   of events you need. Every focused run in this project (`hrtimer_start`,
   `sched_switch`, `sys_enter_ioctl`, `sys_enter_futex`, `cycles`) was fine —
   0.7 MB to 850 MB, clean termination.
2. **Bound it**: a 196-thread target multiplies every event you ask for. Check
   `events x threads` before recording.
3. **Run `perf` in the foreground** and wait for its "Captured and wrote" line.
   The first, wedged run was backgrounded in a subshell, so its `timeout -s INT`
   never reached it and nothing noticed for ten minutes.
4. **A collapsing probe sample-rate is a machine-health signal, not a result.**
   If `queueburst` drops an order of magnitude, stop and check the load average
   and for stuck processes before interpreting anything.
5. Check `ps -eo pid,stat,comm | grep perf` after any perf work. A `D` there is
   a reboot.

---

## `deckrate` is a shape detector, not a rate meter — 2026-08-20

`bin/deckrate.sh` answers "did the readout pixels change since the last
screenshot". That is a *sampling* question, and it inherits every source of
capture jitter: a full-screen grab that lands late, or twice inside the same
tenth of a second, scores a miss the engine never made.

On configurations independently measured healthy — 0 teardowns, continuous audio
at the wire — it has returned:

    1.00  1.00  1.00  1.00  1.00  1.00  0.97  0.96  0.95  0.91  0.87  0.84  0.74

**A single sub-1.0 deckrate reading is therefore not evidence of anything.** It
also saturates at 1.0 and cannot distinguish 1.0x from 1.2x, so it cannot
confirm real-time playback either — only rule out the gross stall it was built
to catch (0.05x, which is what the PC MASTER OUT defect looked like).

This matters because `GOLD-STATUS.md` cited "1.00x" from this instrument as
proof the engine keeps real time. That claim was **over-stated for the
instrument that produced it** and has been corrected.

### The replacement: `bin/deckclock.sh`

Two OCR reads of the deck's elapsed-time readout, start and end, divided by wall
clock. Jitter in either read costs one tenth of a second across the whole window
rather than one sample in a hundred, and it can report above 1.0.

    deck 17.7s -> 138.2s = 120.5s of audio in 120.5s of wall clock = 1.000x

Two traps found while building it, both of which returned a confident wrong
answer rather than an error:

- **The panel shows two clocks.** Remaining first, with a leading minus, then
  elapsed. Reading the first match reads the countdown, whose delta is negative
  for a *healthy* deck. Take the second.
- **Every global threshold binarised the readout to a solid block** that
  tesseract read as zero characters — the same fail-open shape as the original
  OCR fault recorded above. A local adaptive threshold (`-lat 25x25-10%`) reads
  it exactly.

### And a harness trap, three times in one session

`bin/soak.sh <secs> <row>` takes a **library row**, and row 5 in the test
collection is "House 1" — a **one-second** sample. The soak dutifully reported
`0 of 155 samples = 0.00 of real time -> THE ENGINE IS STALLED`, which is the
signature of the worst bug this project has hunted. A screenshot of the window
showed a healthy application with a one-second track at its end.

The rule already recorded here — *screenshot the whole window before believing a
run of zeros* — held. It is now cheap to obey and it should be obeyed every time.

### `pgrep -f` matches the shell that runs it

Three separate commands this session died at exit 144 because a `pgrep -f`
or `pkill -f` pattern matched the command line of the very shell evaluating it,
and one `until ! pgrep -f 'bin/soak.sh'` wait-loop matched *itself* and could
never terminate — which then reported a finished soak as still running.
Use a bracket to break the self-match (`pgrep -f 'soak[.]sh'`), or kill by PID.
