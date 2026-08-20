# REGRESSION — every test this project has, and what a pass looks like

**Written 2026-08-14, after the audio Sample Rate dropdown — a feature proven
working on 2026-08-13 (`upstream/wasapitest-output-event.txt`, screenshot) — was
broken by stacked changes and nobody noticed for a day.** There was no regression
suite. This is it.

**Run Tier 0 and Tier 1 on every change. Run all tiers at every milestone and
before any upstream submission or packaging claim.**

There is **no `rbw regress` command**. Nothing here is wired into a single
runner; every test below is invoked by hand. Building that runner is the first
thing to do after this document. Treat that as an open gap, not an oversight to
be worked around.

## Why tiers

A full pass is slow — Tier 2 alone is ~30 minutes of unattended GUI driving,
Tier 4 needs a human at the keyboard with hardware attached. Tier 0 and Tier 1
together are under five minutes and catch the majority of what has actually
broken here. Ordering is not cosmetic:

| tier | what | needs | wall time |
|---|---|---|---|
| **0** | instrument self-tests — is the harness itself trustworthy | nothing | ~3 min |
| **1** | headless probes, no GUI | wine, some need the controller | ~1 min total |
| **2** | UI assertions, rekordbox running | GUI session, X11 | ~30 min full |
| **3** | controller physically connected | DDJ-400 plugged in | ~10 min |
| **4** | a human confirming what a machine cannot | a person, ears, hardware | ~15 min |

**Minimum on every change** — about six minutes, and it would have caught every
configuration regression this project has suffered:

    ./bin/rbw doctor                                    # 0.1
    ./bin/rbw selftest                                  # 0.2
    ./bin/audiotest.sh --self-test                      # 0.7
    RBW_PREFIX=$PWD/prefixes/rb7 ./bin/rekordbox-wine --check   # 1.9 (read its caveats)
    WINEPREFIX=$PWD/prefixes/rb7 wine upstream/vblanktest.exe   # 1.1
    WINEPREFIX=$PWD/prefixes/rb7 wine upstream/wasapitest.exe event  # 1.4
    ./bin/audiotest.sh                                  # 2.5  <- the R24 detector

**Tier 0 runs first or everything downstream is worthless.** `docs/investigation/THEMES/T00-instrument.md`
is emphatic about this and it is not theoretical: the oracle produced **two fake
verdicts**, and one of them (`blank-window` from an X11 grab that returned pure
black, stddev 0.0) would have "confirmed" the exact AppDB 7.2.8 bug the project
was hunting. The other (OCR returning zero characters, so every text assertion
failed open) produced a published-to-ourselves `no-input` verdict on run
`20260812T201002` that run `20260813T062048` later disproved by recovering the
very keystrokes it said were never accepted.

## Conventions

- All commands are run from the repo root: `cd ~/projects/rekordbox-wine`
- `$P` below means `WINEPREFIX=~/projects/rekordbox-wine/prefixes/rb7`
- Every claimed result cites a run id, a transcript file, or a commit. Anything
  without one is marked **UNTESTED** or **UNVERIFIED**.
- Wine version pinned by all recorded results: **wine-staging 11.15**, Intel
  Iris Xe / Mesa 26.1.6, KDE Plasma on Wayland (XWayland), PipeWire 1.6.8,
  rekordbox 7.2.17, Pioneer DDJ-400 (usb `2b73:0026`).

**Uncommitted at time of writing.** `bin/audiotest.sh`, the `audio_prefs` block
in `scenarios/regions.json`, and `uiassert.py --block` were built on 2026-08-14
in response to the Sample Rate regression and are still in the working tree, not
in any commit. Tests 0.7 and 2.5 describe them as they stand.

---

# Tier 0 — instrument self-tests

Nothing below this line means anything if these fail. A Tier 0 failure is never
an application finding; it is a harness fault, and every verdict produced since
the last passing Tier 0 is suspect.

### 0.1 — `rbw doctor`

    ./bin/rbw doctor

**Measures** that every tool the oracle depends on exists: `wine`, `winetricks`,
`xdotool`, `xwininfo`, `magick`, `tesseract`, `jq`, `qdbus6`; that `DISPLAY` is
set; disk free.

**PASS** every line green, ends `ok ready`, prints `wine wine-11.15 (Staging)`.

**FAIL** a missing `qdbus6` is the dangerous one: `rbw run` degrades to
OCR-only input adjudication with only a `warn`, which is precisely the
configuration that produced the retracted `no-input` verdict. A missing
`tesseract` or `magick` fails every capture assertion open.

**Theme** T00 · **Needs** nothing · **Time** ~5 s

### 0.2 — `rbw selftest` — the positive control

    ./bin/rbw selftest

**Measures** that the oracle can return `window-ok` at all, by driving `winecfg`
and `notepad` through the **identical** `cmd_run` code path used for rekordbox:
window discovery, spectacle capture, cropping, OCR, synthetic typing, clipboard
read-back, verdict. Also measures the greyscale stddev floor of two genuinely
good windows, which is the only evidence that `BLANK_STDDEV` is a safe number.

**Recorded PASS** (`20260812T194729-control-ctl-winecfg`,
`20260812T194755-control-ctl-notepad`; table in `docs/investigation/THEMES/T00-instrument.md`):

| control | verdict | peak stddev | input |
|---|---|---|---|
| winecfg | `window-rendered` | **0.46473** | n/a |
| notepad | `window-ok` | **0.41156** | echoed |

and the closing line `BLANK_STDDEV=0.02 is safely below both. Threshold OK.`
followed by `RESULT: oracle validated.` `0.02` sits an order of magnitude below
both; before this it was a number invented with no evidence.

**FAIL, and what each means** — the script names them explicitly:
- `no window` → `xdotool`/capture cannot see Wine windows. Historic cause: window
  discovery matched the launcher **subshell** pid (70157) instead of the wine
  child that owns the window (70235). Every run would return `no-window`.
- `typing not echoed` → synthetic input **or** OCR is broken. Historic cause:
  tesseract read zero characters at native resolution; the 3× upscale +
  sharpen fixed it. Typing was fine all along — one root cause, two apparent
  failures.
- lowest stddev < 0.02 → the blank threshold would misjudge a real window as
  blank; the script tells you what to lower it to.

**Theme** T00 · **Needs** nothing (builds `prefixes/control` on first run) ·
**Time** ~2–3 min (two 20 s runs plus prefix boot)

**Re-verify after any Wine, KDE, ImageMagick, or tesseract upgrade.** That is a
standing instruction in T00, not a suggestion.

### 0.3 — capture path is spectacle, not an X11 grabber

    grep -n "spectacle" bin/rbw research/probes/uiprobe.py research/probes/uiassert.py research/probes/menuprobe.sh
    grep -rn "x11grab\|import -window\|xwd" bin/          # must return nothing

**Measures** that no capture path has regressed to an X-side grabber.

**PASS** spectacle appears in all four files; the second grep is empty.

**FAIL** means captures may silently return pure black under XWayland — measured
2026-08-12, `ffmpeg -f x11grab` of the XWayland root returns **stddev 0.0**
because the root holds no composited content and toplevels are redirected.
`import` (ImageMagick 7.1.2-29) fails outright with "missing an image filename".
Either produces a confident `blank-window` on a healthy window.

**Theme** T00 (fault I1) · **Needs** nothing · **Time** ~1 s

### 0.4 — `uiassert` refuses to grade an ungradeable screenshot

    ./research/probes/uiassert.py --shot runs/CALIB/main.png            # must exit 0
    ./research/probes/uiassert.py --shot upstream/devtree-output-stock.txt ; echo $?   # must exit 2

**Measures** the exit-code contract: **0** = assertions held, **1** = an
assertion failed, **2** = the test *could not run*. Distinct on purpose, because
"the test could not run" reading as "the test passed" is exactly what produced a
fake `blank-window` earlier in this project.

The live calibration gate is in `research/probes/uiassert.py:161` — if the always-enabled
`File` label is not at least 0.20 peak brighter than an empty background patch,
it refuses to grade and exits 2 rather than emitting confident nonsense.

**Recorded PASS** commit `ac36003`, 2026-08-14: baseline on `runs/CALIB/main.png`
(2050×1164) grades all four regions and exits 0.

**FAIL** exit 2 with `calibration failed: reference bright_text peak=… vs
dark_background peak=…` means the window is occluded, blank, or the regions
have rotted against a new skin/compositor — **not** an application finding.

**Theme** T00 · **Needs** nothing (a stored screenshot) · **Time** ~3 s

### 0.5 — classifier does not invent crashes

    python3 bin/classify.py runs/20260812T201002-rb7-baseline-x11/wine.log /tmp/rbwtest
    jq '.categories' /tmp/rbwtest/classify.json

**Measures** the anchored-hex guard in `bin/classify.py:20-23`. An unanchored
`c0000005` matches inside ordinary hex arguments; measured on the first
rekordbox baseline, `NtQueryValueKey(...,6c00000050,...)` was reported as **12
access violations in a log with zero real faults**.

**PASS** `access_violation` and `unhandled_exception` absent from `.categories`
for that log. The recorded finding for `20260812T201002` is **zero real
exceptions in 960,172 lines**, 99 modules.

**FAIL** phantom crash categories, which feed `verdict.py` and get appended to
headlines.

**Theme** T00 · **Needs** nothing (writes only to `/tmp`) · **Time** ~10 s

### 0.6 — verdict taxonomy still distinguishes three input states

    grep -n "stale-surface\|accepted-not-echoed" bin/verdict.py bin/rbw

**Measures** that the `accepted / echoed` → verdict mapping added on 2026-08-13
survives:

| accepted | echoed | verdict |
|---|---|---|
| yes | yes | `window-ok` |
| yes | no | `stale-surface` — input fine, presentation broken |
| no | no | `no-input` |

**FAIL** if `stale-surface` disappears, the harness collapses back to the
two-state model that produced the retracted verdict on `20260812T201002`.

**Theme** T00 (fault I6) · **Needs** nothing · **Time** ~1 s

### 0.7 — `audiotest --self-test` — the Sample Rate detector is not a constant

    ./bin/audiotest.sh --self-test

**Measures** that the Sample Rate detector (test 2.5) answers **both ways** on
the same layout, against three stored fixtures in `runs/AUDIOTEST/`. A detector
that always returns the same answer is worse than no detector.

**Recorded PASS** (2026-08-14, all three fixtures present):

| fixture | content | measured | expected exit |
|---|---|---|---|
| `03-audio.png` | the live broken capture | `peak=0.000 sd=0.000` → `absent` | **1** |
| `FIXTURE-populated.png` | synthetic white text | `peak=1.000 sd=0.269` → `active` | **0** |
| `FIXTURE-populated-dim.png` | synthetic dim grey | `peak=0.471 sd=0.127` → `greyed` | **0** |

Ends `self-test OK: the detector is not a constant.`

**FAIL** exit 2 with `the detector does not discriminate. Do not trust its
verdicts.` Also exit 2 if a fixture is missing — the fixtures are evidence and
must not be deleted.

**Theme** T03 / T00 · **Needs** nothing (stored screenshots) · **Time** ~10 s

---

# Tier 1 — fast headless probes

Freestanding PE probes, no GUI, no toolkit, no rekordbox. Built with
`upstream/build-probes.sh` (clang against Wine's own headers; no mingw, no root).
`.exe` files are committed, so a rebuild is only needed after editing a probe.

**Note** `build-probes.sh` covers `vblanktest wasapitest miditest hidtest
devtreetest`. **`ifacetest` is missing from its `PROBES` list and from
`libs_for()`** — `upstream/ifacetest.exe` exists but cannot be rebuilt by that
script as written. **GAP.**

### 1.1 — `vblanktest` — is `WaitForVBlank` implemented

    $P wine upstream/vblanktest.exe

**Measures** the achieved rate of 200 `IDXGIOutput::WaitForVBlank` calls. This is
the whole T01 root cause in two lines of output, with no proprietary software.

**Recorded PASS** (JOURNAL 2026-08-13T08:25):

    patched : hr=0x00000000, 0 of 200 failed, 60 calls/second on a 60Hz panel
              VERDICT: OK — rate is consistent with a real display refresh.

**Recorded FAIL / stock baseline:**

    stock   : hr=0x80004001 (E_NOTIMPL), 200/200 failed, 200 calls in 0 ms
              VERDICT: BROKEN — WaitForVBlank does not block.

**A third state matters.** `VERDICT: SUSPECT` (succeeds but >200/s) is what a
*wrong* fix looks like: the first version of patch 0001 truncated the ms
conversion, woke just before the refresh boundary, and measured **109 calls/s on
a 60 Hz display**. It "worked" — rekordbox repainted — and would have made every
JUCE app repaint at double rate and burn CPU. Assert the *number*, not the
verdict word.

**FAIL means** the patched `dxgi.dll` is not loaded (see 1.7) or the patch
regressed. Downstream symptom: any JUCE app paints one frame and freezes while
still accepting input.

**Theme** T01 · **Needs** nothing (a display) · **Time** ~4 s

### 1.2 — `wasapitest` — exclusive-mode format sweep

    $P wine upstream/wasapitest.exe

**Measures** `IAudioClient::IsFormatSupported` in `AUDCLNT_SHAREMODE_EXCLUSIVE`
across 6 rates × 2 channel counts × 4 depths = 48 formats, for every render
endpoint. This is how rekordbox builds its Sample Rate list.

**Recorded PASS** (`upstream/wasapitest-output-alsa.txt`, 7 render endpoints):

    HRESULTs seen   : 0x00000000(S_OK)
    verdict: 48 exclusive formats accepted — a rate list can be built.

**Recorded FAIL** (`upstream/wasapitest-output-pulse.txt`, 6 render endpoints):

    HRESULTs seen   : 0x8889000e(EXCLUSIVE_MODE_NOT_ALLOWED)
    verdict: EVERY exclusive probe refused ... 48/48

`XCL` in every cell means the audio driver is winepulse, which implements no
exclusive mode at all.

> **A PASS HERE DOES NOT MEAN THE SAMPLE RATE DROPDOWN WORKS. Measured
> 2026-08-14: `wasapitest` reports 48/48 exclusive formats accepted while the
> dropdown is blank.** rekordbox builds its rate list at **device-selection
> time**, on a path this probe never walks. Treating this test as coverage for
> the dropdown is exactly the false confidence that let R24 go unnoticed for a
> day. The only honest oracle for the widget is test **2.5**.

**Theme** T03 · **Needs** nothing (controller only for endpoint `[6]`) ·
**Time** ~10 s

### 1.3 — `wasapitest play` — a real exclusive stream

    $P wine upstream/wasapitest.exe play

**Measures** end to end: `IsFormatSupported` saying yes and a stream actually
running are different claims. Opens exclusive at 44100/4ch and pushes 1.5 s of a
440 Hz square wave.

**Recorded PASS** (`upstream/wasapitest-output-alsa.txt` tail):

    playing a tone on [6] Speakers (Out: DDJ-400 - USB Audio)
    device period   : default 100000 ns, min 50000 ns
    Initialize excl : 0x00000000 S_OK   (44100 Hz, 4 ch, 32f)
    buffer size     : 3528 frames
    Start           : 0x00000000 S_OK
    wrote           : 66150 frames

**FAIL** `0x8889000e` on Initialize = wrong driver. Silence with S_OK = a
routing problem, not an API problem — escalate to Tier 4.

**Theme** T03 · **Needs** the DDJ-400 for endpoint `[6]`; runs against other
endpoints without it · **Time** ~5 s

### 1.4 — `wasapitest event` — event-driven exclusive, the call rekordbox makes

    $P wine upstream/wasapitest.exe event

**Measures** `Initialize(EXCLUSIVE | AUDCLNT_STREAMFLAGS_EVENTCALLBACK)` and then
the **refusal rate** of `GetBuffer` across 344 periods. Two separate patches are
under test here: 0002 (mmdevapi, PE, per-prefix) and 0003 (winealsa, unix `.so`,
system-wide).

**Recorded results, all four combinations known:**

| mmdevapi | winealsa | result |
|---|---|---|
| stock | — | `Initialize` → `0x8889000a DEVICE_IN_USE` on an idle device (`upstream/wasapitest-output-event.txt`) |
| **patched 0002** | stock | `S_OK`, buffer **256 frames** = one period, event fires; then **343 refusals across 344 periods**, `0x88890006 BUFFER_TOO_LARGE`, padding stuck at 256 |
| **patched 0002** | **patched 0003** | **344 serviced, 0 refusals** (T05, "343 refusals to 0") |

**PASS today** = `S_OK`, 256-frame buffer, **0 refusals**.

**FAIL** `DEVICE_IN_USE` → mmdevapi patch not loaded (see 1.9); this is the
**leading candidate mechanism for the Sample Rate regression**, but — as with
1.2 — a pass here is not evidence the dropdown populated. Confirm with 2.5. It is the single most
likely cause of the dropdown going empty. Non-zero refusals → the system
`winealsa.so` has reverted to stock (a `wine-staging` package upgrade does
exactly this, by design — it fails safe back to stock).

**Instrument note** the first version of this probe broke out on the first
refusal and reported "the event never arrived". The *rate* is the finding, not
the first refusal.

**Theme** T03 / T05 · **Needs** the DDJ-400 · **Time** ~10 s

### 1.5 — `miditest` — MIDI port enumeration and naming

    $P wine upstream/miditest.exe                 # list
    $P wine upstream/miditest.exe out 0           # open OUT 0, send a note, hold 8 s
    $P wine upstream/miditest.exe in 0            # open IN 0, receive, hold 8 s

**Measures** what winmm reports, and — in `out`/`in` mode — whether
`midiOutOpen(n)` actually subscribes to the device `midiOutGetDevCaps(n)`
describes. The hold-open is deliberate: it gives you 8 s to run `aconnect -l`.

**Current expected PASS** (patches 0004 + 0006 installed; STATE.md, T05):

    MIDI OUT devices: 1        [0] DDJ-400
    MIDI IN devices : 1        [0] DDJ-400

**Note the committed transcript is STALE.** `upstream/miditest-output.txt`
records the *pre-patch* state — 4 devices, DDJ-400 last at `[3]`, named
`DDJ-400 - DDJ-400 MIDI 1`. Do not treat that file as the pass criterion; it is
the historical baseline. **UNVERIFIED**: no transcript of the current 1-OUT/1-IN
state has been committed, only the counts quoted in STATE.md and T05.

**FAIL and what each means:**
- `Midi Through Port-0` present → `snd_seq_dummy` is loaded again. rekordbox
  binds the loopback and talks to itself; `Tx/Rx bytes` stay 0 forever.
- `PipeWire-System` / `PipeWire-RT-Event` present → patch 0006 not loaded.
  Those ports have `CAP_READ`/`CAP_WRITE` but not `CAP_SUBS_READ/WRITE`, so
  `midiInOpen` on them returns `3` (`MMSYSERR_NOTENABLED`) **without logging
  anything** (`alsamidi.c:1214`).
- Name is `DDJ-400 - DDJ-400 MIDI 1` → patch 0004 not loaded. rekordbox keys its
  mapping profile on this exact string and will write an empty stub profile.
- `WINE ALSA Input` appearing as a MIDI **OUT** device → Wine enumerating its own
  ports; a real Wine defect, but it is *not* what broke binding (rekordbox
  enumerates before its own ports exist).

**Theme** T05 · **Needs** the DDJ-400 · **Time** ~2 s list, ~10 s open modes

### 1.6 — `hidtest` — is the controller visible through the HID stack

    $P wine upstream/hidtest.exe

**Measures** a walk of the HID device-interface class exactly as rekordbox does
(`HidD_GetHidGuid` → `SetupDiEnumDeviceInterfaces` → `HidD_GetAttributes` →
`HidD_GetProductString`).

**Recorded PASS** (T05):

    [0] \\?\hid#vid_2b73&pid_0026&mi_04#...   VID_2B73 PID_0026   product: DDJ-400
    VERDICT: the controller IS visible through HID.

**FAIL** nothing found → `/dev/hidraw0` is not readable by the user, so
`winebus.sys` cannot enumerate it and rekordbox behaves as though no controller
is attached. Fix is the udev rule (see Known Good Configuration) plus a
**replug** — `uaccess` only applies on a real device-add event.

**UNVERIFIED**: no committed transcript file; the quoted lines live in
`docs/investigation/THEMES/T05-controller.md` only.

**Theme** T05 · **Needs** the DDJ-400 · **Time** ~2 s

### 1.7 — `devtreetest` — do the cfgmgr32 calls tell the truth

    $P wine upstream/devtreetest.exe

**Measures** `CM_Get_DevNode_Status` / `CM_Get_Child` / `CM_Get_Sibling` with the
out-params **pre-poisoned to `0xdeadbeef`**, so a stub that returns `CR_SUCCESS`
without writing them is visible rather than looking like a plausible device state.

**Recorded PASS** (`upstream/devtree-output-patched.txt`, patch 0005):

    ROOT\WINE\WINEBUS   [status: CR_SUCCESS st=0000000A prob=00000000]
      WINEBUS\VID_845E&PID_0001\0&0000&0&0&0            [st=0000000A prob=00000000]
      WINEBUS\VID_845E&PID_0002\...                     [st=0000000A prob=00000000]
      USB\VID_2B73&PID_0026&MI_04\259&-----&0&0&0       [st=0000000A prob=00000000]

`0x0A` = `DN_DRIVER_LOADED | DN_STARTED`; three children enumerated.

**Recorded FAIL / stock** (`upstream/devtree-output-stock.txt`):

    ROOT\WINE\WINEBUS   [status: CR_SUCCESS st=DEADBEEF prob=DEADBEEF]
      *** CM_Get_Child returned CR_SUCCESS but never wrote *child ***

A real application asks "is this device started and problem-free", is told **yes,
succeeded**, and reads `problem = 0xDEADBEEF`.

**Scope note** patch 0005 is a genuine correctness fix and is **not** on
rekordbox's code path — run `20260813T145820-rb7-cfgmgr32-trace` measured
**0 calls** to `CM_Get_Child`, `CM_Get_Sibling`, `CM_Get_DevNode_Status` and
`CM_Get_Parent` across a full startup. Keep the test; do not re-derive the
hypothesis.

**Theme** T06 · **Needs** the DDJ-400 · **Time** ~2 s

### 1.8 — `ifacetest` — `DRV_QUERYDEVICEINTERFACE` for every winmm device

    $P wine upstream/ifacetest.exe

**Measures** `DRV_QUERYDEVICEINTERFACESIZE` (0x080D) then
`DRV_QUERYDEVICEINTERFACE` (0x080C) for wave out, wave in, midi out, midi in.

**Recorded PASS** (run `20260813T154622-rb7-midiiface`, patch 0007): every MIDI
size query paired with a fetch, all `rc=0`, string

    \\?\usb#vid_2b73&pid_0026&mi_03#-----#{6994ad04-93ef-11d0-a3cc-00a0c9223196}

376 matched size/fetch pairs for IN and OUT, all `MMSYSERR_NOERROR`. Wave devices
return a bare endpoint GUID (`{B1AD9065-…}`), **not** a path — measured twice,
recorded so nobody re-derives it.

**FAIL** `rc=` non-zero on MIDI → patch 0007 not loaded. Note this restores the
pre-0007 behaviour in which rekordbox polls forever (559 `midiInMessage(0,
0x080D)` calls, run `20260813T151348-rb7-midienum-patched`), which is what the
user sees as device controls flickering.

**Do not chase the string's content.** Phase 7 (workflow `wsbi09ne4`, five
agents, two concluding independently) established the path is stock JUCE 7.0.9
`getInterfaceIDForDevice`, stored as an opaque `MidiDeviceInfo::identifier` and
never parsed. `upstream/reports/NOTES-iface-format-search.md` must not be run.

**Theme** T05 · **Needs** the DDJ-400 · **Time** ~2 s

### 1.9 — configuration verifier

    RBW_PREFIX=$PWD/prefixes/rb7 ./bin/rekordbox-wine --check

**Measures** every step that has silently reverted on us: patched DLL present in
the prefix and **byte-identical to the artifact**, patch marker present in the
installed file, `DllOverrides` read back out of the registry, `Drivers\Audio`,
system `winealsa.so` marker, `snd_seq_dummy` not loaded, udev rule present,
`/dev/hidraw*` readable.

**Exit** 0 all verified · 1 misconfigured · 2 bad usage.

**Three defects in this checker, found while writing this document. Read before
trusting it:**

1. **The `winmm` check is a guaranteed false pass.** The marker it greps is
   `midiInMessage` (`bin/rekordbox-wine:89`), which is an **exported symbol name
   present in stock winmm** — measured 2026-08-14: `strings
   /usr/lib/wine/x86_64-windows/winmm.dll | grep -c midiInMessage` = **2**. A
   stock winmm passes this check. Patch 0007's PE half carries **no RBW marker
   at all** (`grep -c RBW artifacts/winmm-patched-native-11.15.dll` = 0). There
   is currently **no way to detect a reverted winmm.** **GAP.**
2. **The `winealsa.so` check greps only `RBW-EVENT`**, which is patch 0003's
   marker. Two other markers exist in the installed file and are not checked:
   `RBW-MIDIENUM build: subscribable ports only, own client skipped.` (0006) and
   `RBW-MIDIIFACE build: DRV_QUERYDEVICEINTERFACE for MIDI.` (0007). Patch 0004
   has no marker at all. `artifacts/winedll/` holds four builds including a
   0003-only one — rolling back to it would pass `--check` cleanly.
3. **The default prefix is wrong for this repo.** `WINEPREFIX` defaults to
   `~/.local/share/rekordbox-wine/prefix`, which **does not exist** here
   (measured). Without `RBW_PREFIX` the check reports `FAIL no prefix` and tells
   you nothing about `prefixes/rb7`.

Until (1) and (2) are fixed, use the explicit marker greps in the Known Good
Configuration section below instead.

**Theme** all · **Needs** nothing (controller lines degrade to `note`) ·
**Time** ~10 s

---

# Tier 2 — UI assertions, rekordbox running

Requires an X11 (XWayland) session with the compositor's screenshot service
available. Wayland-driver runs can be captured but **cannot be typed into** —
XTEST is X11-only — so they must use `--no-input` and can never return
`window-ok`. Do not read that as an application failure (T00, known limitation).

### 2.1 — `uiassert` baseline — the four binding tells

    ./research/probes/uiassert.py --capture --expect baseline
    ./research/probes/uiassert.py --shot runs/CALIB/main.png --expect baseline    # offline

**Measures** enabled/disabled state of the four controls the user identified as
the "controller is bound" tells: `midi_indicator` and `pad_indicator` (top
right), `mix_control` and `level_control` (above the library). Decides on **peak**
brightness inside each region, not mean — the mean is dominated by near-black
background either way, while the peak tracks the glyphs. Distinguishes `absent`
(no glyphs at all) from `greyed`, because a missing control and a disabled one
are different failures.

**Recorded PASS** commit `ac36003`, calibrated 2026-08-14 against
`runs/CALIB/main.png` (2050×1164) in PERFORMANCE view: **all four `greyed`, MIDI
not bound** — i.e. the baseline asserts the *current known-broken* state, and it
passes.

**Recorded PASS for the milestone** — `--expect milestone` asserts all four
`active`. **This has never passed. UNTESTED by definition**: the controller has
never bound. It is the project's finish line encoded as an exit code.

**FAIL** exit 1 with `FAIL want=…` per region. Exit 2 is a harness fault, not a
finding (see 0.4).

**Theme** T05 · **Needs** rekordbox running in Performance view; a stored
screenshot for the offline form · **Time** ~5 s

### 2.2 — `rbw run` — adjudicated single-window run

    ./bin/rbw run --recipe rb7 --label <what-changed>
    ./bin/rbw run --recipe rb7 --label x --debug '+dxgi' --timeout 120

**Measures** the full oracle: window mapped, per-sample stddev, OCR, synthetic
click-then-type, clipboard read-back, log classification, verdict. Writes
`runs/<id>/{manifest.json,wine.log,timeline.tsv,verdict.json,classify.md,shots/}`
and appends one line to `runs/index.jsonl`.

**Recorded PASS** `20260813T071026-rb7-PATCHED-vblank-native` → **`window-ok`**,
"keystrokes accepted and echoed", token `RBWPROBE1426` visibly rendered in the
email field, shot-to-shot RMSE **0.0213** — non-zero for the first time in the
investigation, where every prior comparison was exactly 0.

**Recorded controls** — one variable, both directions:

| dxgi build | load path | verdict | run |
|---|---|---|---|
| unpatched | native, marker stripped | `stale-surface` | `…071216` / `…071224` |
| **patched** | identical | **`window-ok`** | `…071026` |

**FAIL** `stale-surface` = the patched dxgi is not live (check `grep RBW-PATCH
runs/<id>/wine.log`). `blank-window` = **suspect the instrument first** and go
back to Tier 0. `indeterminate` = the window was never isolated in a capture;
blankness is undecidable and the run is void, not a failure.

**Caveat** this drives the **sign-in window** by default. Every recorded
`window-ok` is on that window. There is still **no adjudicated `rbw run` on the
main UI** — it is listed as an outstanding sub-step in STATE.md and remains
**UNTESTED**.

**Theme** T01 · **Needs** GUI session; the prefix holds an authenticated
session, so shots may show the library and the account email (`runs/**` is
gitignored) · **Time** ~2–4 min

### 2.3 — `uimatrix` — patched vs stock vs software renderer

    ./research/probes/uimatrix.sh                          # all three variants
    ./research/probes/uimatrix.sh patched-d2d              # one variant

**Measures** `scenarios/main-ui.json` (15 steps: hovers, sidebar clicks, library
clicks, arrow keys, a drag to the deck) across three variants — `patched-d2d`,
`patched-nod2d` (`d2d1=d`, JUCE's software renderer), `stock-dxgi` — scoring
per-region response on an 8×6 grid and reporting cells that never changed.

**Recorded result** (`20260813T0914*`):

| variant | interactions responding | grid cells never changed |
|---|---|---|
| patched-d2d | 3/12 | 25/48 |
| patched-nod2d | 3/12 | 25/48 |
| **stock-dxgi** | **1/12** | **37/48** |

**Read this as a comparison only.** The absolute numbers understate reality
badly and **must not be quoted as "the UI is half dead"** — the patched run's
final screenshot
(`runs/20260813T091454-rb7-ui-patched-d2d/shots/015-settle-final.png`) shows a
fully healthy app with a 13-track library and a track dragged into the deck with
waveform and beat grid. Two known flaws: coordinates are blind fractions that
mostly land in empty space, and "dead cells" counts static chrome that
legitimately never changes. **Calibrating the scenario against that screenshot is
an open harness job.**

**PASS criterion** stock must be markedly deader than patched, and the two
patched variants must be identical (the vblank path is renderer-independent).

**Readiness gate** the script requires window content to be non-uniform **and**
stable across two samples before probing. Without it, the first matrix run
probed a blank 1920×1006 canvas and every "NO RESPONSE" was our own impatience.
`blank-main-window` in `uiprobe.json` means the gate fired — that is a recorded
non-result, not a finding.

**Theme** T01 · **Needs** GUI session · **Time** ~20–25 min for all three

### 2.4 — `menuprobe` — do the top-level menus open

    ./research/probes/menuprobe.sh runs/menu-$(date +%s) 5

**Measures** clicks each top-level menu with a full state reset between attempts
(pointer off the bar, Escape twice, settle), scoring by whether a top-level
window **named `menu`** appears — a fact, not a judgement — plus full-screen RMSE
and the geometry of any new window.

**Recorded result** (T04, 5 passes):

| menu | opened |
|---|---|
| File | **0/5** |
| View | 5/5 |
| Track | 5/5 |
| Playlist | 5/5 |
| Help | 4/5 (only miss was the first attempt after launch) |

So this is a **known-failing test**: File is a hard, reproducible 0/5. A File
click creates **no window at all** — checked without `--onlyvisible`, so unmapped
windows too; a View click adds 5 (the popup plus four JUCE drop-shadow helpers) —
RMSE 0, no new log lines. That is upstream of window creation, so it is **not**
the T01 repaint bug and the dxgi patch is irrelevant to it.

**Regression criterion** View/Track/Playlist dropping below 5/5 is a new
regression. File going 0/5 → n/5 is the T04 fix landing.

**Coordinates** client-relative, read off a 300%-magnified crop: File 24,
View 72, Track 129, Playlist 191, Help 251, all at y=12. Verified against the
pixels before blaming the app.

**Theme** T04 · **Needs** rekordbox running, GUI · **Time** ~5 min for 5 passes

### 2.5 — `audiotest` — is the Sample Rate dropdown populated

    ./bin/audiotest.sh                      # launch-or-attach, navigate, capture, grade
    ./bin/audiotest.sh --no-launch          # fault rather than starting rekordbox
    ./bin/audiotest.sh --shot F.png         # grade a stored capture, drive nothing
    ./bin/audiotest.sh --keep-open          # leave Preferences open

**Measures** one 196×16 px box — the value-text area of the Sample Rate combo,
6 px inside its left edge — by peak brightness and standard deviation of real
pixels. It drives the UI (gear → Preferences → `sidebar_audio` →
`tab_configuration` → capture) because the API probes cannot see this: **an empty
combo interior is pure black**, so glyphs are unmissable, and `uiassert`'s
existing `absent` rule (`peak < dark+0.06 AND sd < 0.03`) separates the two
states with an enormous margin. `greyed` still means glyphs are present, so
**only `absent` is the regression.**

**Exit** 0 = has content · 1 = **EMPTY, the regression** · 2 = harness fault.

**Four gates, any of which yields exit 2 rather than a verdict:**

1. the captured PNG's size matches the live Preferences window geometry — proves
   we photographed the dialog and not whatever stole focus;
2. the `Audio` sidebar row is the selected one **by ≥0.10 mean margin** over the
   other five. Not theoretical: **on the View pane the Sample Rate coordinates
   land on flat panel that scores `greyed`, which would have READ AS A PASS**;
3. both section headings have glyphs — the pane actually drew;
4. the **in-shot positive control**: the Audio Device combo — same widget, same
   skin, same font, same 6 px inset, known populated — must read `active`. If the
   detector cannot see text that is definitely there, its claim that other text
   is absent is worthless.

**Calibration** references live **inside the Audio pane** (bright = the Audio
Device combo's own value text; dark = the right-hand interior of the Sample Rate
combo itself), so the threshold is immune to skin, compositor and display-profile
drift. Calibrated 2026-08-14 against `runs/AUDIOTEST/03-audio.png`, dialog
806×824; the script warns if the live dialog differs and the gates fault rather
than guess.

**Three coordinate frames, deliberately distinct** — documented in
`scenarios/regions.json`: main-window fractions; Preferences-dialog fractions
(the dialog gets no KWin shadow, so `spectacle -a` returns exactly the X
geometry, image px == window px); and the gear anchor in **pixels from the right
edge** (261, 35), because rekordbox's toolbar is right-anchored with fixed-size
icons and a fractional anchor drifts off it at any other window size.

**OCR is commentary only and never touches the verdict.** T00 recorded tesseract
silently returning nothing, which here is indistinguishable from an empty
dropdown — it would fake the exact bug being hunted. Pixels decide.

**CURRENT RECORDED RESULT: FAIL, exit 1.** `runs/AUDIOTEST/03-audio.png`,
2026-08-14 — `sample_rate_value peak=0.000 mean=0.000 sd=0.000` → `absent`,
with the Audio Device positive control reading `active` in the same shot. **The
Sample Rate dropdown is empty right now.** This is R24, and it is unexplained in
the repo record: `wasapitest` reports 48/48 accepted, so the Wine-side
`IsFormatSupported` path is healthy and the fault is somewhere between that and
the widget.

**Theme** T03 · **Needs** rekordbox running (it will launch it; ~90 s to become
usable), GUI, X11 · **Time** ~30 s attached, ~2.5 min from cold

---

# Tier 3 — controller physically connected

Everything here needs the DDJ-400 plugged in and, for the ACL, replugged at
least once since the udev rule was installed.

### 3.1 — rawmidi byte counters — the ground truth for binding

    grep -H "bytes" /proc/asound/card*/midi0

**Measures** whether a single MIDI byte has ever crossed to the hardware. This is
the least deniable measurement in the project: it is the kernel's own counter,
downstream of Wine, rekordbox, ALSA and PipeWire alike.

**Recorded state — FAILING** `Tx bytes: 0   Rx bytes: 0`, unchanged across every
session and every patch (0003, 0004, 0005, 0006, 0007).

**PASS** = `Tx bytes` moves off 0. **That has never happened.** It is the primary
milestone signal and is what STATE.md's next action is waiting on.

**Theme** T05 · **Needs** the controller · **Time** ~1 s

### 3.2 — `devwatch` — passive timeline of the binding path

    ./research/probes/devwatch.sh 1800 > runs/_devwatch/session-$(date +%Y%m%dT%H%M%S).tsv

**Measures** once per second, emitting a line only on change: rekordbox pid,
Wine's ALSA sequencer client number, whether the Wine input port is subscribed to
the DDJ-400, cumulative Tx/Rx bytes, and how many processes hold `/dev/hidraw0`.
Never touches the application — killing rekordbox to inspect it destroys the
state being inspected.

**Recorded artefact** `runs/_devwatch/session-20260813T144319.tsv`.

**PASS** `sub=yes` together with `tx` climbing. **FAIL** `sub=no` with a live
pid, or `sub=yes` with `tx` pinned at 0 (subscribed to the wrong client — this is
how the Midi Through loopback was caught).

**Note** the script finds the rawmidi node by searching for `DDJ` rather than
hardcoding `card1`, because a replug renumbers the card and a stale path reports
`Tx 0` forever, i.e. it fakes the exact bug being hunted.

**Theme** T05 · **Needs** the controller · **Time** runs as long as you ask;
default 1800 s

### 3.3 — ALSA subscription sanity, outside Wine

    aconnect -l
    aconnect 20:0 128:1        # by hand — proves ALSA permits the subscription

**Measures** whether the failure is ALSA's or Wine's. The decisive measurement in
phase 6 was `aconnect 20:0 128:1` **succeeding by hand**, which killed every
"ALSA won't allow it" theory in one command and proved Wine was passing a
PipeWire pseudo-port as the argument.

**PASS** the manual connect succeeds; `client 20: 'DDJ-400' [type=kernel,card=1]`
present; no `client 14: 'Midi Through'`.

**FAIL** `Midi Through` present → `snd_seq_dummy` is loaded (see Known Good
Configuration). Wine's client showing `Connecting To: 14:0` → it bound the
loopback and is talking to itself.

**Theme** T05 · **Needs** the controller · **Time** ~5 s

### 3.4 — `midiInOpen` trace — does rekordbox even try

    ./research/probes/rbtrace.sh midiopen '+midi,+winmm' 100
    grep -c "midiInOpen\|midiOutOpen" runs/<id>/wine.log

**Measures** whether rekordbox calls `midiInOpen` on the controller at all, which
separates "Wine refused" from "rekordbox declined".

**Recorded results:**

| run | finding |
|---|---|
| `20260813T150716-rb7-midi-open-trace` | `midiOutOpen(0) => 0`, `midiInOpen(0) => 3`, close; same for 1; gives up. `3` = `MMSYSERR_NOTENABLED` |
| `20260813T151348-rb7-midienum-patched` | **559** `midiInMessage(0, 0x080D, …)` polls, no answer |
| `20260813T154622-rb7-midiiface` | 376 size/fetch pairs, all `MMSYSERR_NOERROR`; **still no `midiInOpen`** |
| `20260813T155900-rb7-builtin-winmm-control` | builtin winmm: 301 queries, **zero opens** — proves 0007 is not a regression |

Plus, from the phase-7 audit: **859 MIDI IN enumerations against 2 OUT calls** —
an input-only retry loop, which is rekordbox's code, not JUCE's change detector.

**PASS** a `midiInOpen` on device 0 returning 0. **Never observed.**

**Theme** T05 · **Needs** the controller · **Time** ~2 min plus a 75–87 MB log

### 3.5 — factory MIDI mapping profile is intact

    ls -l "prefixes/rb7/drive_c/users/$USER/AppData/Roaming/Pioneer/rekordbox6/MidiMappings/DDJ-400.midi.csv"
    head -1 "…/DDJ-400.midi.csv"; wc -l "…/DDJ-400.midi.csv"

**Measures** that rekordbox has not overwritten the shipped 243-row factory
profile with a stub. A successful `<name>.midi.csv` load **gates `DeviceMidi`
construction entirely** (`0x1422bc470`, the only caller of the ctor
`0x1423a4d40`), failing to `"### MIDI:%s.midi.csv is not found."`

**PASS** mode `444`, header `@file,1,DDJ-400`, **243 rows**, 16562 bytes.

**FAIL** a 15-byte or 32-byte file, or a header reading
`@file,1,DDJ-400 - DDJ-400 MIDI 1`. rekordbox wrote exactly that twice; the
factory profile is now installed read-only so it cannot be stubbed again.

**Status: UNTESTED.** The read-only install was made on 2026-08-13 and **no run
has been made since** — this is STATE.md's next action, still outstanding.

**Theme** T05 · **Needs** the controller for the follow-up run · **Time** ~2 s

### 3.6 — `devicelog` — rekordbox's own words

    ./research/probes/devicelog.py runs/DEVICELOG/devicelog.txt
    # requires DeviceLogEnable=1 in rekordbox3.settings + a DeviceLog.conf

**Measures** rekordbox's internal controller-layer log, streamed to
`127.0.0.1:10001`. It would state the failure in the application's own words —
`### HID:Other:[%s] open wait for start midi.`, `MIDI input is not found`,
`@@@ Auth is Enabled : startMidiDevice`, `@@@ MIDI Disconnect by AuthReq`. The
last two are the discriminator between a Wine transport bug and a scope wall.

**Status: DOES NOT WORK.** Produced **no output across two launches**
(`runs/DEVICELOG/`, 2026-08-13). Either another precondition is missing or the
transport differs. Listed as worth one more try. **Do not count this as
coverage.**

**Theme** T05 · **Needs** the controller · **Time** ~5 min

---

# Tier 4 — a human has to look

Machines cannot adjudicate these. Every one of them has, at some point in this
project, been the thing that overturned a machine verdict — or been overturned by
one.

### 4.1 — Sample Rate dropdown populates

**Do** launch rekordbox → Preferences → Audio → select `DDJ-400 WASAPI` → open
the **Sample Rate** dropdown.

**Recorded PASS** 2026-08-13, screenshot evidence, quoted in T03, PATH-TO-GOLD
step 2b and STATE.md: **the dropdown populates and 44100 Hz is selected**, full
list offered.

**FAIL** empty field, dropdown opens to an **empty popup**. Note that clicking
Sample Rate fires **zero** `IsFormatSupported` calls — the list is built at
device-selection time, not on demand, so re-opening the dropdown proves nothing.
Re-select the device.

**Now automated as test 2.5** (`bin/audiotest.sh`, built 2026-08-14 in response
to this regression). The human check remains useful as a cross-check of the
detector, and to read the *contents* of the list — 2.5 only asserts that glyphs
exist, not that the values are sane. Note that tests 1.2 and 1.4 cover the two
Wine-side mechanisms and **both can pass while this fails**: measured
2026-08-14, `wasapitest` reports 48/48 accepted with the dropdown blank.

**CURRENT STATE: FAILING.** See 2.5.

**Theme** T03 · **Needs** a human, ~1 min

### 4.2 — sustained playback through the controller

**Do** with the DDJ-400 selected as output, load a track and play it. Listen.

**Recorded PASS, partial** human session 2026-08-13 ~08:30, **no run id**: a demo
track played with the spectrograph rendering and **audio was audible**. That was
on the default device, not confirmed through the controller.

**Status: UNCONFIRMED through the DDJ-400.** T03 is explicit: the stream opens
and the event fires, but sustained playback has never been confirmed. If it
stutters, the cause is Wine's exclusive-mode padding accounting (test 1.4), not
rekordbox.

**Theme** T03 · **Needs** a human, ears, the controller, ~3 min

### 4.3 — does a jog wheel move a deck

**Do** move a jog wheel, a fader, a pad. Watch the screen.

**Status: NEVER PASSED.** This is the project's actual milestone. Machine
proxies are test 3.1 (`Tx bytes` off 0) and test 2.1 (`--expect milestone`).

**Theme** T05 · **Needs** a human and the controller, ~1 min

### 4.4 — clean-restart config-file dialog

**Do** quit rekordbox **from its own menu**, relaunch, and see whether *"The
configuration file cannot be read. Restart with a backup file."* returns.

**Why** the dialog appeared in the first real user session after ~15 harness runs
that all ended in `kill -9` plus `wineserver -k` — an excellent way to truncate a
settings file mid-write. Both `rekordbox3.settings` and
`rekordbox3.backup.settings` were 25,889 bytes and rewritten live, so config I/O
is healthy. `rbw` now closes windows gracefully before escalating (WM_CLOSE →
10 s → TERM → 3 s → KILL).

**PASS** no dialog. That decides whether this goes in the AppDB report as a Wine
problem or as our own harness damage. **UNTESTED** — the one-minute test has
still not been run.

**Theme** T00 / T01 · **Needs** a human, ~2 min

### 4.5 — USB export to a CDJ-readable stick

**Do** export a playlist to the `REKORDBOX`-labelled FAT32 stick mapped as `E:`.

**Status: NEVER RUN. The single biggest gap between here and a Gold claim.** The
stick is formatted (msdos label, single primary FAT32, lba, labelled
`REKORDBOX`), mapped as `E:` with a device link and
`HKLM\Software\Wine\Drives E: = removable`, and `wine cmd /c dir e:\` reports
`Volume in drive e is REKORDBOX`. Export itself has never been attempted.

**Validation rule (T02)** any stick produced here is parsed **natively, outside
Wine**, with `rekordcrate` (from git — crates.io 0.3.0 is Jan 2025 and lacks the
2026 PDB read fixes) or Deep-Symmetry `crate-digger`, **before** it goes anywhere
near hardware.

**Theme** T02 · **Needs** a human, a stick, ~10 min

### 4.6 — sign-in

**Do** hand the keyboard to the user.

**Rule, absolute** credentials are never given to the harness and must not be
typed into a logged terminal. A credentials file exists at
`~/.credentials/rekordbox` and has still not been used. Synthetic probes use a
throwaway token. Screenshots would capture the email address on screen even
though `runs/**` is gitignored.

**Recorded PASS** human session 2026-08-13, "sign in successful" dialog, **no run
id**.

**Theme** — · **Needs** the user · **Time** ~2 min

---

# Known good configuration

Every item below has silently reverted at least once, and in each case the
application simply behaved as though unpatched — which looks exactly like a
brand-new bug. **Verify by measuring the installed artefact, never by
remembering that you installed it.**

## Wine patches — four PE DLLs in the prefix

| patch | DLL | marker | why |
|---|---|---|---|
| 0001 | `dxgi.dll` | `RBW-PATCH` | implements `IDXGIOutput::WaitForVBlank`; without it any JUCE app paints one frame and freezes (T01) |
| 0002 | `mmdevapi.dll` | `RBW-MMDEV` | allows event-driven exclusive streams; without it the Sample Rate list is empty (T03) |
| 0005 | `cfgmgr32.dll` | `RBW-CFGMGR` | `CM_Get_Child`/`Sibling`/`DevNode_Status` returned `CR_SUCCESS` without writing out-params (T06) |
| 0007 (PE half) | `winmm.dll` | **none — see below** | answers `DRV_QUERYDEVICEINTERFACE` for MIDI (T05) |

Verify — byte-compare **and** marker-grep, because a prefix update restores the
stock builtin over the top and a stock build loads perfectly while behaving as
though unpatched:

    for d in dxgi mmdevapi cfgmgr32 winmm; do
      cmp -s artifacts/$d-patched-native-11.15.dll \
             prefixes/rb7/drive_c/windows/system32/$d.dll \
        && echo "$d: matches artifact" || echo "$d: DIFFERS"
    done
    for pair in "dxgi RBW-PATCH" "mmdevapi RBW-MMDEV" "cfgmgr32 RBW-CFGMGR"; do
      set -- $pair
      printf '%s %s: ' "$1" "$2"
      strings -a prefixes/rb7/drive_c/windows/system32/$1.dll | grep -c "$2"
    done

**Measured 2026-08-14: all four match, all three markers present (count 1 each).**

**`winmm` has no verifiable marker.** See Tier 1.9 defect (1). The only check
available today is the byte-compare against the artifact. **GAP.**

Rebuild with `bin/build-patched-dlls.sh [dxgi|mmdevapi|cfgmgr32]`. **The script
cannot build `winmm`** — there is no entry for it in `PATCHFILE`/`SOURCEFILE`/
`MARKER`, so `bin/build-patched-dlls.sh winmm` fails on an unbound array key.
Patch 0007 has no reproducible build path. **GAP.**

Two non-obvious steps the build script handles, both of which silently produce a
null result if skipped: Wine resolves builtin PE DLLs from **its own** dll dir,
not the prefix; and Wine refuses a `native` override on any file carrying
winebuild's `"Wine builtin DLL"` marker, so the marker is blanked in place (same
length, no offsets move).

## Wine patches — the system `winealsa.so`

`winealsa.so` is a **unix** library. `DllOverrides` does not apply to it and
`WINEDLLPATH` does not cover it — measured, the refusal count was unchanged at
343/344 with `WINEDLLPATH` pointing at the staged build. It must replace the
system file.

    bin/make-private-wine.sh     # SUPERSEDED the old sudo install-system-wine-patches.sh

Verify all four patches, not just one:

    strings -a /usr/lib/wine/x86_64-unix/winealsa.so | grep -E \
      'RBW-EVENT|RBW-MIDIENUM|RBW-MIDIIFACE'
    cmp -s /usr/lib/wine/x86_64-unix/winealsa.so \
           artifacts/winedll/winealsa-0003+0004+0006+0007.so && echo "4-patch build live"

**Measured 2026-08-14:**

    RBW-EVENT build: client event gated on a free period.               (0003)
    RBW-MIDIENUM build: subscribable ports only, own client skipped.    (0006)
    RBW-MIDIIFACE build: DRV_QUERYDEVICEINTERFACE for MIDI.             (0007)
    system winealsa == 0003+0004+0006+0007 artifact
    backup present: /usr/lib/wine/x86_64-unix/winealsa.so.rbw-backup

Patch **0004** (MIDI port naming) carries **no marker** — the only proof it is
live is the port name in test 1.5. **GAP.**

**This file is overwritten by every `wine-staging` package upgrade.** That is
fail-safe by design (you get stock behaviour, not a broken hybrid) but it means
`pacman -Syu` is a regression event: re-run Tier 1 after every Wine upgrade.

## Registry values (prefix-scoped)

    wine reg add 'HKCU\Software\Wine\DllOverrides' /v dxgi      /d native /f
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v mmdevapi  /d native /f
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v cfgmgr32  /d native /f
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v winmm     /d native /f
    wine reg add 'HKCU\Software\Wine\Drivers'      /v Audio     /d alsa   /f
    wine reg add 'HKLM\Software\Wine\Drives'       /v 'e:'      /d removable /f

Verify by reading them **back out** of the registry:

    WINEPREFIX=$PWD/prefixes/rb7 wine reg query 'HKCU\Software\Wine\DllOverrides' | tr -d '\r'
    WINEPREFIX=$PWD/prefixes/rb7 wine reg query 'HKCU\Software\Wine\Drivers' /v Audio | tr -d '\r'

**`tr -d '\r'` is load-bearing.** `wine reg query` emits CRLF, and `"native" !=
"native\r"` made the checker report a correctly configured prefix as broken.

**Use the registry, not `WINEDLLOVERRIDES`.** The environment variable only
covers launch paths you remember to edit — we patched the `.desktop` file and the
user still got stock behaviour from the Plasma start menu.

## udev rule

    sudo install -m644 packaging/60-pioneer-ddj.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules
    # then REPLUG the controller

    KERNEL=="hidraw*", ATTRS{idVendor}=="2b73", MODE="0660", GROUP="audio", TAG+="uaccess"

Verify the **effect**, not the file — a rule can parse perfectly and do nothing:

    ls /etc/udev/rules.d/ | grep pioneer      # must be 60-, NOT 99-
    getfacl -p /dev/hidraw0 | grep '^user:'   # must show  user:<you>:rw-

**Measured 2026-08-14:** `60-pioneer-ddj.rules` installed, `user:user:rw-`
present, node is `crw-rw----+ root audio`.

**The `60-` prefix is load-bearing.** systemd consumes the `uaccess` tag in
`/usr/lib/udev/rules.d/73-seat-late.rules`, so a rule numbered above 73 adds the
tag after the point it is read. The file was first written as `99-` and silently
granted nothing.

## Kernel modules

    sudo modprobe -r snd_seq_dummy

Verify:

    lsmod | grep -c '^snd_seq_dummy'          # must be 0
    aconnect -l | grep -c 'Midi Through'      # must be 0

**Measured 2026-08-14: not loaded — but there is NO blacklist file.**
`/etc/modprobe.d/` contains only `firewalld-sysctls.conf`. **The module will
return on the next reboot and re-break MIDI binding.** Make it permanent:

    echo 'blacklist snd_seq_dummy' | sudo tee /etc/modprobe.d/rekordbox-wine.conf

**GAP — this is a live, unfixed regression waiting to happen.**

## Application-side state

    ls -l "prefixes/rb7/drive_c/users/$USER/AppData/Roaming/Pioneer/rekordbox6/MidiMappings/DDJ-400.midi.csv"

Must be mode `444`, 16562 bytes, 243 rows, header `@file,1,DDJ-400`. rekordbox
will otherwise rewrite it as a 15-byte stub. See test 3.5.

---

# Regressions we have actually suffered

Real incidents. Each row: what broke, how it was noticed, and which test would
have caught it. Sources are `docs/investigation/JOURNAL.md`, `docs/investigation/THEMES/*`, and `git log`.

## Configuration silently reverting

| # | Incident | How it was noticed | Test that catches it |
|---|---|---|---|
| R1 | **Launcher forgot the DllOverride.** The Plasma `.desktop` set `WINEPREFIX` but not `WINEDLLOVERRIDES=dxgi=n`, so Wine loaded the *builtin* stub and the patched dxgi was never used. Every T01 symptom returned on the big UI: sidebar cut off and click-dead, nav labels missing, rows unselectable. | Reported by the user as a **brand-new second bug**; cost a full round trip. Confirmed twice: the `.desktop` provably lacked the override, and the user watching `uimatrix.sh` saw variants 1–2 fine and variant 3 broken. Fixed properly by the **prefix registry**, not the env var. (`ce1961d`, `61ed659`) | **1.9** override read-back; **2.3** stock-vs-patched comparison; `grep RBW-PATCH runs/<id>/wine.log` |
| R2 | **A prefix update restored a stock DLL over the patched one.** Cited in `docs/PATH-TO-GOLD.md` and the `bin/rekordbox-wine` header as one of the three silent reverts that motivated `--check`. | Application behaved as unpatched; no error anywhere. | **1.9** byte-compare against the artifact (`cmp`), not "is a file present" |
| R3 | **udev rule numbered `99-` parsed fine and did nothing.** `TAG+="uaccess"` is consumed by `73-seat-late.rules`, so a `99-` rule adds it too late; `/dev/hidraw0` stayed root-only and Wine could not enumerate the controller. Worked around for one session with `setfacl`, which resets on replug. | Only found by checking `getfacl` output rather than trusting that the rule existed. (`3a33d2e`) | **Known Good Config** `getfacl /dev/hidraw0` shows `user:<you>:rw-`; **1.6** `hidtest` finds nothing |
| R4 | **`snd_seq_dummy` returns on reboot.** Removed by hand on 2026-08-13; **no blacklist file was ever written**. Still true 2026-08-14. | Not yet noticed — it has not rebooted. | **Known Good Config** `lsmod`; **1.5** `Midi Through Port-0` reappears in the device list |
| R5 | **The system `winealsa.so` is reverted by every `wine-staging` upgrade.** By design, but unannounced. | Would show as 343 refusals returning in test 1.4. | **1.4** refusal count; marker grep on `winealsa.so` |

## The instrument lying

| # | Incident | How it was noticed | Test that catches it |
|---|---|---|---|
| R6 | **Oracle returned black frames.** `ffmpeg -f x11grab` of the XWayland root returns **stddev 0.0** — the root holds no composited content and toplevels are redirected. `import` failed outright. Every run would have been adjudicated `blank-window`, i.e. a **fake confirmation of the AppDB 7.2.8 bug being hunted**. | `rbw selftest` against winecfg/notepad — known-good windows came back blank. (`e30274b`) | **0.2** selftest; **0.3** grep for X11 grabbers |
| R7 | **OCR returned nothing.** tesseract read **zero characters** from native-resolution UI text. Every text assertion failed open, which made the first selftest report that synthetic typing was broken — the typing was fine all along. One root cause, two apparent failures. | selftest notepad control. Fixed with `-colorspace Gray -resize 300% -sharpen 0x1 -normalize`. (`a70002c`) | **0.2** selftest asserts notepad echo |
| R8 | **Window discovery matched the wrong pid.** `$!` is the backgrounded subshell (70157); the window's `_NET_WM_PID` is the wine child (70235). `xdotool search --pid` never matched, and the fallback searched for a class no control window has. Every run → `no-window`. | selftest. Fixed by matching `WM_CLASS` + a pre-launch window-set diff. | **0.2** selftest `saw_window` |
| R9 | **The input oracle could not tell "dropped" from "never redrawn".** OCR of a screenshot cannot distinguish them. Run `20260812T201002` was adjudicated **`no-input`** and believed for a day; run `20260813T062048` typed a token blind into the same field and read it straight back out. **The published AppDB 7.2.14 diagnosis is very likely the same illusion.** | A hypothesis, then a clipboard read-back with a sentinel. Produced the new `stale-surface` verdict. (`2b73b71`) | **0.6** taxonomy grep; **2.2** `rbw run` clipboard oracle |
| R10 | **Full-screen fallback photographed the desktop** every poll — including browser tab titles and a WhatsApp window title — and OCR'd them into the run log. A privacy leak, and a whole-desktop stddev **masks** a genuinely blank window. | Reading the first failed control run's shots. Now: uncropped grabs require `ALLOW_FULLSCREEN_CAPTURE=1`, and only window-isolated samples may decide blankness (`indeterminate` otherwise). | **2.2** `blank_decidable` / `capture_methods` in `verdict.json` |
| R11 | **Classifier invented 12 access violations** in a log with zero real faults: unanchored `c0000005` matched inside hex arguments. | Reading `classify.md` against a log with no exceptions. | **0.5** classifier regression check |
| R12 | **`uimatrix` probed a blank canvas.** The first matrix run started clicking as soon as a large window existed; the app had not drawn yet, so every "NO RESPONSE" was our own impatience. Nearly reported. | Opening the screenshots. Now gated on non-uniform **and** stable content, recording `blank-main-window` instead of inventing numbers. | **2.3** readiness gate is the fix; assert the gate still exists |
| R13 | **`uiassert` measured the whole image.** ImageMagick's `-format %[fx:maxima]` **ignores a preceding `-crop`**: a pure-black region came back `peak=1.000 mean=0.500 sd=0.000`. Every assertion would have been meaningless while looking perfectly plausible. Now reads actual pixels via `txt:`. | Found by running the tool during calibration. (`ac36003`) | **0.4** exit-2 calibration gate; region sanity on a known shot |
| R14 | **`uiassert` region overlapped the wrong control.** `level_control` initially overlapped the bright 1/2/3/4 deck buttons and read `active` for a control that is greyed. Retightened against 3×/4× crops. | Same session. | **0.4** / **2.1** baseline must pass on `runs/CALIB/main.png` |
| R15 | **`wine reg query` CRLF broke the checker.** `"native" != "native\r"`, so a correctly configured prefix was reported as broken. | Running `--check` on a known-good prefix. | **1.9**; the `wq()` helper now strips `\r` |
| R16 | **The manifest did not record `WINEDLLOVERRIDES`.** A run differing from baseline **only** by an override was indistinguishable from baseline in its own manifest — the one variable under test went unrecorded. | Noticed while setting up the `d2d1=d` control. | **2.2** `jq .winedlloverrides runs/<id>/manifest.json` |
| R17 | **The event probe reported the wrong failure.** It broke out on the first `GetBuffer` refusal and printed "the buffer never came free"; a real client retries and gets 344/344. Reporting the first refusal would have sent the next session after a bug that is not there. | Re-reading the probe. It now prints the HRESULT and the padding. | **1.4** asserts the refusal *rate* |
| R18 | **A "fix" that worked but was wrong.** Patch 0001 v1 truncated the ms conversion and ran at **109 calls/s on a 60 Hz panel**. rekordbox repainted, so it looked correct; shipped, it would have made every JUCE app repaint at double rate. | `vblanktest` measuring the achieved rate. (`122b9dd`) | **1.1** assert 60/s, not just "no failures" |
| R19 | **`grep -q` SIGPIPE'd `strings` under `set -o pipefail`**, failing a build check that had in fact succeeded. Fixed with process substitution. | A build cycle lost. | build script uses `<(strings -a …)` throughout |
| R20 | **An audit claimed the cfgmgr32 devnode FIXMEs "fire". They do not** — the 47 `stub!` lines are `RegisterTouchWindow`, `GetUserObjectSecurity`, `PowerRegisterSuspendResumeNotification`. Two hours went into a hypothesis one `grep -c` would have killed. | Run `20260813T145820` counted the calls: **0**. | **1.7** measures with poisoned out-params instead of reading a stub list |
| R21 | **`pkill -f konsole` in a probe script killed the operator's own terminal mid-run.** | Immediately and painfully. Rule: kill by exact pid only. | — (discipline, not a test) |

## Application-side and harness-damage regressions

| # | Incident | How it was noticed | Test that catches it |
|---|---|---|---|
| R22 | **rekordbox overwrote the 243-row factory MIDI profile with a 15-byte stub**, keyed under Wine's decorated port name. A successful `.midi.csv` load gates `DeviceMidi` construction, so even a perfect MIDI transport would have bound to an empty mapping table. Factory profile now installed mode 444. | Found by a source/binary audit, verified by hand. (`3f11ec8`, `4c2ac21`) | **3.5** size/rows/mode check |
| R23 | **`kill -9` teardown truncated `rekordbox3.settings`**, producing *"The configuration file cannot be read. Restart with a backup file."* on the first real user session after ~15 harness runs. | The user hit it. `rbw` now does WM_CLOSE → TERM → KILL. (`9af17e4`) | **4.4** clean-restart test — still **UNTESTED** |
| R24 | **TODAY: the audio Sample Rate dropdown, working on 2026-08-13 (populated, 44100 Hz selected — T03, PATH-TO-GOLD step 2b, screenshot), is EMPTY again.** Broken by stacked changes across the phase-5→phase-6 work (0003–0007, the system `winealsa.so` swap, the ALSA/registry state) and unnoticed for a session. | By the user, by eye. **There is no run id, no `docs/investigation/JOURNAL.md` entry and no commit recording the incident** — the only records are the user's report, this document, and `runs/AUDIOTEST/03-audio.png`. **Root cause still not established.** The suspicious part: `wasapitest` reports 48/48 exclusive formats accepted *right now*, so the API layer looks healthy and the fault is between it and the widget. | **2.5** `bin/audiotest.sh` — built 2026-08-14 for exactly this, and it reports exit 1 today. **1.2 and 1.4 do not catch it** and must not be quoted as if they did. |

---

# How to add a new test

1. **Decide the tier by what it needs**, not by how important it is. Anything
   that reads pixels is Tier 2 at best; anything needing the hardware is Tier 3;
   anything needing a person is Tier 4. If it validates the harness itself, it is
   Tier 0 and it must be cheap enough that nobody skips it.
2. **Prefer a channel the bug does not sit on.** This project's single most
   expensive lesson, learned twice: when the thing under investigation is the
   display, the display cannot be the only witness. `Tx bytes` in
   `/proc/asound/…`, a clipboard read-back, an ALSA subscription list and a
   kernel byte counter are all better evidence than a screenshot.
3. **Record the PASS with numbers**, not adjectives. "48/48 `S_OK`",
   "343 refusals → 0", "60 calls/second", "243 rows". A pass criterion you cannot
   diff is not a regression test. Commit the transcript under `upstream/` next to
   the probe, and say which run id produced it.
4. **Make "could not run" a distinct outcome.** Exit 2, `indeterminate`,
   `blank-main-window`, `no-window-isolated` — all of these exist because a test
   that silently fails open is worse than no test. Never let a harness fault read
   as a pass.
5. **Calibrate against a reference in the same measurement**, not against an
   absolute constant. `uiassert` derives its threshold per screenshot from a
   known-bright label and a known-dark patch; `verdict.py`'s `BLANK_STDDEV` is
   only trusted because `rbw selftest` measures the floor of two known-good
   windows every time it runs.
6. **Give any patched binary a greppable marker**, and check the *installed*
   file for it. `RBW-PATCH`, `RBW-MMDEV`, `RBW-CFGMGR`, `RBW-EVENT`,
   `RBW-MIDIENUM`, `RBW-MIDIIFACE`. A C comment does not survive compilation —
   patch 0003 shipped once with a comment-only marker and there was no way to
   tell whether the build was live. Do not reuse a symbol name that already
   exists in the stock binary (see the `winmm`/`midiInMessage` defect).
7. **One variable per run**, and record the variable in the manifest. If it is
   not in `manifest.json`, the run does not prove what you think it proves.
8. **Add it here**, in the tier table and in full, with its command, its recorded
   pass numbers, its failure meanings, its theme, its needs and its time. Then
   add the citation to the relevant `docs/investigation/THEMES/T0x.md`.

---

# Coverage gaps — read this before claiming anything works

Listed explicitly, because a false sense of coverage is what got this project
into trouble.

| gap | status |
|---|---|
| **No single runner.** Every test above is invoked by hand; there is no `rbw regress`. | **GAP** |
| **The Sample Rate dropdown is EMPTY right now** and the cause is not established. Test 2.5 detects it; nothing explains it. | **FAILING — R24** |
| **Tests 1.2 / 1.4 do not cover the Sample Rate dropdown**, despite looking as though they do. Measured: 48/48 accepted with the widget blank. | known-misleading |
| **`bin/audiotest.sh`, `audio_prefs` regions and `uiassert --block` are uncommitted.** | needs a commit |
| **2.5 asserts only that glyphs exist**, not that the offered rates are correct. winealsa opens `plughw:`, so the list is optimistic (192000 offered on 44100-only hardware). | partial |
| **`winmm` (patch 0007 PE half) has no detectable marker**; `--check`'s `midiInMessage` grep passes on stock winmm (measured). | **GAP** |
| **`winmm` has no reproducible build path**; `build-patched-dlls.sh` has no entry for it. | **GAP** |
| **Patch 0004 has no marker**; only test 1.5's port name proves it is live. | **GAP** |
| **`--check` greps only `RBW-EVENT`** in `winealsa.so`; a rollback to the 0003-only build passes. | **GAP** |
| **`snd_seq_dummy` has no blacklist file**; it returns on reboot. | **GAP** |
| **`ifacetest` is not in `build-probes.sh`** and cannot be rebuilt by it. | **GAP** |
| ~~`scenarios/regions.json` `anchors` reference `bin/uidrive.sh`~~ | **STALE ENTRY, removed 2026-08-20** — `regions.json` contains no such reference and has not for some time. The gap list itself had gone out of date; the anchors are plain coordinate fractions with no script reference at all |
| **No adjudicated `rbw run` on the MAIN UI** — every recorded `window-ok` is the sign-in window. | **UNTESTED** |
| **`uimatrix` scenario coordinates are uncalibrated** blind fractions; absolute numbers must not be quoted. | known-bad metric |
| **`miditest` committed transcript is pre-patch** and no post-patch transcript exists. | **UNVERIFIED** |
| **`hidtest` has no committed transcript.** | **UNVERIFIED** |
| **`devicelog.py` produces no output** across two attempts. | **DOES NOT WORK** |
| **USB export (T02) has never been run.** | **UNTESTED** |
| **Sustained playback through the DDJ-400 unconfirmed.** | **UNTESTED** |
| **Controller binding has never succeeded** — `Tx bytes` has never moved off 0. | **NEVER PASSED** |
| **Factory `.midi.csv` read-only install untested** — no run since it was made. | **UNTESTED** |
| **Clean-restart config-dialog test never run** (1 minute). | **UNTESTED** |
| **No clean-prefix reproduction.** The current prefix has been through ~20 runs, several ending in `kill -9`. Everything here should be reproduced from scratch once before publication. | **UNTESTED** |
| **Wayland driver rows can never return `window-ok`** — XTEST is X11-only. Do not read that as an application failure. | known limitation |

## Pre-test device reset (added 2026-08-14)

Run `research/probes/usbreset.sh` **before any controller measurement**. The controller
accumulates state across a session: its MIDI byte counters only zero on
re-enumeration, its LEDs latch whatever the last host left them in, and a
half-configured audio interface persists until something tears it down.
Measuring against that state is how a run gets quietly skewed rather than
obviously wrong.

    research/probes/usbreset.sh --check    report device/ALSA/hidraw/ACL state, change nothing
    research/probes/usbreset.sh            deauthorize + reauthorize, wait for re-enumeration

It refuses to run while rekordbox is up, because resetting the bus under a
process holding the device leaves Wine's HID stack with a dead handle — which
looks exactly like the binding bug being hunted.

**It cannot power-cycle.** Measured on this laptop, the xHCI root hub reports
`wHubCharacteristic 0x000a` = *"No power switching"*, so `uhubctl` cannot help
and VBUS stays up regardless. The controller's own MCU does not reboot. Only a
physical unplug does that. What the script guarantees is a clean **host-side**
state: drivers unbound and rebound, ALSA card and `/dev/hidraw*` destroyed and
recreated, udev rules re-run, counters zeroed.

**Verify it actually did something.** Identical before/after output is also what
a no-op looks like. Confirm in `sudo dmesg`: the `hid-generic 0003:2B73:0026.NNNN`
suffix must increment and `usb 3-9: authorized to connect` must appear.

Standing observation, present on every enumeration of this device and not yet
explained: `usb 3-9: 1:1: cannot get freq at ep 0x1` and
`Quirk or no altset; falling back to MIDI 1.0`.

## Audio — PC MASTER OUT (added 2026-08-19, `docs/investigation/THEMES/T10` phases 33-45)

This is the test that would have caught the fault the project spent ten phases
on, and it takes three minutes unattended. **Tier 1.**

    bin/rbclean.sh --force
    RBW_PREFIX=$PWD/prefixes/rb7 bin/rekordbox-wine --check     # Audio settings section
    # launch, wait for the window, then:
    bin/soak.sh 140 3

**A pass is `1.00 of real time` and `teardowns in 155 s: 0`.**
Anything below 1.00 with a non-zero teardown count is the PC MASTER OUT fault
returning. `bin/soak.sh` reads the deck's own clock, because
`bin/enginerate.sh` goes VOID once rekordbox has read the whole track into
memory (~30 s in polling mode).

Preconditions, all of which the launcher now enforces and `--check` reports:

    WasapiPolling        = 1        without it: 0.05x and a rebuild every 15.9 s
    AudioBufferSize      >= 512     at 256: ~2 teardowns per 660 s
    PCSpeakerSelected_23 = 1        this test is meaningless with it off

Deeper checks, when a change touches the audio path at all:

| check | command | pass |
|---|---|---|
| the start-up rendezvous | `research/probes/barrierscope.sh 40` | **1** barrier opening, ~3.5 s after the stream starts, then none; both callback threads within 1% of each other |
| the driver boundary | `grep RBW-CLIENTS <launch log> \| tail -4` | `fail=0`, `askmax` == `AudioBufferSize`, `signal in every buffer` on **both** devices |
| the queues | `research/probes/queuescope.py <pid> 150` | `trim_count resets (= announces): 0` |
| real audio out | `parec --device=<sink>.monitor …` for 10 s | continuous, non-silent, no per-second gaps |
| performance load | `bin/loadplay.sh 3` + `research/probes/loaddeck2.sh 4`, both playing | 0 teardowns in 120 s |
| no regression with PC MASTER OUT **off** | `bin/rbset.sh PCSpeakerSelected_23 0`, relaunch, `bin/soak.sh 140` | 1.00, 0 teardowns |

Two harness traps this test has already paid for:

* **Launch rekordbox with `setsid`.** A `timeout` that kills the harness shell
  kills the whole process group and takes rekordbox with it, mid-measurement.
* **The deck play button toggles.** A script that clicks it twice leaves the
  deck paused, and every subsequent number is a measurement of silence. Verify
  against the readout, never against the click count.

## USB export (added 2026-08-19, `docs/investigation/THEMES/T02`) — **Tier 2**

Needs a FAT32 stick attached. Ten minutes, mostly unattended.

    research/probes/usbdevnode.sh                       # after plugging the stick in
    bin/rbclean.sh --force && bin/rekordbox &
    # EXPORT mode -> Devices -> the stick must be listed
    # expand it -> Yes to "Use the selected devices on rekordbox?"
    # Collection -> right-click a track -> Export Track -> <stick>
    bin/pdbcheck.py /run/media/$USER/<LABEL>/PIONEER/rekordbox/export.pdb

**A pass is:**

| check | expectation |
|---|---|
| `upstream/drivetest.exe` | the stick is `REMOVABLE`, its label is right, `fs "FAT32"`, and `nt` is non-empty |
| same, class enumeration | at least one `GUID_DEVCLASS_VOLUME` device whose `PDO` equals the stick's `nt` |
| rekordbox EXPORT → Devices | the stick is listed |
| after export | `Contents/…/<track>` byte-for-byte the source size, `PIONEER/USBANLZ/…/ANLZ0000.DAT`, `.EXT`, `.2EX` all starting `PMAI` |
| `bin/pdbcheck.py` | **structurally sound and the exported track is present** |

Two dialogs will silently swallow clicks if they are open — **"Convert to
OneLibrary"** during the first export attempt, and **"iTunes Library"** if that
source is selected. Screenshot the whole window before believing any negative.

Full `rekordcrate` / `crate-digger` validation remains required before the stick
goes into real hardware; `pdbcheck.py` is the gate, not the finish line.

## Tier 1 — the packaging gate, added 2026-08-20

Run before any AUR release. It answers "does a build from the patch series alone
lose a fix", which nothing else here asks.

    RBW_WINE_BUILD=$(mktemp -d) ./bin/build-patched-dlls.sh

**Pass** = it prints `built and verified: dxgi mmdevapi setupapi mountmgr.sys
winealsa winex11 mountmgr`. The script fails on a missing marker, on a component
`configure` dropped, and on an empty build — all three of which have previously
reported success while producing a package with no fixes in it (T11).

Then the two marker audits, which are different claims:

| must be PRESENT | in |
|---|---|
| `RBW-PATCH` | `artifacts/dxgi-patched-native-*.dll` |
| `RBW-MMDEV` | `artifacts/mmdevapi-patched-native-*.dll` |
| `PhysicalDeviceObjectName` | `artifacts/setupapi-patched-native-*.dll` |
| `RBW-EVENT`, `RBW-EVENT3`, `sending directly to` | `artifacts/winedll/winealsa.so` |
| `RBW-POPUP` | `artifacts/winedll/winex11.so` |
| `RBW-REMOVABLE` | `artifacts/winedll/mountmgr.so` |
| `RBW-BUSTYPE`, `RBW-VOLNODE` | `artifacts/winedll/mountmgr.sys` |

| must be ABSENT — debug instrumentation must never ship | in |
|---|---|
| `RBW-PERIODS`, `RBW-FORCESHARED` | `artifacts/mmdevapi-patched-native-*.dll` |
| `RBW-SEC`, `RBW-GAP` | `artifacts/winedll/winealsa.so` |

Finally, install them and prove behaviour, not just strings:

    sudo research/retired/install-system-wine-patches.sh
    bin/arm.sh release-gate WasapiPolling=1 AudioBufferSize=512 PCSpeakerSelected_23=1
    bin/loadplay.sh 3                      # row 3 -- NOT row 5, which is a 1 s sample
    bin/deckclock.sh 120

**Pass** = `1.000x` and **0 teardowns**. Use `bin/deckclock.sh`, not the rate
line from `bin/soak.sh`: that one is a pixel-sampling detector whose readings on
a healthy configuration spread from 0.74 to 1.00 (T00). `soak.sh` is still the
right tool for the teardown count.

Recorded pass: 2026-08-20, `runs/SOAK/deckclock` —
`deck 17.7s -> 138.2s = 120.5s of audio in 120.5s of wall clock = 1.000x`,
0 teardowns in 135 s, with libraries built from a pristine tree plus 0001..0009.

## Tier 1 — the co-existence and provenance gates, added 2026-08-20

Three checks that answer questions nothing else here asks. Run all three before
any release.

### 1. Does the patch series still explain the whole tree?

    bin/treediff.sh

**Pass** = exit 0. It diffs the *entire* Wine working tree against
"pristine + `upstream/patches/0*.patch`" and fails on any file not listed in
`upstream/patches/expected-divergence.txt`. Every entry in that allowlist must be
debug-only instrumentation, with a reason, reviewed by a person.

The per-patch version of this check missed a real fix **three times in one
session** — the wineusb unixlib (which existed only in a working tree), the
`RBW-MMCSS` block, and three instrumented files. An audit shaped like the patch
series cannot see a change that arrives by another route.

### 2. Is the running process actually using our libraries?

    bin/verifyloaded.sh

**Pass** = every patched library the process mapped is ours. This reads
`/proc/<pid>/maps`, not the filesystem.

It exists because the file-on-disk checks all passed while rekordbox was loading
**stock** libraries: a symlinked `ntdll.so` in the private Wine tree resolved
back to `/usr/lib/wine`, and Wine took its whole tree from the resolved path.
Checking the artifact instead of the running system is the "measurement that
cannot fail" T00 is about.

### 3. Does the system Wine remain untouched?

    for f in winealsa.so winex11.so mountmgr.so wineusb.so; do
      strings -a /usr/lib/wine/x86_64-unix/$f | grep -c RBW-
    done
    # every count must be 0

**Pass** = zero `RBW-` markers in every system Wine file. We ship a private
tree; if one of our markers appears in the distro's Wine, something has
overwritten a file owned by another package and every other Wine application on
the machine is affected. See T13.

A second, positive half: run any non-rekordbox Wine application and confirm
`bin/verifyloaded.sh <pid>` reports it on the system Wine.

**Run `bin/verifyloaded.sh` as the first step of every audio measurement.** The
harness itself was left on the system Wine when the private tree landed, and the
resulting arm reported 21 teardowns in 40 s — which reads as a broken audio fix
rather than a harness pointing at the wrong Wine. Recorded pass on the private
tree, 2026-08-20: **0.999x over 120 s, 0 teardowns in 140 s**, PC MASTER OUT on,
`runs/T13-private-tree`.
