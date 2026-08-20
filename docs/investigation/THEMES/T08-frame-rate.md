# T08 — UI frame rate and jitter: measuring it honestly, and what it actually says

**Opened:** 2026-08-14 · **Status:** INSTRUMENT BUILT AND CALIBRATED; baseline established;
degradation-over-time under investigation.
**Owner symptom:** *"over time the UI has become extremely laggy and is no longer usable"*.

Split out of T01 deliberately. T01 is *"the window never repaints at all"*, which is
resolved. This is *"it repaints, but badly"*, which is a different question with a
different instrument and a different answer.

## 1. The instrument, and why the previous ones were void

Every frame-rate number produced in this project before today was invalid:

- `ffmpeg -f x11grab` returns a **black root window** for XWayland clients under KWin.
  The frames it counted were the mouse cursor ffmpeg draws itself. Two runs that
  should have differed came back at *exactly* 101 frames each, which is what exposed
  it. All ffmpeg-derived numbers here remain void (T01:323,352).
- The plan to count `d2d_device_context_EndDraw` calls could never have worked: it was
  aimed at a DLL that is **off this application's frame path** (§3). "Zero paint
  frames" was the correct answer to the wrong question.

**`research/probes/damagefps.c`** counts X DAMAGE events on the rekordbox window. Damage is the
signal the compositor itself uses to know a window repainted; it carries **no pixels**,
so a black capture cannot fool it. It reports the rate *and* the distribution of gaps
between repaints, because a waveform that averages 30 fps by delivering 60,60,4,60,4
is unusable while its mean looks respectable.

### Calibration — it answers both ways

| control | expectation | measured |
|---|---|---|
| `glxgears` (compositor vsync) | ~60 | **60.17 fps**, p50 gap 16.67 ms |
| glxgears' own internal counter | — | **60.505 fps** (independent agreement) |
| a static `xmessage` window | ~0 | **0.20 fps** (one map event, then nothing) |

### Cross-check — an in-process second opinion

`WINEDEBUG=+fps` makes Wine print the application's own present rate from *inside*
the process. Measured in the **same run** as the external instrument:

    damage (external, X server) : 29.70 fps
    wine wglSwapBuffers (in-process) : 29.68 - 29.78 fps

Two independent instruments, one outside the process and one inside it, agreeing to
0.1 fps. Neither reads a pixel; neither can see the cursor.

**Harnesses:** `research/probes/fpsmatrix.sh` (one-variable-at-a-time A/B, with a cleandown and a
config-survived-the-launch check between variants) and `research/probes/uisoak.sh` (long runs,
trend reporting).

## 2. The baseline — the UI is NOT slow in a clean session

| state | fps | p50 gap | p99 gap | max gap | frames dropped |
|---|---|---|---|---|---|
| both decks empty | 29.8 | 33.8 ms | 34.8 ms | 35.3 ms | — |
| **a track loaded on a deck** | **58.1** | **17.4 ms** | **18.0 ms** | **18.3 ms** | **0 in 15 s** |

That is a healthy, smooth application.

**The 30 fps idle figure is rekordbox's own frame limiter, not a Wine fault.** An
`strace` of its GL render thread shows `pselect6` sleeps of 27-32 ms, clustered at
30-31, in whole milliseconds and adaptive to how long the frame took — i.e. a fixed
~33 ms period minus elapsed work. There is **no sleep anywhere in Wine's GL path**
(grepped `dlls/winex11.drv/opengl.c`, `dlls/opengl32/*.c`, `dlls/win32u/opengl.c`:
zero `NtDelayExecution`/`usleep`/`nanosleep`/`Sleep`). The limiter is in the
application.

**Control that settles what 58 fps tracks:** the rate stayed at 58 *after* the
one-second loop sample had finished playing. So 58 fps follows "a deck holds a
track", not "audio is playing".

## 3. What the frame path actually is — two corrections to T01

From the recon workflow (`w5v7znbp5`), measured from RTTI and the PE import table:

- **rekordbox 7.2.17 is JUCE 7.0.9, not JUCE 8**, and contains **no Direct2D
  renderer at all**. `Direct2DLowLevelGraphicsContext` does not exist in the binary.
  The only D2D symbol is `ID2D1SimplifiedGeometrySink` — JUCE's DirectWrite
  glyph-outline sink, used once per process for text measurement.
- The UI is painted by **JUCE's own renderer** — CPU rasterisation of paths and
  glyphs — composited through a **`juce::OpenGLContext`** and presented with
  `wglSwapBuffers` (confirmed live: Wine's `+fps` channel reports on
  `wglSwapBuffers`). `rekordbox.exe` imports the full OpenGL entry-point set plus
  `wglCreateContext`/`wglMakeCurrent`, and carries a private fork of JUCE's GL
  renderer in its own `rb` namespace.
- **The dxgi `WaitForVBlank` patch remains correct and load-bearing.** JUCE 7 has
  `VBlankDispatcher` too, and rekordbox imports exactly one symbol from `dxgi.dll`:
  `CreateDXGIFactory`. dxgi is this application's frame **clock**, never its
  renderer. The clock is verified healthy at a steady **60.0 fps**
  (`RBW_VBLANK_STATS=1`) in every configuration measured.

Consequence: T01's "JUCE 8 on Direct2D" attribution is wrong, and so is the claim
that `WINEDLLOVERRIDES=d2d1=d` "forces JUCE's software renderer" — it only removes
DirectWrite glyph conversion. Run `20260813T064144-rb7-no-d2d` compared two
identical renderers; its *result* was right and its *interpretation* was not.

## 4. Refuted, with numbers

`research/probes/fpsmatrix.sh --variants`, one variable per run, each verified to have survived
the launch:

| variant | fps | p99 gap | max gap | CPU |
|---|---|---|---|---|
| baseline | 29.83 | 34.8 | 35.2 | 72% |
| `DisableAdaptiveVsync=1` | 29.92 | 35.1 | 35.7 | 73% |
| `BasicOpenGL=1` | 29.83 | 34.8 | 35.3 | 71% |
| `UseVertexWave=0` | 29.75 | 35.0 | 35.1 | 71% |
| `RenderDelay=60` (from 120) | 29.92 | 34.9 | 36.3 | 72% |
| **`DisableOpenGL=1`** | **36.17** | **50.2** | **68.6** | **87%** |

- Every rekordbox graphics setting except `DisableOpenGL` changes **nothing**.
- `DisableOpenGL=1` is **not** a fix. It raises the mean by removing the app's own
  limiter and makes the experience *worse*: it drops `wglSwapBuffers` entirely (the
  UI falls back to `StretchDIBits`), the p99 gap rises from 35 ms to 50 ms, the worst
  gap nearly doubles to 69 ms, and CPU rises. Pioneer documents this setting as
  "drawing speed may become slower and the waveform sometimes may stutter"; measured
  here, that is accurate. **Do not ship it.**
- **Mesa `vblank_mode=0` — refuted.** 29.70 fps, unchanged. The 30 fps idle rate is
  not a GL swap-interval stall.

Also refuted by the recon, before costing a run:

- Anything under `HKCU\Software\Wine\Direct3D` (renderer=vulkan, csmt,
  VideoMemorySize, MaxVersionGL): wined3d is instantiated once per process for a
  text-measurement render target and never presents a swapchain.
- DXVK / vkd3d: there is no D3D rendering to translate.
- `WINEESYNC`/`WINEFSYNC`/`WINE_DISABLE_FAST_SYNC`: these strings **do not exist**
  anywhere in wine-staging 11.15. ntsync is the only fast-sync path. Do not ship
  cargo-cult env vars.
- `winewayland.drv`: shipped and one registry value away, but its documented open
  limitation is child-window rendering and rekordbox's GL renderer is a child HWND.
  Ten-minute falsification test at most; not a candidate.

## 5. The one genuinely pathological thing found: a 37,000/sec poll loop

One rekordbox thread holds **68-84% of a CPU core continuously**, idle or not:

    ioctl(12, NTSYNC_IOC_WAIT_ANY, ...) = -1 ETIMEDOUT   x 186,581 in 5 s  (37,300/sec)

Every single call times out. Attributed to the exact caller by mapping the Linux tid
to the Wine tid through the TEB (`gs_base`; `TEB.Self` at +0x30 confirms; `ClientId`
at +0x40) and pulling that thread out of a `winedbg` `bt all`:

    rekordbox+0xfe86eb -> kernelbase+0x76c7d (WaitForSingleObject+0x4d) -> ntdll -> ioctl

Its thread-start frames match the vblank thread's, so it is a JUCE worker. The
timeout must be zero: 37,300 iterations/sec is impossible with even a 1 ms timeout.

**It is the application's own design, and Wine's per-call cost only sets its speed.**
The two eras reconcile exactly:

| | per iteration | achieved |
|---|---|---|
| wineserver (pre-ntsync) | 8 syscalls, ~156 µs | 6,400 spins/sec |
| ntsync | 1 ioctl, ~27 µs | 37,300 spins/sec |

ntsync made each call cheaper; it did not stop the loop. **This corrects the phase-17
claim that ntsync took rekordbox from 70-138% to ~0%** — the *server* went to ~2%,
the *application* did not.

**Deliberately NOT patched.** Making the call cheaper cannot help: it is a busy loop,
so it will consume a core whatever an iteration costs. This theme follows the rule
that has already cost this project two reverted patches (0009 and the
GetCurrentPadding cache): no patch without a mechanism that predicts the measurement.
It matters on a power-limited laptop (§6) and is recorded for that reason.

## 6. Degradation over time — the user's actual complaint

`research/probes/uisoak.sh`, 20 s samples, a track loaded and playing:

| elapsed | fps | p50 | p99 | stutter | rb CPU | threads | rss MB | fds |
|---|---|---|---|---|---|---|---|---|
| 21 s | 55.4 | 17.5 | 31.1 | 0.6% | 146% | 196 | 2104 | 823 |
| 123 s | 53.2 | 17.6 | 35.6 | 1.7% | 155% | 196 | 2109 | 823 |
| 245 s | 46.6 | 18.4 | 49.7 | 7.7% | 166% | 196 | 2115 | 823 |
| 408 s | 42.2 | 20.9 | 54.0 | 9.6% | 171% | 197 | 2123 | 827 |

**The degradation is real and measurable**: -24% frame rate in under 7 minutes, with
the worst-case gap rising from 31 ms to 54 ms and dropped frames from 0.6% to 9.6%.
That is the user's report, reproduced under instrument.

What it is **not**:
- not a thread leak — 196 -> 197
- not an fd leak — 823 -> 827
- not RSS — 2104 -> 2123 MB (~3 MB/min)
- not a Wine object storm — wineserver flat at 2%
- **not thermal.** Refuted twice. At the moment the degraded session measured 32.5 fps,
  `glxgears` on the same display measured **60.00** (its own counter: 60.003) — the
  machine was delivering 60 Hz perfectly. And a **fresh session started while the
  package was still at 96 °C immediately gave 58.17 fps with zero dropped frames.**
  A restart fully recovers it, so the decay is a per-session software quantity.

## 7. It is a GPU memory leak, and it is invisible to every conventional counter

    GEM buffer objects charged to the process   246 MB fresh -> 794 MB after 14 min
    rate, with a track loaded                   ~1.2 MB/sec, monotonic, no plateau
    correlation with frame rate                 r = -0.963 over 21 samples
    reproduced independently                    1.19 MB/s and 1.12 MB/s, separate sessions

**Why every earlier counter missed it: `VmRSS` does not account for DRM buffer
objects.** RSS moves ~1 MB per 20 s while GEM moves ~20 MB. `VmSize` does track it —
measured, the two agree to within 130 kB per interval, i.e. *100% of the process's
address-space growth is i915 GEM*. `research/probes/uisoak.sh` now samples
`/proc/<pid>/fdinfo/*` `drm-total-system0` in the same row as the frame rate.

**What the objects are.** Diffing `/proc/<pid>/maps` by mapping size, the byte growth
is dominated by a **2048 KiB** class — +34 in 60 s, i.e. 68 MB of the 71 MB — alongside
many small 8K/16K objects. There is **no ~8 MiB class**, so these are *not*
framebuffers or swapchain buffers.

**Idle is the control.** With both decks empty the same small-object churn continues
(~1.5/s) but the 2048 KiB class is **entirely absent** and bytes grow 18× slower
(0.047 MB/s). The big leak is specifically the loaded-deck waveform path — which is
also why the frame rate only decays with a track loaded.

**The GL calls balance.** Over an 80 s window under `WINEDEBUG=+opengl`:
`glGenBuffers` 5807 vs `glDeleteBuffers` **5842**; `glGenTextures` 191 vs
`glDeleteTextures` **190**; and zero `Deleting … host 0x0` lines. So nothing is
created-and-never-deleted at the API level, and Wine is not dropping deletes.

**Wine's GL path audited clean.** No list, tree or cache of drawables, contexts or GL
objects that grows per call or per frame; `glGen*`/`glDelete*` are not wrapped at all
and pass straight through the generated thunk; the only two grows-forever structures
in `unix_wgl.c` (`wow64_strings`, `buffers.map`) are wow64-only and `rekordbox.exe` is
measured 64-bit.

**What Wine does contribute is an amplifier, not the leak.** All three of rekordbox's
GL surfaces are on the **offscreen child-window path** — measured from the X tree: a
1×1 dummy parent holding three children, and the toplevel `rekordbox` window has no GL
child. `needs_offscreen_rendering()` (`dlls/winex11.drv/init.c:226`) returns TRUE for
any HWND whose parent is not the desktop, which is every `juce::OpenGLContext`. In
that mode `x11drv_surface_swap` (`dlls/winex11.drv/opengl.c:1457-1464`) **blocks in
`glXWaitForSbcOML`** and then does a full-window `StretchBlt` per frame. That is why
rising GPU cost appears as *blocked time*, and it is the reason a leak the app might
survive on Windows lands here as lost frames.

### Refuted here

- **The size arithmetic.** 2,097,152 bytes = 2048 × 256 × 4, and the app has a
  `WaveImageWidth2=256` setting — a tempting fit. Halving it to 128 changed nothing:
  1.12 MB/s and still a 2048 KiB class, +32 in 60 s. The buffer size is not derived
  from that setting.

### Two corrections to this theme's own earlier text

1. **"Not more app work — CPU is flat" was wrong.** CPU *per frame* roughly doubles
   over a run (2.00 → 4.25 %CPU per fps). The per-thread trace that showed "flat"
   started 215 s into the soak and sampled the plateau *after* the ramp had happened.
2. **The whole renderer matrix in §4 was measured with BOTH DECKS EMPTY**, at the
   29.8 fps idle limiter, where no waveform is drawn and no waveform setting can do
   anything. Those results stand for the idle state only; **no renderer setting has
   ever been tested under the fault.** `research/probes/fpsmatrix.sh` now loads a track and
   verifies it by frame rate before reporting any number.

### Next

1. Name the allocator of the 2 MB buffers: a fresh session under
   `strace -e trace=ioctl` filtered to `DRM_IOCTL_I915_GEM_CREATE`, or the
   PTRACE_SEIZE single-thread sampler (32.8 µs stop, 0.66% duty). A caller inside
   rekordbox means an application leak; inside `winex11.drv`/`opengl32` would
   overturn the audit above.
2. Re-run the renderer matrix **with a track loaded** — it has never been done.
3. Test `DisableOpenGL=1` while sampling GEM: if the growth stops, the leak is
   unambiguously in the GL stream.

## 2026-08-17 (late evening) — the leak is unambiguously in the GL stream

Three of this theme's four open items are now measured.

### The leak reproduces, and it is faster than recorded

Fresh launch, one track loaded and playing, GPU memory read from the process's
own DRM fd (`/proc/<pid>/fdinfo/<drm fd>` → `drm-total-system0`):

    206,664 KiB  fresh, no track
    259,704 KiB  track loaded
    378,004 KiB  60 s later      = +1.97 MB/s

### `DisableOpenGL=1` stops it dead — item 3, answered

Same machine, same track playing, one variable (the rekordbox setting, edited in
`rekordbox3.settings` with the app closed, byte-length preserved so the file does
not reflow):

| renderer | GEM at start | after 60 s | rate |
|---|---|---|---|
| OpenGL (default) | 259,704 KiB | 378,004 KiB | **+1.97 MB/s** |
| software (`DisableOpenGL=1`) | 96,372 KiB | 96,268 KiB | **0.00 MB/s** |

**The growth is entirely in the GL stream**, and the software renderer's whole
GPU footprint is a third of what the GL renderer starts at. There is no residual
leak underneath it.

### What the allocation stacks say — item 1, partly

`strace -f -e trace=ioctl` on the process, then `strace -k` on the one thread
that issues DRM ioctls (tid 2684374; the busiest thread overall is a different
one, doing 181,371 `NTSYNC_IOC_WAIT_ANY` in four seconds — the app's own
zero-timeout poll, not graphics):

    4 s of ioctls:  16 DRM_IOCTL_I915_GEM_CREATE_EXT   (4/s)
                   498 DRM_IOCTL_I915_GEM_MADVISE
                   231 DRM_IOCTL_I915_GEM_EXECBUFFER2
                   231 DRM_IOCTL_SYNCOBJ_CREATE

Every `GEM_CREATE_EXT` stack is **entirely inside `libgallium` (Mesa)**, with
`wine/x86_64-unix/opengl32.so` as the outermost frame that can be unwound — i.e.
the allocation is Mesa acting on a GL call that arrived through Wine's thunk, as
expected. **Naming the GL call needs Mesa debug symbols**, which this machine
does not have: `addr2line` resolves only to the nearest exported symbol (garbage
— it reported `__vaDriverInit_1_24` for driver-internal addresses) and
`eu-addr2line` with `debuginfod` returns `??` for every frame. That is the next
concrete step, and it needs a Mesa build or debug package, not more tracing.

**Wine's swap path is exonerated as an allocator.** `x11drv_surface_swap`
(`dlls/winex11.drv/opengl.c:1448`) does `glFlush`, `glXSwapBuffersMscOML`,
`glXWaitForSbcOML` and `client_surface_present` — no readback, no per-frame
client-side allocation. It costs *blocked time*, which is this theme's
amplifier finding, but it does not allocate.

### The software renderer with a track loaded — item 2, first data

`bin/damagefps`, track playing, `DisableOpenGL=1`:

    fps=38.87   p50 gap 32.7 ms   p90 33.8 ms   p99 49.95 ms   stutters 25.3%

against the GL renderer's 58.1 fps / p99 18.0 ms measured fresh. So software is
markedly worse **when fresh** — but it does not leak, and the GL renderer decays
to 36.8 fps over nine minutes. Whether software is the better choice for a long
set is exactly the soak comparison this theme has never run in software mode.

## 2026-08-17 (night) — CORRECTION: the frame rate does NOT degrade while a track is playing

This theme's headline — *"55.4 → 36.8 fps over nine minutes, resources and clocks
flat, so the per-frame cost itself grew"*, attributed to the GPU memory leak — is
**wrong, and the mechanism of the error is a confound in the soak itself**.

### The confound

rekordbox renders at ~58 fps with a track **playing** and runs its own ~33 ms
frame limiter otherwise. `research/probes/uisoak.sh` requires a track to be *loaded*, and
this theme's own text warns that "soaking an empty session measures the limiter,
not the lag" — but a deck that is loaded and **stops** is the same thing. The
demo track is 2:08 long and the soaks are 9–27 minutes, so unless something
keeps the deck playing, every soak spends most of its length measuring the
limiter.

Re-running the soak with GPU memory instrumented showed the drop is not gradual
at all:

    t=21 s   fps 51.00   p50 22.18 ms
    t=65 s   fps 38.35   p50 32.87 ms      <- 33 ms IS the idle limiter
    t=304 s  fps 36.85   p50 33.06 ms

A step, inside the first minute, exactly when the deck stopped — not a decay.

### The controlled pair, with `research/probes/playkeep.sh` keeping the deck playing

`playkeep` checks every 20 s whether the deck's own elapsed-time readout is
advancing and, only if it is not, presses CUE then PLAY. Ten minutes each, same
track, same machine, one variable:

| renderer | fps first → last | min | verdict | GPU memory |
|---|---|---|---|---|
| **OpenGL** (default) | **58.0 → 57.9** | 49.8 | **STABLE, −0.3%** | 244 → **1368 MB** |
| software (`DisableOpenGL=1`) | 41.4 → 41.9 | 38.5 | STABLE, +1.2% | 94 → 94 MB |

**The frame rate holds at 58 fps for ten minutes while GPU memory grows by more
than a gigabyte.** The leak is real, it is entirely in the GL stream, and over
this interval it is **asymptomatic**. The r = −0.963 correlation this theme
reported was correlation with a stopped deck, not causation by GPU memory.

The transient dips in the GL run (52.3 at t=174, 50.9 at t=502) coincide with
`playkeep` restarting the track, and recover to 58 immediately.

### What that changes

- **`DisableOpenGL=1` is not a recommendation.** It is stable, but it is stable
  at **41 fps against OpenGL's 58**, and it has no advantage now that the leak is
  known not to cost frames over a set-length interval.
- **"Restart rekordbox between sets" loses its stated justification.** It was
  based on this degradation. The user's original report — *"over time the UI has
  become extremely laggy and is no longer usable"* — is still real and still
  unexplained; T07 (36 orphaned processes and lost ntsync) explains a large part
  of it, and that is fixed.
- **The leak stays open on its own merits.** 1.9 MB/s, unbounded, ~1.4 GB in ten
  minutes. Whether it becomes symptomatic beyond that — through memory pressure
  or eviction — is a longer soak, which is running.

### An honest note on my own earlier run today

The first GL soak I ran tonight reported −33% and I very nearly wrote it up as
confirmation. It used `playkeep` v1, which watched the track file's offset — a
signal that dies once a 5 MB file has been read to the end, so it "detected a
stall" every 13 s and toggled play/pause on a healthy deck for the whole run.
The fixed version, watching the deck's own readout, gives −0.3%. **Two soaks,
opposite verdicts, and the difference was entirely in the instrument.**

### The long soak: 4.5 GB of GPU memory, and the frame rate does not care

27 minutes, GL renderer, deck kept playing by `research/probes/playkeep.sh` (12 track
restarts, no play/pause toggling):

    fps        first 58.1   last 57.5   min 44.4   change -1.2%   VERDICT: STABLE
    gpu mem    1497 MB -> 4514 MB       (+3 GB in 27 minutes, ~1.9 MB/s, no plateau)
    rss        1991 MB -> 2110 MB
    threads    196 -> 196     fds 824 -> 824     hottest 96 -> 95 C

**Three gigabytes of leaked GPU memory bought no measurable frame-rate cost.**
The dips in the series (44.4 min) are transient and coincide with track
restarts; the run ends where it began, at 58 fps.

The machine has 38 GB of RAM and this is an integrated GPU, so 4.5 GB is
affordable. The honest residual risk is **duration**: at 1.9 MB/s a three-hour
set would reach ~20 GB, which is a different regime and has not been tested. The
leak remains worth fixing, and naming the allocating GL call still needs Mesa
debug symbols — but it is not the cause of any lag anyone has reported.
