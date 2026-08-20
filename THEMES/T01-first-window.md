# T01 — The first-window blocker

**Status:** **RESOLVED — root cause proven, patch written** · **Opened:** 2026-08-12 · **Closed:** 2026-08-13 · **Gate 1: PASSED**

## Symptom

rekordbox 7.2.x has never been reported to reach its main window under Wine, by
anyone. Two independent published observations, on different GPU vendors:

| Source | Version | Wine | Observation |
|---|---|---|---|
| AppDB iId=43369 | 7.2.14 | 11.8 (Fedora 44) | Sign-in text boxes accept **no keystrokes**. Disabling `winewayland.drv` to force X11 changes nothing. |
| AppDB iId=43000 | 7.2.8 | main (Dec 2025) | Sign-in **is accepted**; main window then opens blank grey and the process dies after an "Importing…" dialog. |
| WineHQ forum | 7.2.x | — | Jan–Feb 2026 thread: login form does not repaint as you type. |

Best result ever recorded on any version: **6.8.4 at Silver on Wine 9.8-staging**
(May 2024), with a residual unexplained startup crash the reporter says to ignore.

## Why this is worth attacking

- No Bugzilla report exists for it. No Wine developer has ever looked.
- No published result exists on an **Intel iGPU** for any rekordbox version — every
  datapoint is Nvidia or AMD. Our hardware is genuinely new ground.
- The two symptoms are machine-detectable, so the variant matrix can run unattended.

## Hypotheses

| # | Hypothesis | Status | Discriminating test |
|---|---|---|---|
| H1 | Embedded-browser surface (CEF/WebView2) failing to composite | **DISPROVEN** (run `…201002`) | `surface_tells.embedded_browser` is empty across 99 loaded modules. No libcef, no WebView2, no chrome_elf. The dossier's Chromium premise is wrong. |
| H2 | Plain Win32 surface | **REFINED** (run `…061437`) | Not plain Win32 and not a browser: the sign-in window is **JUCE**. Class `JUCE_19ff98b3885`, title `ActivationEmailWindow`, with `d2d1.dll` + `DWrite.dll` loaded — i.e. JUCE's Direct2D renderer. JUCE draws its own controls, so there are no child `EDIT` windows. |
| H3 | X11-driver-specific (winex11 path) | untested | `--driver wayland` vs `x11`. NOTE: wayland rows cannot be typed into (T00 limitation) so they can only test *rendering*, not input. |
| H4 | Input focus/IME routing, not rendering | **DISPROVEN** (run `…062048`) | Keystrokes reach the field. Typed blind and recovered verbatim via Ctrl+A/Ctrl+C. Input was never the problem. |
| H5 | GPU/driver specific to Iris Xe / Mesa 26.1.6 | untested, now central | The fault is presentation, so a GPU/driver path explanation is back in scope — but for *presentation*, not for input. |
| H6 | Regression between staging 9.8 and 11.15 | untested | Needs the 6.8.7 baseline first. |
| **H7** | **The window presents exactly one frame and never presents again** | **CONFIRMED** | See "The one-frame surface" below. |
| **H8** | **JUCE 8's vblank thread spins on a failing `WaitForVBlank` and never dispatches a repaint** | **PROVEN BY CONSTRUCTION** (run `…071026`) | Implementing `WaitForVBlank` in `dlls/dxgi/output.c` turns `stale-surface` into `window-ok`. Controlled against the same DLL unpatched through the identical load path. |

### The one-frame surface — the 2026-08-13 result

**`no-input` was wrong, and so, probably, is AppDB 7.2.14.** The keystrokes were
in the text field the entire time. They were never drawn.

The discriminator that settled it (run `20260813T062048-rb7-clipread`) ignores
the screen completely. JUCE's `TextEditor` implements Ctrl+A/Ctrl+C, and Wine
bridges its clipboard to the KDE selection, so the field can be read back *out
of the app*:

    clipboard primed with sentinel ('SENTINEL-rekordbox-92159')
    typed 'ZZTOKENZZ' blind into the email field
    clipboard NOW = 'ZZTOKENZZ'

The sentinel proves the clipboard was actually rewritten rather than holding
stale text, and the same sequence against `wine notepad` in the same run (C3)
proves the read-back path works, so a negative would have meant something.

Every earlier observation now falls into place under H7 — one frame, then
nothing, forever:

| Observation | Run |
|---|---|
| First frame is *perfect*: 682×562, legible, stddev 0.1179 | `…201002` |
| 8 captures over 105 s are **byte-identical** | `…201002` |
| Typing changes nothing on screen | `…060402` |
| Minimise + restore changes nothing | `…060644` |
| Occlude + re-expose changes nothing | `…060644` |
| Hovering and press-and-holding a button changes nothing | `…060923` |
| **Clicking Cancel destroys the window and exits the process** | `…061225` |
| Clicking dead space does *not* (control — so Cancel proves delivery) | `…061225` |
| Wine posts `WM_CHAR` to the JUCE hwnd | `…061225` |
| Typed text recovered from the field via clipboard | `…062048` |

Wine's keyboard path is intact end to end:

    KeyPress keysym=4b (K) -> vkey 0x4B -> send_keyboard_input hwnd 0x1007e
    NtUserTranslateMessage 1 -> PostMessageW(0x1007e,WM_CHAR,<x>,00250001) for L"K"

and `0x1007e` is `ActivationEmailWindow` itself, so for a JUCE app that is the
*correct* destination, not a misroute.

**Mechanism: see Root cause below (H8).** The first guess here — that D2D
presents were being dropped — was wrong, and disabling Direct2D outright
(`20260813T064144`) disproved it. The repaints are never *requested* at all.

Two tests that could not be run, recorded so nobody repeats them:
- **Resize to force a relayout** — the window is fixed-size; `xdotool
  windowsize` is refused and it stays 682×562, so identical pixels prove
  nothing. Run `…061855` is void for this reason.
- **Click [Log in] and watch for a validation dialog** (run `…061651`) — nothing
  happened, but the button is drawn greyed/disabled, so the click is ambiguous
  and it does not bear on H7 either way.

### Probe caveat — read before trusting `no-input`

**Superseded 2026-08-13 — the caveat was justified and the verdict was wrong.**
Kept for the record. What follows describes the fault as it stood before the
clipboard read-back existed.

The harness probe does `windowactivate` → `Tab` → `type`. It does **not** click
into a field. That was sufficient for notepad, where the whole window is a text
control, but a login dialog may not focus an input on `Tab` alone. So the
verdict is currently *consistent with* AppDB 7.2.14 but does not yet exclude the
duller explanation that we simply never focused a field.

Method C from the T00 input testing (click at a point inside the window, then
XTEST type) is proven to work and is the discriminator. **Run that before
reporting this upstream.**

## Evidence log

_(one row per run that moved a hypothesis; run ids are the citation)_

| Date | Run | Change | Verdict | Moves |
|---|---|---|---|---|
| 2026-08-12 | `20260812T201002-rb7-baseline-x11` | first baseline: 7.2.17, wine-staging 11.15, x11, Iris Xe | `no-input` **(WRONG — retracted 2026-08-13)** | H1 disproven, H2 supported, H4 leading |
| 2026-08-13 | `20260813T060402-rb7-clickprobe` | click into the email field, then type (method C) | not echoed | kills the "our probe never focused a field" explanation |
| 2026-08-13 | `20260813T060644-rb7-repaint` | minimise/restore, ±1px resize, occlude/expose | all byte-identical | first sign the surface never updates |
| 2026-08-13 | `20260813T060923-rb7-repaint2` | hover/press a button; click Cancel; notepad capture control | window destroyed by Cancel | mouse input IS delivered; capture path is fresh |
| 2026-08-13 | `20260813T061225-rb7-keytrace` | `WINEDEBUG=+key`; dead-space click as control | Cancel exits, dead space doesn't | Wine posts `WM_CHAR`; click delivery now controlled |
| 2026-08-13 | `20260813T061437-rb7-hwndmap` | `WINEDEBUG=+key,+win` | — | target hwnd is JUCE `ActivationEmailWindow`; H2 refined |
| 2026-08-13 | `20260813T061651-rb7-blindlogin` | blind throwaway login, click [Log in] | no new window | inconclusive — button is disabled |
| 2026-08-13 | `20260813T061855-rb7-resizepaint` | resize to force relayout | **void** | window is fixed-size, cannot be resized |
| 2026-08-13 | `20260813T062048-rb7-clipread` | type blind, Ctrl+A/Ctrl+C, read clipboard | **token recovered** | **H4 disproven, H7 leading, `no-input` retracted** |
| 2026-08-13 | `20260813T062324-rb7-stale-surface-confirm` | rerun through the fixed harness | `stale-surface` | the finding now reproduces automatically |
| 2026-08-13 | `20260813T064144-rb7-no-d2d` | `WINEDLLOVERRIDES=d2d1=d` — force JUCE's software renderer | `stale-surface` | **rules out Wine's Direct2D path**; fault is upstream of the renderer |
| 2026-08-13 | `20260813T064405-rb7-paintmsg` | `+msg,+win`, sliced around idle/click/keystroke | — | **zero `WM_PAINT` ever** -> repaints are never requested |
| 2026-08-13 | `20260813T065355-rb7-vblankcount` | `+dxgi,+dwmapi` to count real call rates | — | **8,615 `WaitForVBlank` calls in 10 s** — the thread spins, it did not die. Corrects the "called once" error. |

**Detail for that run.** Window `682x562` maps within 15 s and is stable for the
full 120 s — no crash, no exit. Peak stddev 0.1179, an order of magnitude above
the 0.02 blank threshold, and OCR reads the sign-in copy verbatim: *"In order to
use rekordbox, you need to create and log in to rekordbox. If you have a
AlphaTheta ac…"*. So this is **not** the AppDB 7.2.8 blank-grey mode.

Log: 960,172 lines, 99 modules. **Zero real exceptions** — no `Unhandled
exception`, no `err:seh`. The only genuine errors are 4 × `err:ole:com_get_class_object
class {aa509086-5ca9-4c25-8f95-589d3c07b48a} not registered`. That unregistered
COM class is the single most interesting lead in the log and is unexamined.

Top fixmes are suggestive for an input-routing hypothesis:
`msg:ChangeWindowMessageFilterEx ×27`, `combase:RoGetActivationFactory ×9`,
`win:RegisterTouchWindow ×9`, `win:RegisterSuspendResumeNotification ×9`,
`system:EnableNonClientDpiScaling ×9`.

Also noted for T02: `setupapi.dll`, `mountmgr.sys` and `cfgmgr32.dll` all load.

## Root cause

**PROVEN. `IDXGIOutput::WaitForVBlank` is a stub in Wine (`return E_NOTIMPL`).
JUCE 8 drives every repaint from a VBlank listener built on that call. Because
the call fails instantly instead of blocking until the next refresh, the vblank
thread spins at ~860 Hz and never dispatches a tick, so nothing is ever told to
repaint. The window paints once at creation and never again.**

Implementing the call fixes it outright — see "Proof by construction" below.

JUCE 8 does not repaint from `WM_PAINT`. It attaches a `VBlankAttachment` and
repaints on that callback. Confirmed here — run `20260813T064405-rb7-paintmsg`
sliced the `+msg` trace around each stimulus:

| slice | WM_PAINT | invalidate | notes |
|---|---|---|---|
| 5 s idle | **0** | 0 | 942 lines of other traffic |
| click | **0** | 9 | |
| one keystroke | **0** | 0 | `WM_USER ×240`, `WM_SYSTIMER ×28`, `WM_CHAR ×4` |

So the message pump is alive and busy; nothing ever asks the window to redraw.

Both of JUCE's vblank sources are stubbed:

    fixme:dxgi:dxgi_output_WaitForVBlank iface 0000000003679410 stub!
    fixme:dwmapi:DwmGetCompositionTimingInfo (0000000000000000 00000000083CED60)

**Correction, run `20260813T065355-rb7-vblankcount`.** An earlier version of this
file said each was "called exactly once". That was wrong, and wrong for an
avoidable reason: Wine logs both behind a once-guard —

    if (!once++) FIXME("iface %p stub!\n", iface); else TRACE("iface %p stub!\n", iface);

— so at default debug levels a million calls are indistinguishable from one.
Re-run with `+dxgi,+dwmapi` and the real numbers appear:

| | measured |
|---|---|
| `WaitForVBlank` calls in 10 s idle | **8,615** (~860/s) |
| `DwmGetCompositionTimingInfo` calls, whole run | 1 |
| `DwmFlush` calls | 0 |

So the vblank thread is not dead — it is **spinning**. `WaitForVBlank` returns
`E_NOTIMPL` immediately instead of blocking until the next refresh, so the loop
free-runs at ~860 Hz, and because the call *failed* it never dispatches the
vblank event to its listeners. Nobody is ever told to repaint.

Upstream state, checked against wine-mirror master on 2026-08-13:

- `dxgi_output_WaitForVBlank` (`dlls/dxgi/output.c`) — pure stub, `return E_NOTIMPL`.
  **Not fixed in master**, so there is no Wine version to upgrade to.
- `DwmGetCompositionTimingInfo` (`dlls/dwmapi/dwmapi_main.c`) — *not* a stub
  despite its FIXME: it fills `rateRefresh`, `qpcRefreshPeriod` and `qpcVBlank`
  from the real display frequency and QPC, and returns `S_OK`. JUCE calls it
  once and does not use it as a clock.

Per the JUCE forum, JUCE's `D3DVsyncSource::VBlankLoop` is supposed to fall back
to `DwmFlush` when the DXGI wait fails. It never does here — `DwmFlush` is called
zero times — which is worth understanding, because that fallback firing would
likely have masked the bug entirely.

This accounts for **every** observation, including two that nothing else does:

- The first frame is perfect because it is painted synchronously during window
  creation, before any vblank is needed.
- Disabling Direct2D changes nothing (run `20260813T064144`, `d2d1` absent from
  the log, override recorded in the manifest) because `VBlankAttachment` is
  renderer-independent in JUCE 8 — the software renderer is starved identically.

**Implication, and it is a big one.** This is not GPU-specific and not
Iris-Xe-specific. It should affect *every JUCE 8 application under Wine on any
hardware* — which is exactly why the AppDB reports on Nvidia and on AMD describe
the identical symptom. The GPU-vendor angle we started with was a red herring.

### Proof by construction — 2026-08-13

`dlls/dxgi/output.c` was patched to sleep to the next estimated refresh boundary
instead of returning `E_NOTIMPL` (refresh rate from `EnumDisplaySettingsW`,
period from QPC; ~30 lines, in `upstream/0001-dxgi-implement-WaitForVBlank.patch`).
Only `dxgi.dll` was rebuilt, from the wine 11.15 tree with clang/lld.

**One variable.** Both DLLs are our own build, both loaded through the identical
path, differing only in that patch:

| dxgi build | load path | verdict |
|---|---|---|
| unpatched | native, marker stripped | `stale-surface` (run `…071216`) |
| **patched** | identical | **`window-ok`** (run `…071026`) |

In the patched run the probe token `RBWPROBE1426` is **visibly rendered in the
email field**, shot-to-shot RMSE is non-zero for the first time in the whole
investigation (0.0213 where every prior comparison was exactly 0), and the
harness reports "keystrokes accepted and echoed".

**Getting the patched DLL loaded took a detour worth recording.** Wine resolves
builtin PE modules from its own dll directory, *not* from the prefix, so
dropping the file into `system32` is silently ignored — the first "control" run
was still executing the stock DLL and proved nothing. `WINEDLLPATH` does not
help either. What works without root: rewrite the `"Wine builtin DLL"` marker
that `winebuild` stamps into the image (same length, so no offsets move), which
makes the loader accept it under `WINEDLLOVERRIDES=dxgi=n`. The patch adds a
distinctive `RBW-PATCH` FIXME purely so the log proves *which* file is live —
without that marker every result here would have been uninterpretable.

**Scope of the fix.** Nothing in this is rekordbox-specific. Any JUCE 8
application driving repaints from `VBlankAttachment` is affected on any GPU,
which is why the AppDB reports on Nvidia and on AMD describe an identical
symptom. The Intel-iGPU premise the project opened on was a red herring.

## Fix / workaround

No workaround yet; `d2d1=d` was tried and does not help. The app is nonetheless
more usable than it looks — it responds to clicks and accepts typing, blind.

If the vblank diagnosis holds, the fix is a Wine patch rather than a prefix
setting, which is a better outcome for everyone than a winecfg tweak.

## Upstream

This is now a much better bug report than we expected to have: a *misdiagnosis*
in the published record, with a reproducible discriminator that anyone can run.

- [ ] Bugzilla report filed — **draft, patch and standalone reproducer all ready
      in `upstream/`**, not yet submitted. Blocked only on a manual duplicate
      search: bugs.winehq.org is behind Anubis and refuses automated fetches.
- [ ] Correct the AppDB 7.2.14 entry: "text boxes accept no keystrokes" is very
      likely this same illusion. The reporter could not have known — the field
      looks dead unless you read it back out of the app.
- [ ] AppDB test report for 7.2.17 on wine-staging 11.15 / Intel Iris Xe — drafted
      in `upstream/appdb-rekordbox-7217.md`, needs a logged-in account to post
- [ ] AppDB correction to iId=43369 ("accepts no keystrokes" is this bug seen
      from outside) — drafted in the same file
- [ ] AppDB test report for 6.8.7 on wine-staging 11.15 / Intel Iris Xe

## Open UI issue, post-fix

**Menus do not open reliably.** Clicking `File` in the top bar often shows
nothing; currently unusable (human observation 2026-08-13, no run id). Not
investigated. Worth checking whether JUCE popup menus are separate top-level
windows that hit the same vblank-driven repaint path — if so this is the same
root cause surfacing somewhere the patch does not reach, rather than a new bug.
A menu that never paints and a menu that never opens look identical.

## 2026-08-14 — vblank clock verified at 60 fps; UI frame rate NOT yet measurable

User reports the waveform rendering as "VERY lumpy, unworkable" and asked for a
frame-rate number.

### The vblank clock is correct

Instrumented `dxgi_output_WaitForVBlank` (patch 0001) to report its achieved
rate. With `RBW_VBLANK_STATS=1`, 53 samples:

    RBW-VBLANK2 rate: 60.0 frames/sec over 120 frames (target 60)
    RBW-VBLANK2 rate: 60.5 frames/sec ...

Rock solid at the display refresh. **My suspicion that `Sleep()`'s whole-
millisecond quantisation was causing the lumpiness is REFUTED** — I added a
precise `NtDelayExecution` path (`RBW_VBLANK_SLEEP=1` selects the old one) and
the OLD path already achieves 60.0 fps. JUCE is getting its ticks on time.

So the lumpiness is downstream of the tick: frames are requested at 60 Hz and
something between there and the screen is not keeping up.

### The frame-rate measurement is NOT valid yet — three instrument faults

1. `ffmpeg -f x11grab` **draws the mouse cursor by default**. Counting
   non-duplicate frames with `mpdecimate` while moving the mouse counts CURSOR
   MOTION. Direct2D and software-renderer runs both returned exactly 101 frames
   — identical to the frame, which is what gave it away.
2. With `-draw_mouse 0` the same capture returns **1 distinct frame in 6 s**:
   the region chosen (library area) does not animate at all, so hovering forces
   no repaint.
3. Nothing on screen animates because **the deck is frozen** — see T03 phase 17.
   There is no continuous motion to measure.

**Therefore: the d2d1-vs-software comparison below is VOID and must not be
cited.** Both "16.8 fps" figures were cursor motion.

### What this blocks on

A frame-rate number needs something animating, and the only continuous animation
in this UI is a playing waveform. **The FPS measurement is blocked on the same
root cause as everything else: playback does not run.** Fix that first, then a
recording of the moving waveform gives a real number in one command:

    ffmpeg -f x11grab -draw_mouse 0 -framerate 60 -video_size <wave region> \
           -i "$DISPLAY+<x>,<y>" -t 6 -vf mpdecimate -fps_mode vfr out.mp4
    ffprobe -select_streams v:0 -count_frames -show_entries stream=nb_read_frames out.mp4

The instrumentation added to `dxgi/output.c` is worth keeping: `RBW_VBLANK_STATS=1`
answers "is the frame clock healthy" in one run, and it is.

### Frame-rate measurement: what worked, what did not, and where it stands

**WORKS — the vblank clock.** `RBW_VBLANK_STATS=1` on the patched dxgi reports a
steady **60.0 frames/sec** against a 60 Hz display, across many samples and in
every configuration tried. The frame *clock* is healthy. Keep this instrument.

**DOES NOT WORK — screen capture on this system.**
`ffmpeg -f x11grab` returns a **black root window** for XWayland clients under
KWin. Verified directly: a single-frame grab of the waveform region, while the
waveform was visibly animating, was uniformly black. Everything x11grab
produced was the cursor ffmpeg draws itself, which is why a Direct2D run and a
software-renderer run returned *identical* counts (101 frames each). **All
ffmpeg-derived frame rates in this theme are void.** For a Wayland/KWin session
the capture must go through the PipeWire portal, not x11grab.

**DOES NOT WORK YET — counting Direct2D frames.**
`d2d_device_context_EndDraw` was instrumented (`RBW_PAINT_STATS=1`) to count real
frame completions with no capture at all. It reports nothing, because the
process keeps loading `/usr/lib/wine/x86_64-windows/d2d1.dll` — the **system
builtin** — even with `d2d1=native` registered and the builtin marker blanked in
the prefix copy. Same class of problem as cfgmgr32 in T06. Until that is
resolved the "zero paint frames" result proves nothing about rendering.

**Next, for whoever picks this up:** get the instrumented d2d1 to actually load
(check KnownDLLs and whether another DLL pulls d2d1 in before the override
applies), then compare `RBW_PAINT_STATS` against `RBW_VBLANK_STATS`. Tick at 60
with paints far below is the definition of the reported lumpiness.
