# STATE — read this first

## Where things are — 2026-09-02

**Wine moved and it broke everything, silently. That is now fixed, rebased and
under CI.** rekordbox runs again on wine-staging 11.16; see
`docs/investigation/THEMES/T14-wine-upgrade-regression.md` for the whole account.

Arch upgraded wine-staging 11.15 → 11.16 on 2026-08-27. The launcher noticed the
version change, rebuilt its private Wine tree out of the **11.15** binaries it
had, stamped the tree "11.16", and reported every check green. Measured result:
`opengl32 wants 39 but driver has 38` — no OpenGL, so no rendering, so
"rekordbox no longer opens". The three PE artifacts correctly reported FAIL, and
the launcher launched anyway, because `bad()` was advisory outside `--check`.

Two defects, both the familiar shape — an instrument that reports success while
the thing it measures is wrong:

- **the version stamp was a lie.** `.wine-version` recorded the *system* Wine,
  not the Wine the patched binaries inside were compiled for, and
  `artifacts/winedll/` carried no version at all. Now
  `winedll/.built-for-wine` exists, `make-private-wine.sh` refuses a mixed-ABI
  tree, and the tree records both versions.
- **`FAIL` did not stop a launch.** New `blocker()`; the launch path stops and
  prints the rebuild commands.

**Series rebased onto 11.16.** Three upstream renames, all context-only:
`device->serial`→`disk_serial`, `harddisk_driver`→`disk_driver`,
`set_volume_info`'s `const char *device`→`unix_device`. No patch body changed.
The series now targets **one** Wine at a time and says so; it does **not** apply
to 11.15 (verified against a pristine tree). 11.15 is commit `9ae9739`.

**Verified after the fix:** 8/8 components built, 9/9 markers, rekordbox 7.2.18
up with the full UI and a 187-track library, `verifyloaded.sh` green, and the
window **repaints** (clock region differs over 65 s — past T01).
**Not re-measured on 11.16:** audio, USB export, DDJ-400. Do not claim those.

**Structural fix, so a Wine bump is never discovered by a user again:**
`.github/workflows/` — `build.yml` (daily + per-push Arch package build against
whatever wine-staging Arch ships, markers verified inside the built package),
`wine-watch.yml` (daily version check against `supported-wine.txt`, keeps one
issue open), `release.yml` (installable package per `v*` tag, Wine version in
every asset name), `aur.yml` (manual dispatch, gated on a secret).

### Next action

1. **Push the CI to GitHub and watch the first `build` run.** The workflows have
   never executed. `origin/master` is a curated 6-commit history whose tree is
   identical to local `389ee04`; publish by fast-forwarding it, never by pushing
   the 262-commit local history.
2. **Re-measure audio, USB export and the DDJ-400 on 11.16.** Until then
   `supported-wine.txt` claims only "applies, builds, launches, repaints", which
   is all that has been shown.
3. Then resume the pre-existing next actions below.

### Blocked on

Nothing for (1). (2) needs the controller and a FAT32 stick.

---

## Where things were — 2026-08-20 (early hours)

**The AUR cleanbuild is verified: a build from `upstream/patches/0001..0009` and a
pristine Wine tarball loses no fix.** That was the last question standing
between the work and a publishable package, and the answer is clean. Full
write-up in `docs/investigation/THEMES/T11-reproducible-build.md`.

- **Reconstruction.** 6 of the 8 touched files come back byte-identical. The
  two that differ — `mmdevapi/client.c` and `winealsa.drv/alsa.c` — differ
  **only by debug instrumentation** (`RBW-PERIODS`, `RBW-FORCESHARED`,
  `RBW-SEC`, `RBW-GAP`), and the env knobs default to exactly what the patches
  hardcode. The working tree is the series **plus** debug code, which is the
  healthy direction.
- **Markers.** Clean build of all seven patched components: 9 of 9 functional markers
  present, 4 of 4 debug markers absent.
- **Behaviour.** Clean-built libraries installed, PC MASTER OUT on:
  **1.000x, 0 teardowns** — `runs/SOAK/deckclock`.

### Three build bugs that reported success while producing a wrong package

All now guarded in `bin/build-patched-dlls.sh`: `want()` read the *function's*
`$#` so every component was skipped and the script exited 0; Wine's `configure`
drops `winex11`/`winealsa` on a missing dev package without failing; import-lib
seeding guessed `dlls/ntoskrnl/` for `libntoskrnl.a`, whose directory is
`dlls/ntoskrnl.exe/`. And the trap under them: `tools/winebuild` is a
prerequisite of every import library, so building it invalidates all 246 seeds
at once.

### A claim that was over-stated, now corrected

`docs/GOLD-STATUS.md` cited **1.00x** from `bin/soak.sh`. That instrument samples
pixels and returns **0.74 to 1.00 on configurations independently measured
healthy**, and saturates at 1.0. Replaced by `bin/deckclock.sh`, which divides
two OCR reads of the deck clock by wall time. See T00.

### One thing the cleanbuild verification missed — corrected 2026-08-20

The "no fix is lost" result was scoped to the **patch series**, and for the
series it holds. But the package needs an **eighth** component that is not a
patch: `wineusb.sys`/`wineusb.so`, spliced in from `upstream/patches/rbw-usbhcd.c`,
which exposes `\\.\HCDn`. `docs/PATH-TO-GOLD.md` step 3c already called it
*mandatory for the controller*, and it was absent from the build script, from
all three PKGBUILD stages and from the launcher's checks — so **the package as
verified yesterday would have shipped with no DDJ-400 support at all.**

Now built, marker-verified in both halves (`RBW-USBHCD`), shipped and checked.
The general lesson is in T11: a completeness audit shaped like the patch series
cannot see a fix that arrives by a different mechanism.

### Clean-room install done — 2026-08-20

`pacman -U`, then `--setup`, `--install` and first launch run **from
`/usr/bin/rekordbox-wine`** into an empty prefix: rekordbox 7.2.17 installed
unattended, window mapped in ~5 s and repainting, AlphaTheta sign-in reached.
That closes the "nothing has ever been built from a clean prefix" blocker. The
prefix is at `~/.local/share/rekordbox-wine/prefix-clean`, signed out.

Also fixed: `--install` did not exist. The README and the package's post-install
message both told users to run it — documentation written ahead of code.

### T12 opened — the real-time story, and a rule withdrawn — 2026-08-20

**`rtkit-daemon` was not installed.** Consequence chain, all measured:
`xdg-desktop-portal` advertised `MaxRealtimePriority = 0` and no time budget →
`libpipewire-module-rt`, which runs **inside rekordbox** via the ALSA plugin,
set `RLIMIT_RTTIME` to `{0,0}` (soft *and* hard, irreversible) → any thread put
on a real-time policy died instantly of `SIGXCPU`.

That is the complete explanation for T10 phase 45's "chrt kills rekordbox 3/3,
silently". **That rule is now withdrawn**: with rtkit installed the identical
`chrt -r` survives 30 s. It was never Wine and never rekordbox.

`rtkit` is installed and enabled (reversal in PATH-TO-GOLD step 12).
`RLIMIT_RTTIME` is 200 ms and PipeWire's data-loop is `SCHED_RR` 20.

**It is a prerequisite, not a cure:** at `AudioBufferSize=256` it still measured
**1 teardown in 260 s**, no better than before, because the RT priority reaches
PipeWire's thread and not rekordbox's callback threads.

Also corrected: T10 assumed PipeWire already had RT here. It did not — its
threads were `SCHED_OTHER` at nice 0, so "rekordbox gets no RT" was parity with
every audio app on this machine, not a Wine deficit.

### Next action

**Defect 11 is closed — do not implement `AvSetMmThreadCharacteristics`.**
Measured both ways (T12): a real-time policy is *fatal* with `WasapiPolling=1`
because the audio thread never blocks and is `SIGKILL`ed against a finite
`RLIMIT_RTTIME`; a nice boost to -15 changes nothing (2 teardowns in 330 s
either way, matched protocol, `bin/niceprobe.sh`). The `RBW-MMCSS` block that
lived only in the working tree is deleted — `dlls/avrt/main.c` is byte-identical
to pristine again.

The open question it leaves: **what actually causes the ~2 teardowns per 330 s
at a 256-frame buffer?** It is not scheduling priority. 512 remains the shipping
configuration and is parity with Windows for a DDJ-400, so this is a
latency-headroom question, not a correctness one.

Everything else that remains needs hardware or another machine: sign in on the
clean prefix, carry an exported stick to a real CDJ, a full DDJ-400 performance
pass, and an install on a second machine.

**Blocked-on:** a second machine; a CDJ; hands on the controller.


---

## Where things are — 2026-08-19 (late evening)

**Three things landed today, and two of them were the last two Gold blockers:
PC MASTER OUT, the File menu (which took EXPORT mode with it), and USB export.**
Nine Wine defects are now catalogued, seven of them fixed. The sections below are
in the order they were solved; the current next action is at the bottom of the
T02 section.

### PC MASTER OUT — fixed, and it needs no Wine change Root cause, mechanism
and every measurement are in `docs/investigation/THEMES/T10` phases 33-42. The fix is two rekordbox
settings, and `bin/rekordbox-wine` now applies them itself.

### The fix

    WasapiPolling   = 1        rekordbox3.settings, with the app STOPPED
    AudioBufferSize = 512      (the floor; 256 still drips one teardown / ~3 min)

    measured: 1.00 of real time, ZERO stream teardowns over 465 s continuous,
              PC MASTER OUT carrying real audio at -19.7..-22.5 dBFS RMS,
              DDJ substream RUNNING throughout, MIDI unaffected,
              and the PC-MASTER-OUT-off arm still 1.00x — no regression.

**End-to-end acceptance test passed**: settings deliberately sabotaged back to
`WasapiPolling=0 / AudioBufferSize=256`, launched through the shipping
`bin/rekordbox-wine`, which reported and repaired both under **Audio settings**;
`bin/soak.sh 140` then measured 1.00 of real time and 0 teardowns.

### Why it was broken, in one paragraph

rekordbox's per-device audio callback refuses to do anything until **every**
output device has completed `max(10, 3000/bufferPeriodMs)` callbacks — three
seconds' worth, 600 of them at 256 frames. It then keeps each device's queue
three buffers deep, trims any device running four deeper than the shallowest,
and after **100** trims less than 100 ms apart announces a device change, which
tears down and rebuilds both streams. With `WasapiPolling=0` the writer sizes
each block from `GetBufferSize()`, which under Wine is **four periods** on the
exclusive controller stream (this project's own
`0002-mmdevapi-exclusive-event-streams.patch` widens it) and one on the shared
PC endpoint. So the DDJ ran at **43** callbacks a second against the PC
endpoint's **172**: the rendezvous took 14 s instead of 3.5, and the queues then
diverged by ~129 entries a second, hitting the 100-trim threshold in under a
second — for ever, every 15.9 s. `WasapiPolling=1` makes the writer use the
device **period** instead; both devices run at 172; the divergence is zero.

    1.2 s closed + 13.9 s rendezvous + 0.87 s audio = 15.97 s, the period this
    project has chased since T03, with no unexplained term left.

### The two instruments that cracked it, after ten phases of dead ends

* **LBR call graphs.** `perf record -e cycles:u --call-graph lbr
  -k CLOCK_MONOTONIC -p <pid>` works on this process. No unwind information is
  needed, so it succeeds where DWARF gave nothing and gdb crashed the app 3 for
  3. `perf script -F brstack` goes further and says **which conditional branches
  were actually taken**.
* **Hardware execute breakpoints.** `perf record -e mem:<code addr>:x -p <pid>`
  counts how often an instruction runs, and when. Four at a time (the debug
  register limit). `research/probes/barrierscope.sh` wraps the four that matter.

New instruments this session: `research/probes/barrierscope.sh`, `bin/soak.sh`,
`bin/arm.sh`, `bin/teardownmark.py`, `research/probes/enginefind.py`, `research/probes/peimports.py`
(names every IAT slot — `call *0x1433747c8` was anonymous until now; it is
`TryEnterCriticalSection`), `research/probes/pecslock.py`.

### Also verified this session

* **Two decks playing at once**, PC MASTER OUT on: both deck clocks advancing at
  their own pitch (1.065 apart, exactly the +6.7 % on deck 2), **0 teardowns in
  120 s**, and a real mix at the PC endpoint peaking above either deck alone.
* **The driver boundary, A/B.** The rebuilt mmdevapi's `RBW-CLIENTS` reporter,
  same binary and prefix, only `WasapiPolling` differing:

        broken   DDJ: GetBuffer ok=21  fail=159314  askmax=2048  ALL ZEROS
        fixed    DDJ: GetBuffer ok=172 fail=0       askmax=256   signal in every buffer

* **rekordbox's own Preferences → Audio** renders correctly and reports
  `DDJ-400 WASAPI`, PC MASTER OUT **on**, 44100 Hz, **512 samples (11.6 ms)** —
  mid-slider, which is what a DDJ-400 user runs on Windows.
* **`bin/rekordbox-wine` end to end**: settings deliberately sabotaged, launcher
  repaired them, `bin/soak.sh` measured 1.00 and 0 teardowns.

### T04 — SOLVED, with a Wine patch

`is_window_managed()` in `dlls/winex11.drv/window.c` treated any `WS_POPUP`
carrying `WS_SYSMENU` as a window the window manager should own. JUCE's popups
carry it, so Wine handed the menu **and its four drop shadows** to KWin, which
moved the off-screen left shadow from x = -13 to x = 0; JUCE saw its own chrome
move and dismissed the menu **11 ms after mapping it**.

    upstream/patches/0005-winex11-popup-not-managed.patch      marker RBW-POPUP

With it, at x = 0, four passes each: **File 4/4, View 4/4, Track 4/4,
Playlist 4/4, Help 4/4, view-mode selector 4/4.** Screenshots in
`runs/T04-filemenu-fixed.png` and `runs/T04-modeselector-fixed.png`.
**EXPORT mode is reachable for the first time.**

### T02 — USB EXPORT WORKS

The last Gold blocker fell today. rekordbox lists the stick, initialises it, and
exports a track, and the result validates outside Wine.

**Why it was invisible.** rekordbox finds a device by intersecting two
enumerations: SetupAPI's `GUID_DEVCLASS_VOLUME` devices, and
`GetDriveType`/`QueryDosDevice`, joined on

    SPDRP_PHYSICAL_DEVICE_OBJECT_NAME == QueryDosDeviceW(letter)     ("\\Device\\Harddisk1" here)

Under Wine the SetupAPI side was empty and the property was a NULL placeholder,
so the intersection could never be non-empty. **Correction to an earlier claim in
this file:** rekordbox *does* call `SetupDiGetClassDevsW(GUID_DEVCLASS_VOLUME)` —
an earlier reading of the relay log inspected only the first six of nineteen
calls and concluded it did not. T02's day-one analysis was right.

**What made it work** (all in `docs/PATH-TO-GOLD.md` steps 8-9, with reversals):

    upstream/patches/0006  mountmgr: a removable UDisks drive is removable
    upstream/patches/0007  mountmgr: stop faking RemovableMedia and BusType
    upstream/patches/0008  setupapi: SPDRP_PHYSICAL_DEVICE_OBJECT_NAME readable
    ACL on /dev/sdX1 — without it a FAT32 stick reads as NTFS
    research/probes/usbdevnode.sh — writes the volume devnode  (STOPGAP)

**The result**, validated by `bin/pdbcheck.py` outside Wine: 4096-byte pages,
20 tables, every page range in bounds, `Contents/…/Demo Track 1.mp3` byte-for-byte
the source size, and `ANLZ0000.DAT/.EXT/.2EX` all starting `PMAI`.

### Next action — ONE thing

**Move the devnode into `mountmgr.sys`.** `research/probes/usbdevnode.sh` is a stopgap and is
labelled as one: `\Device\HarddiskN` is assigned in plug order and is not stable
across boots, so the entry is per-stick and per-session. mountmgr already knows
the NT device name, the drive letter, the label and the removability — it should
write the `Enum\STORAGE\Volume` devnode when it creates a volume and remove it
when the volume goes. The key discovery that makes this cheap is in `docs/investigation/THEMES/T02`:
**Wine's SetupAPI device-class enumeration is purely registry-driven and does not
even test `DIGCF_PRESENT`**, so no PnP device object and no bus driver is needed.

After that, the remaining Gold work is a full `rekordcrate` / `crate-digger`
parse of an exported stick, a real CDJ read, and the DDJ-400 performance pass.

**Find rekordbox's device enumerator.** Everything around it is now known and
two dead ends are already ruled out (see `docs/investigation/THEMES/T02`): the Devices-only code in
an LBR diff is just a destructor, and the browser-widget class is shared with
Explorer. Slice instead on the **Explorer-only** functions the same diff
produced — `FUN_141480440`, `FUN_141482940`, `FUN_141482f30`, `FUN_14151ae10`,
`FUN_14151d570`, `FUN_14146e320`, `FUN_14151ac80` — find the one that walks
drive letters, and breakpoint its Devices-side twin.

Explorer is the control: same widget, same window, two enumerators, and one of
them works.

### After that

**Implement `AvSetMmThreadCharacteristics` in Wine** — but understand this
first: `sudo chrt -r -p 5` on a single callback thread **kills rekordbox within
ten seconds, three times out of three**, with no Wine error and no dialog. If
Wine cannot tolerate a scheduling-policy change under a running thread, that has
to be understood before any RT work, and it may itself be the bug. It is a stub, so no
rekordbox thread has real-time priority: measured 185 `SCHED_OTHER`, 9
`SCHED_BATCH`, **zero** `SCHED_FIFO`/`SCHED_RR`, while on Windows its render
threads run under MMCSS "Pro Audio". That jitter is the only reason a 256-frame
buffer still drips one teardown every ~3 minutes, and it is the same gap that
will govern jog-wheel latency at the controller. RTKit
(`org.freedesktop.RealtimeKit1`) is already on this machine — PipeWire uses it.
Draft and evidence: `upstream/reports/NOTES-mmdevapi-buffer-widening.md`.

**Do not** raise the priority from outside: `chrt -r 20` on the two callback
threads stopped rekordbox's audio and the process did not survive (T10 phase 41).

After that, the remaining Gold work is not audio: T04 (the File menu never
opens), T02 (USB export untested), and a full DDJ-400 performance pass against
the hardware.

### Blocked on

Nothing.

### System state as left — all restored

    kernel.perf_event_paranoid = 2      kernel.kptr_restrict = 1
    kernel.yama.ptrace_scope   = 1      pipewire clock.force-rate = 0

`tracefs` is root-only here, so every `perf` command needs `sudo`. A rebuilt
`mmdevapi.dll` is installed in `prefixes/rb7` and in `artifacts/`: it is **not**
a behaviour change — it adds the `RBW_EXCL_PERIODS` / `RBW_SHARED_PERIODS`
knobs whose defaults (4 and 3) reproduce the shipping behaviour exactly, and it
is what made the root cause provable. Greppable as `RBW-PERIODS exclusive`.
`rekordbox3.settings` is left at the fixed configuration:
`WasapiPolling=1, AudioBufferSize=512, PCSpeakerSelected_23=1`.

### Rules learned this session, all cheap to obey

* Launch rekordbox with `setsid` from a harness shell. A timeout that kills the
  shell kills the whole process group, and the app dies mid-measurement — twice.
* `bin/enginerate.sh` goes **VOID** once rekordbox has read the whole track into
  memory, which it does within ~30 s in polling mode. Use `bin/soak.sh`, which
  reads the deck's own clock.
* A whole-region read of `/proc/<pid>/mem` fails on this process's big heaps.
  Scan in chunks; a silent skip hid the engine object for an hour.

## Where things are — 2026-08-17 (late evening)

**MIDI/controller: DONE.** The DDJ-400 authenticates, lights up and its jog
wheels work, on plain launches, via `upstream/patches/0004-winealsa-midi.patch`. See
`docs/investigation/THEMES/T05` phases 23-24. Do not reopen without new evidence.

**Environment: CLEANED.** `docs/PACKAGE.md` is the authoritative install list.

**Audio with PC MASTER OUT: OPEN — but it now has a number, an oracle, and a
much smaller suspect list.**

### The one-line summary of this session

The fault is **rekordbox's playback engine, not Wine's audio path**, and it is
measurable in 40 seconds without a human:

| configuration | engine rate | stream rebuilds in 40 s | run |
|---|---|---|---|
| PC MASTER OUT **off** (the daily config) | **1.00x** | 0 | `20260817T172154` |
| PC MASTER OUT **on** | **0.05x** | 5 | `20260817T172004` |

### The oracle — use it to score everything from here

    ./bin/enginerate.sh 40

reads the playing track's file offset from `/proc/<pid>/fdinfo` and compares it
against the file's own bitrate from `ffprobe`. **1.00x = fixed, 0.05x = broken,
0.00x = refused as "paused or dead", and a track that ends mid-window is
refused as void.** No OCR, no compositor, no recording, no human. Get a track
playing first with `./bin/loadplay.sh`, which proves it is playing by the same
measure rather than by looking at the screen.

### What the fault actually is — settled this session

- **The transport is stopped, not the data path.** In the broken arm the track
  file is read **only during the teardown**, 48 KiB (~1.2 s of audio) per
  15.8 s cycle. Everything phases 19-24 measured — silence at the wire, zeros in
  the WASAPI buffers, a burst before each teardown — is the shape of a transport
  that is kicked once per stream rebuild.
- **The engine completes a FIXED NUMBER OF BUFFERS per cycle (~9/s, ~140 per
  cycle) regardless of buffer size.** 256 → 0.05x, 512 → 0.11x, 1024 → 0.22x,
  2048 → 0.40x: exactly proportional. Something counts buffers and fills up; a
  stream rebuild is the only thing that empties it. A bigger buffer is NOT a
  workaround.
- **Wine is exonerated for the two-client case.** `upstream/dualclient.c` opens
  an exclusive client on the DDJ and a shared one on the PC endpoint, both
  event-driven, and Wine feeds **both at 100% of real time** — in six arms,
  including the minimum period, a 44100-forced shared client, and asking for the
  whole buffer on every event. The fault does not reproduce without rekordbox.
- **Nothing is blocked.** rekordbox's per-cycle audio thread burns 62% of a core
  in the broken arm and 66% in the healthy one. It spins; it does not park.
- **The PC stream is silent too** (`20260817T171408-dualsink`, 8% audible), which
  resolves the phase-24b inconsistency: the old "60 s of continuous music at the
  laptop monitor" was a recording of a different configuration.

### The user's track-load delay is the SAME fault (phase 25h)

`bin/loadtime.sh` times a drag-to-deck to the moment rekordbox opens the file
(from `/proc/<pid>/fd`). PC MASTER OUT **off: 0.9 s, 0.9 s** (and 0.2 s twice in
an earlier pair). **On: 2.9 s, 5.8 s** (and 7.9 s, 2.3 s). Three to nine times
slower, on the same switch — so it is not a separate fault, and the attribution
shifts slightly: it is not "the DDJ is selected", it is "a second output stream
is open". Fixing the engine stall fixes both.

### T08 CORRECTED: the frame rate does NOT decay while a track plays

This theme's headline ("55 → 37 fps over nine minutes, caused by the GPU memory
leak") was a **soak confound**. rekordbox renders at 58 fps with a track playing
and at its own 33 ms limiter otherwise; the demo track is 2:08 and the soaks are
9-27 minutes, so every previous soak spent most of its length measuring the
limiter. With `research/probes/playkeep.sh` keeping the deck playing:

| renderer | fps first → last | verdict | GPU memory |
|---|---|---|---|
| OpenGL (default) | **58.0 → 57.9** | STABLE, −0.3% | 244 → **1368 MB** |
| software (`DisableOpenGL=1`) | 41.4 → 41.9 | STABLE, +1.2% | 94 → 94 MB |

**58 fps held for ten minutes while GPU memory grew by a gigabyte** — and in a
27-minute run, **58.1 → 57.5 fps (−1.2%, STABLE) while GPU memory went 1.5 → 4.5
GB**. The leak is
real and entirely in the GL stream (proved by the software arm), but over a
set-length interval it is asymptomatic. `DisableOpenGL=1` is not a
recommendation — it is stable at 41 fps against OpenGL's 58 — and "restart
between sets" loses its stated justification.

### NEW: T09 — the desktop lost all its audio devices, and it is not rekordbox

Found before any experiment ran: `pactl` listed **no sinks at all**, and had not
since **15:26 today** — the whole second half of the previous session. Cause,
from the system journal and reproduced Wine-free in 30 seconds with
`research/probes/pwclash.sh` (`20260817T165505`): one direct `hw:` open makes PipeWire's own
open return EBUSY, the node goes `suspended -> error`, and **WirePlumber's error
handler then throws a Lua exception** (`alsa.lua:425` concatenates `node.name`,
nil for a node that never bound) so the node is never retried. The device is
gone until `systemctl --user restart wireplumber`.

Consequences: **every run made after 15:26 yesterday was made on a machine whose
PC endpoint was a null sink**, including the runs that concluded RBW-RING "broke
WASAPI". That attribution is suspect and must be re-tested. And it is a
packaging deliverable — a Gold package cannot leave the user's desktop audio
dead after a set. See `docs/investigation/THEMES/T09-pipewire-coexistence.md`.

### The WASAPI boundary is now fully accounted for (phase 25f)

Per-client counting (`debug/mmdevapi-clients-probe.diff.txt`), same launch, one
toggle:

| arm | client | GetBuffer ok/fail | frames written per second | content |
|---|---|---|---|---|
| healthy | DDJ (`plughw:1,0`) | 43 / 163,286 | 44,032 | **signal in every buffer** |
| broken | DDJ (`plughw:1,0`) | 43 / 157,221 | 44,032 | all zeros |
| broken | PC (`default`) | 262 / 0 | 44,453 | all zeros |

**Both clients are written at exactly real time in both arms.** The only
difference between working and broken is whether those frames contain signal.
Nothing in Wine's buffer contract can change that, which closes the entire
buffer-accounting line of work — phase 23's four arms, RBW-RING and the deeper
ring were all aimed at a layer that is measurably not the constraint.

The ~160,000 `AUDCLNT_E_BUFFER_TOO_LARGE` refusals a second are real and are
Wine's, but they are present **in the healthy arm too**, so they are an
efficiency bug (about a core of wasted work), not this fault.

### Phase 26-27 (2026-08-18): the fault is in the EVENT-CALLBACK path

The `+mmdevapi` channel is now usable (silencing the three hot calls drops it
from 200k lines/s to 2 KB/s), and the two arms are not subtly different:

- **PC MASTER OUT off:** zero device-layer calls in 60 s. It sets up once.
- **PC MASTER OUT on:** rekordbox **rebuilds its entire audio subsystem every
  14.7 s** — new `MMDeviceEnumerator`, full endpoint enumeration, 17 format
  probes, `Activate`/`Initialize`/`SetEventHandle`/`GetService`/`Start` on both
  clients — with **no failing Wine call anywhere** in the sequence.

**What moved the number, and what did not:**

| change | engine |
|---|---|
| shipping | 0.03-0.05x |
| give the app exactly the buffers it asks for (256 / 441 frames) | 0.05x |
| halve the exclusive buffer | 0.13x |
| serve the exclusive request as SHARED (`RBW_FORCE_SHARED`) | 0.05x |
| implement session notifications, or fail them honestly | 0.05x |
| implement MMCSS "Pro Audio" priority | 0.05x |
| signal the event on any free space instead of a full period | 0.05x |
| **the app's own `WasapiPolling=1`** (stops it using EVENTCALLBACK) | **~0.3x**, rebuild cycle mostly stops |
| PC MASTER OUT off | 1.00x |

So the fault needs **two output streams AND the event-callback path**. Taking the
application off events is the only thing that changes it qualitatively — and it
is a 6x improvement, not a cure, so it is **not** shippable.

**Wine's event cadence is separately poor and worth fixing:** the DDJ's 5.805 ms
period is signalled every **8.3 ms** on average, worst **17.5 ms** — Wine drives
the event from a per-stream software timer (`alsa_timer_loop`,
`NtDelayExecution`), not from the sound card. But it is **identical in the
healthy arm**, which plays perfectly, so it is not the differentiator.

### Phase 28 (2026-08-18): inside the application — the decoder is never asked

Traced the wake chains with `strace -f -tt -e trace=futex`:

- **The thread that decodes the track is asleep**, not slow: 160 of 160 samples
  in `futex_do_wait`, zero CPU, for 40 s.
- **Healthy:** a chain of two threads wakes it 573 times in 15 s, continuously.
  **Broken:** the equivalent chain fires **once per cycle**, 38 wakes in 4 ms,
  and its middle link sits in a 5 ms polling loop (1,411 timed waits, all
  `ETIMEDOUT`) deciding "no work" every time.
- **That single burst lands 66 ms BEFORE the teardown**, aligned on one clock
  against the DDJ substream. So the second of audio per cycle is produced as
  part of the reset — between a stream starting and the next teardown the engine
  asks for **nothing at all**.
- **Each device has its own writer thread** (`RBW-WHO`): PC 254 writes/s in
  1..256-frame blocks, DDJ 43 writes/s in 1024-frame blocks, both at real time,
  both all zeros. No inline mirroring, so neither can be blocking the other.

Two more Wine-side eliminations from the same phase:

- `dualclient spin` reproduces rekordbox's impatience — **22 million GetBuffer
  refusals a second** — and both clients still write **100% of real time**, alone
  or together. Wine does not buckle under the access pattern.
- **Padding is load-bearing**: it is the only progress number the app reads
  (320,000 calls/s; it never calls `IAudioClock`). Replacing Wine's
  `held_frames` with an exact ALSA hardware-pointer value **stopped playback
  entirely**. Reverted, and a warning against "improving" that number casually.

**So the fault is a state inside rekordbox's engine**: it runs, writes real-time
silence into both devices, and never requests audio, until a watchdog resets the
device ~14.7 s later. Nothing at the Wine boundary distinguishes the two arms.

### Phase 29 (2026-08-18): 7.2.18, and the interop layer tested to its end

**The user updated to rekordbox 7.2.18 and it behaves identically** (0.99x off /
0.05x on, six rebuilds per 40 s). The harness is now version-agnostic —
`bin/rbexe.sh` finds whatever is installed; thirteen scripts had 7.2.17
hardcoded and would have launched nothing.

**The user's key datum: PC MASTER OUT works on a real Windows machine.** So this
is an interop difference. Each candidate, measured:

| candidate | result |
|---|---|
| **rekordbox detects Wine** (`wine_get_version` is in `rekordbox.exe`) — hidden via `HideWineExports=Y`, verified working by `upstream/winedetect.c` | **no change** (0.05x on, 0.98x off) |
| Wine timer granularity — the app's own 5 ms waits | 5.07 ms median: **fine** |
| Wine's ALSA timer loop | body 17 µs, total **5804 µs against a 5805 µs period: exact** |
| event cadence made exact (`RBW_EVENT_GATE=always`: 173 events/s at 5805 µs, PC at 10000 µs) | **no change**, 0.07x |
| **the second stream made a PERFECT SINK** (`RBW_NULLSINK=1`: padding always 0, GetBuffer always succeeds, ReleaseBuffer free, driver never touched) | **no change**, 0.07x |

**That last one is the discriminator: the engine is not gated on how the second
stream behaves — it is gated on the second stream EXISTING.** A flawless,
instant, never-busy second device stalls it exactly as much as a real one.

**Therefore no change to Wine's audio path can fix PC MASTER OUT.** Buffers,
share mode, cadence, padding, session notifications, priority, backend device
and the entire behaviour of the second stream have all been substituted with the
same result. The remaining difference from Windows is above the audio path.

### Next action, in order

0. **A candidate not yet tried, and the cheapest one left:** make Wine's shared
   client match the exclusive one. The two streams run at different periods and
   buffer sizes (DDJ 1024 frames written 43x/s; PC ~170 frames written 262x/s),
   and rekordbox has to reconcile them. Forcing winealsa's shared period/buffer
   to the exclusive stream's is a small, targeted build, and `enginerate` scores
   it in 40 s.
1. **The stall is inside rekordbox's two-output path, above WASAPI.** What is
   left to instrument is what the app is told OUTSIDE the render path:
   `IAudioSessionControl::RegisterAudioSessionNotification` is a Wine **stub**
   and rekordbox calls it twice per cycle; `AvSetMmThreadCharacteristics`
   ("Pro Audio") is a stub; `GetService` for an unknown IID answers
   `E_NOINTERFACE` and logs a FIXME. Log every `GetService` IID and every stub
   hit in BOTH arms and diff them — the call that appears only with two devices
   is the lead.
2. **The 5-second thread.** Every cycle creates 8 threads that live 14.6 s plus
   exactly one that lives **5.0 s**. Name it.
3. **Re-test the RBW-RING attribution** now that the machine has sinks again —
   though phase 25f makes the patch pointless either way: no buffer change can
   fix a client that is already being served on time.
4. **T09 upstream report** for the WirePlumber crash, and a shipped rule that
   keeps PipeWire off the DDJ.
5. T08 (GPU leak) and packaging are unchanged.

### BLOCKED — the machine needs a reboot (2026-08-19)

A `perf record -e 'syscalls:sys_enter_*'` (a ~400-tracepoint glob against a
196-thread process — roughly 78,000 event descriptors) **deadlocked the kernel's
perf subsystem**. The `perf` process is stuck in `D` state inside
`perf_event_ctx_lock_nested` / `perf_read` and cannot be killed, and it is
holding rekordbox: that process cannot be killed either, sits at 196 threads,
and still owns the DDJ substream, which is in `XRUN`. Load average reached 199.

**Nothing here is a data-loss risk** — the repository, the prefix and the
installed Wine driver are all consistent, and every sysctl has been restored
(`ptrace_scope=1`, `perf_event_paranoid=2`, `kptr_restrict=1`). The settings
file is back to `PCSpeakerSelected_23=0` / `AudioBufferSize=256`, so the daily
configuration is what comes back after a restart.

**A reboot clears it.** Until then rekordbox cannot be started (the DDJ is held)
and no further measurement is possible. The full write-up and the rules that
follow from it are in `docs/investigation/THEMES/T00-instrument.md`.

### Blocked on

Nothing. Everything above reproduces unattended with the app idle or with
`bin/loadplay.sh` driving it.

### The standing rule, restated

The user's daily configuration is **PC MASTER OUT off**, and it works — verified
again at the end of this session at **0.98x with zero rebuilds**, with the
buffer size restored to the user's 256 samples. Install nothing into that path
that has not been measured in that configuration.

## ROOT CAUSE, for the record — 2026-08-17

**Splitting a MIDI SysEx across two USB transfers hangs the DDJ-400.** That is
the whole controller story: the wedges, the dark LEDs, the connect/disconnect
loop, and the intermittency that produced years of contradictory attributions in
this repo. It is not the auth content, not a licence wall, not the HCD driver,
and not lost bytes.

**Controlled proof, Wine-free, one variable** (`research/probes/authreplay.py`, back to back,
identical 66 bytes, only the number of `write(2)` calls differs):

| arm | device afterwards |
|---|---|
| one write — contiguous | **healthy** 22 s, accepted all 1,426 bytes, still re-issuing `@AuthReq` |
| two writes — 63 + 3, 5 ms apart | **dead instantly**, no inbound ever again, `amidi` blocked, Tx frozen |

**And it matches the two full-stack captures exactly:**

| run | `@AuthResponseE` at the wire | outcome |
|---|---|---|
| `…161822-gdbwire` | **one URB**, 88 B, all 66 bytes, ends `0f 09 05 f7` | `@AuthEnd`, `enableDevice`, **LEDs on, controls responding** (user-confirmed) |
| `…072840-h2-r1` | **two URBs**, 84 B (63 bytes) + 4 B (`09 05 f7`) | second URB never completes, nor any keep-alive after it; device wedged |

### Why Wine hits this and native Linux apps do not

`midi_out_long_data` (`dlls/winealsa.drv/alsamidi.c`) sends every SysEx through
the **ALSA sequencer**. The sequencer delivers a userspace SysEx to the rawmidi
port in **32-byte chunks** (`dump_var_event`), so 66 bytes arrive as 32 + 32 + 2.
The USB MIDI packetiser emits whole 3-byte packets only, so it sends 63 and
holds one byte back; whether the final packet catches the same URB is a race.
Windows delivers a `midiOutLongMsg` SysEx as one transfer, and native Linux MIDI
applications write to **rawmidi**, which is why `research/probes/authreplay.py` never once
reproduced the fault.

### Next action — write the Wine patch

Deliver SysEx contiguously instead of through the sequencer's chunked path.
Ranked options in `docs/investigation/THEMES/T05-controller.md` phase 23; the preferred one is a
rawmidi write to the destination, which is a real change to winealsa's
architecture (it uses the sequencer for routing) and deserves a fresh session.
Note that chunk *alignment* is not a fix — any event over 32 bytes is chunked,
so only contiguous delivery removes the race.

Plant an `RBW-*` marker, and validate with the instrument that already exists:
`research/probes/usbwire.sh` shows whether the 66 bytes leave as one URB or two.

Independently upstream-worthy, and unfixed: `midi_out_long_data` **discards the
return value** of `snd_seq_event_output_direct` and returns `MMSYSERR_NOERROR`
regardless — demonstrated live when it accepted 41 messages against a device
that was taking nothing.

### Settled, and not to be relitigated

- **Not licence enforcement.** `@AuthResponseE` is
  `FNV-1a-32(SeedE ‖ (SeedE XOR 68 01 31 FB))` over the device's own reply plus
  two compile-time constants — no host-derived input, zero crypto imports.
- **The full handshake works under Wine** when the message goes out contiguous:
  `@Activate` → `@AuthReq` → `@AuthChallengeA` → `@AuthResponseA` →
  `@AuthResponseE` → `@AuthEnd`, then 261 NoteOn + 36 ControlChange
  (`enableDevice`). Confirmed at the hardware.
- **A wrong auth payload does NOT harm the device** — it retries every 10 s
  indefinitely. Only framing kills it.
- **Instrument warnings.** The 0xFE wire check passes on a device that is merely
  refusing to start a new auth, and it cannot see a held-open port (now
  reported). `research/probes/authprobe.sh` renamed the MIDI port on every run until
  2026-08-17 — see T05 phase 22g; any result from before that fix is void.

---

## Phase 21 (2026-08-16, afternoon) — the wedge is explained, and the auth is NOT a licence wall

**Read `docs/investigation/THEMES/T05-controller.md` phases 20-21c before touching this.** New
instruments: `research/probes/usbwire.sh` + `research/probes/usbwire.py` (USB wire capture with URB
completion codes), `research/probes/authreplay.py` (drives the handshake from pure Linux),
`research/probes/authprobe.sh` (full-stack, both layers correlated).

### What is now MEASURED and should not be re-derived

1. **An unterminated SysEx wedges the DDJ-400, hard.** Three arms of
   `authreplay.py`, one variable. Not sending the final message: device healthy
   25 s. Sending it well-formed with a knowingly wrong payload: device healthy
   25 s, retries. Sending it with the `F7` removed: **dead from that instant**,
   needs a physical power cycle. The device does NOT punish a wrong answer; only
   broken framing kills it.
2. **The device does the handshake with any host.** `authreplay.py` answered
   `@AuthReq` with its own invented nonce and got a full 51-byte
   `@AuthResponseA` back. Steps 1-3 need nothing from Pioneer's stack, and the
   whole exchange is now readable: TLV bodies with nibble-packed payloads,
   tag 03 a fresh per-session nonce.
3. **The device has its own 10-second clock** and re-issues `@AuthReq`
   indefinitely. rekordbox's 8000 ms `timerCallback` gives up first.
4. **The kernel has been logging the wedge all along** — 2,254
   `ALSA: seq_midi: MIDI output buffer overrun` messages. They are a
   *consequence*: in run `…145128-gdbauth` they start 69 s after
   `@AuthResponseE`, which is exactly the 4096-byte rawmidi buffer filling at
   the 60 B/s keep-alive rate. That independently times the moment the device
   stopped draining to `@AuthResponseE` ±1 s.
5. **Both wire probes truncate** (64 bytes out, 32 in, the inbound one with no
   marker), so no one had ever seen the tail of either auth message. The
   "full-fidelity wire log" claim in the code and the journal is false.
6. **Wine discards the return value of `snd_seq_event_output_direct`** and
   returns `MMSYSERR_NOERROR` regardless (`alsamidi.c`, MOD_MIDIPORT branch).
   A real defect whether or not it is this bug.
7. **Interleaving is impossible from inside Wine** — one process-global mutex,
   one `write(2)`, payload linearised in userspace. That hypothesis is dead.
8. **The HCD patch is exonerated** as a cause of the wedge: it uses no libusb
   and only reads `/sys/.../descriptors`.

### Scope — this is NOT a licence wall

The `@Auth` exchange authenticates hardware the user physically owns, over
public USB descriptor data and a device-initiated nonce. Nothing here requires
forging or bypassing a cryptographic response, and the fix under investigation
is "make Wine deliver 66 bytes intact", which is ordinary transport fidelity.

### Next action

**Count the bytes of `@AuthResponseE` at the wire in a real rekordbox run.**
`./research/probes/authprobe.sh --secs 55 --label wire3 --runs 3`. Outcomes:
  - fewer than 66 bytes, or no `F7` -> **Wine transport bug, ours to fix**,
    and the mechanism is already reproduced.
  - all 66 with `F7` and clean URBs -> the stall is device-side and the next
    question is the *content* of the response.

Known intermittency: rekordbox sometimes takes the **generic** path instead
(no HCD walk, no auth, 245 LED writes on ch15) — run
`20260816T153238-wirecount-r1` did exactly that. Runs that never reach
`@AuthResponseE` are no-data, not evidence.

---

## Phase 19 (2026-08-14, evening) — the UI lag: two causes found, one fixed, one open

The user's report was *"over time the UI has become extremely laggy and is no longer
usable"* plus *"several rekordbox tray instances in my system tray"*. Both are now
measured rather than described. **Read `docs/investigation/THEMES/T07-session-lifecycle.md` and
`docs/investigation/THEMES/T08-frame-rate.md` before touching this.**

### Cause 1 — leaked sessions, and with them ntsync. FIXED.

`wineserver -k` kills the server, **not its clients**, so every previous session left
a complete set of orphans behind. Measured with rekordbox not even running: **36
orphaned processes, 3.1 GB resident, 650 CPU-seconds burned, no wineserver at all,
and 9 `rekordboxAgent` processes — which is exactly the duplicate tray icons the user
saw.** And because `wineserver` opens `/dev/ntsync` once and caches the fd for life,
a session inherited from before the modprobe never gets it: **43-65% wineserver CPU
against 1.5-1.9%**.

Fixed by `bin/rbclean.sh` (scopes by `WINEPREFIX` from `/proc/<pid>/environ` *and*
requires a wine exe, polite→TERM→KILL, then **verifies** zero survivors). Wired into
`bin/rekordbox-wine`, which now cleans before every launch, and shipped by the AUR
package along with a `modules-load.d` entry for ntsync and a `.desktop` that goes
through the launcher.

### The frame rate itself is FINE, and there is now a trustworthy instrument

`research/probes/damagefps.c` counts X DAMAGE events — no pixels, so the black-XWayland-capture
fault that voided every previous number cannot fool it. Calibrated (glxgears 60.17 vs
its own 60.505; static window 0.20) and cross-checked in-process against Wine's
`+fps` counter (29.70 external vs 29.68-29.78 internal, same run).

| state | fps | p99 gap | dropped |
|---|---|---|---|
| decks empty | 29.8 | 34.8 ms | — |
| **track loaded** | **58.1** | **18.0 ms** | **0 in 15 s** |

The 30 fps idle figure is **rekordbox's own frame limiter** (its GL thread sleeps
27-32 ms between frames; Wine's GL path contains no sleep at all), not a Wine fault.
`DisableOpenGL=1` is **not** a fix — it is measurably worse (p99 35→50 ms).

### Cause 2 — a per-session degradation. REAL, REPRODUCIBLE, NOT YET EXPLAINED.

`research/probes/uisoak.sh`, track loaded: **55.4 → 36.8 fps over nine minutes**, worst gap
31 → 60 ms, dropped frames 0.6% → 12.5%.

Refuted, with evidence:
- **Not thermal.** At the same moment the degraded session read 32.5 fps, glxgears on
  the same display read **60.00** (its own counter: 60.003). And a **fresh session
  started while the machine was still at 96 °C gave 58.17 fps with zero dropped
  frames.** A restart fully recovers it.
- **Not a leak by any *conventional* counter**: threads 196→197, fds 823→827,
  RSS 2104→2128 MB, wineserver 2%, Xwayland 0.8%, kwin 2.5%, prefix procs 15.
  (RSS is the misleading one — see below. It does not count GPU memory.)
- **The cost per frame rises**: CPU per frame roughly doubles over a run
  (2.00 → 4.25 %CPU per fps).

**IT IS A GPU MEMORY LEAK, invisible to every conventional counter.** `VmRSS` does
not account for DRM buffer objects, which is why "not a leak" was concluded: RSS moves
~1 MB per 20 s while GEM moves ~20 MB. Measured:

    GEM charged to the process   246 MB fresh -> 794 MB after 14 minutes
    rate, track loaded           ~1.2 MB/s, monotonic, no plateau
    correlation with fps         r = -0.963 over 21 samples
    the objects                  a 2048 KiB class dominates the bytes (+34 in 60 s
                                 = 68 of 71 MB). No ~8 MiB class, so NOT framebuffers.
    idle control                 same small-object churn, 2048 KiB class ENTIRELY
                                 absent, bytes 18x slower. The big leak is the
                                 loaded-deck waveform path.

**Not Wine's GL bookkeeping.** The GL calls balance (5807 glGenBuffers vs 5842
glDeleteBuffers; 191 vs 190 textures) and Wine's GL path was audited clean — it does
not wrap or track GL objects at all. **What Wine contributes is an amplifier:** all
three GL surfaces are on the offscreen child-window path, where every swap blocks in
`glXWaitForSbcOML` and then does a full-window `StretchBlt`, so rising GPU cost lands
as blocked time rather than CPU.

Refuted here: the tempting arithmetic that 2,097,152 = 2048 x 256 x 4 and the app has
a `WaveImageWidth2=256` setting. Halving it changed nothing (1.12 MB/s, still 2048 KiB).

### Next action

1. **Name the allocator of the 2 MB buffers.** Fresh session under
   `strace -e trace=ioctl` filtered to `DRM_IOCTL_I915_GEM_CREATE`, or the
   PTRACE_SEIZE single-thread sampler. Caller inside rekordbox = an application leak;
   inside `winex11.drv`/`opengl32` would overturn the audit and make it a Wine bug.
2. **Re-run the renderer matrix with a track loaded** — see the correction below; it
   has never been run under the fault. `research/probes/fpsmatrix.sh` now loads a track itself.
3. **`DisableOpenGL=1` while sampling GEM:** if growth stops, the leak is
   unambiguously in the GL stream.
4. Until fixed, the honest user-facing advice is **restart rekordbox between sets** —
   a restart provably restores 58 fps even on a hot machine.

### Also corrected this session

- **rekordbox is JUCE 7.0.9, not JUCE 8, and has no Direct2D renderer.** T01's
  attribution is wrong; the dxgi `WaitForVBlank` patch is still correct and
  load-bearing as the frame *clock*. The planned `d2d1` EndDraw frame counter could
  only ever have counted zero — it was aimed at a DLL off the frame path.
- **My own "CPU is flat, so the app is not doing more work" was wrong.** CPU *per
  frame* roughly doubles over a run; the per-thread trace that showed "flat" began
  215 s in and sampled the plateau after the ramp.
- **The renderer A/B matrix was run with BOTH DECKS EMPTY**, at the 29.8 fps idle
  limiter, where no waveform is drawn. "Every setting is a no-op" holds for idle only.
- **Phase 17's "ntsync took rekordbox from 70-138% to ~0%" is wrong.** The *server*
  went to ~2%; the *application* still holds 68-84% of a core in a zero-timeout
  `WaitForSingleObject` poll of its own (37,300 ioctl/sec, all `ETIMEDOUT`, traced to
  `rekordbox+0xfe86eb`). Deliberately not patched: it is a busy loop, so making the
  call cheaper cannot help.

---

## Phase 6 — the controller blocker is found, and it is two Wine bugs deep

**2026-08-13.** The DDJ-400 binding failure is no longer a mystery. It is a
chain, and the first link is now fixed.

**Link 1 — FIXED. Wine offered rekordbox junk MIDI devices ahead of the
hardware.** `winealsa` enumerated every port with `CAP_READ`/`CAP_WRITE`, but
the only thing it ever does with a port is `snd_seq_connect_from/to`, which need
`CAP_SUBS_READ`/`CAP_SUBS_WRITE`. PipeWire registers two ports that are readable
but *not* subscribable, and Wine also enumerated **its own** input port. Result:

    before:  MIDI OUT [0] WINE ALSA Input  [1] PipeWire-System  [2] PipeWire-RT  [3] DDJ-400
             MIDI IN  [0] PipeWire-System  [1] PipeWire-RT      [2] DDJ-400
    after:   MIDI OUT [0] DDJ-400          MIDI IN [0] DDJ-400

rekordbox walks device indices in order. The trace shows it opening output 0,
trying input 0, being refused with `MMSYSERR_NOTENABLED`, releasing the output,
repeating for index 1, and giving up — **never reaching the controller at index
2**. Run `20260813T150716-rb7-midi-open-trace`:

    midiOutOpen(0) => 0   midiInOpen(0) => 3   midiOutClose
    midiOutOpen(1) => 0   midiInOpen(1) => 3   midiOutClose

Patch `upstream/patches/0006-winealsa-enumerate-only-subscribable-midi-ports.patch`,
built, installed system-wide, verified: both lists now contain exactly the
DDJ-400 at index 0. `snd_seq_connect_from` fails because the *arguments* were a
PipeWire port — `aconnect 20:0 128:1` by hand succeeds, which is what proved
ALSA was never the problem.

**Link 2 — THE CURRENT BLOCKER. `DRV_QUERYDEVICEINTERFACE` is unimplemented for
MIDI.** With link 1 fixed, rekordbox finds the DDJ-400 and then asks Wine for its
*device interface path* — the string that would let it match this MIDI port to
the `HID\VID_2B73&PID_0026&MI_04` devnode it already identified. Run
`20260813T151348-rb7-midienum-patched`: **559 `midiInMessage(0, 0x080D, ...)`
calls**, i.e. `DRV_QUERYDEVICEINTERFACE`, in a polling loop. Wine never answers.

    dlls/winmm/waveform.c   DRV_QUERYDEVICEINTERFACE fully implemented (get_device_interface)
    dlls/winmm/winmm.c      midiInMessage / midiOutMessage — no case for it at all

That polling loop is almost certainly what the user sees as "device controls
flickering" and "connecting and reconnecting a lot".

**This also answers the question T06 was chasing.** The join between the HID
device and the MIDI port is not a devnode walk and not ContainerID — both were
tested and refuted. It is the device interface path, requested through
`DRV_QUERYDEVICEINTERFACE`. An earlier audit spotted this gap and I dismissed it
as "not the blocker, rekordbox has a fallback". **That dismissal was wrong.**

**Link 2 — NOW IMPLEMENTED (patch 0007), and it moved the wall.** `winmm` accepts
a bare device ID for both interface queries and routes them to `winealsa`, which
answers with a path derived from the real hardware. Run
`20260813T154622-rb7-midiiface`: 376 matched size/fetch pairs, all
`MMSYSERR_NOERROR`, string

    \\?\usb#vid_2b73&pid_0026&mi_03#-----#{6994ad04-93ef-11d0-a3cc-00a0c9223196}

**Link 3 — the current wall. rekordbox reads the answer and still declines.**
Control run `20260813T155900-rb7-builtin-winmm-control` proves 0007 is not a
regression: with builtin winmm it does not call `midiInOpen` either. It was
**patch 0006** that moved rekordbox off blind index-opening onto the
interface-query path. So the blocker is now the *content* of the string.

### Next action

**The string-content hypothesis is DEAD** — see T06/T05 phase 7. rekordbox never
parses the interface path; it is JUCE 7.0.9's opaque `MidiDeviceInfo::identifier`.
Do NOT run the format search in upstream/reports/NOTES-iface-format-search.md.

The real mechanism: `DeviceMidi::openDevice` matches the port by **exact
`juce::String::operator==` on `MIDIINCAPS.szPname`**, and a successful
`<name>.midi.csv` load gates `DeviceMidi` construction entirely.

1. **UNTESTED CHANGE PENDING A RUN.** rekordbox had rewritten a 15-byte
   `DDJ-400.midi.csv` over the shipped 243-row factory profile. The factory
   profile is now installed read-only (mode 444) at
   `AppData/Roaming/Pioneer/rekordbox6/MidiMappings/DDJ-400.midi.csv`.
   Launch and check for `midiInOpen`, and for `Tx bytes` in
   `/proc/asound/card1/midi0` moving off 0 for the first time.
2. If still stuck: compare the HID product string against Wine's
   `MIDIINCAPS.szPname` **byte for byte**. Trailing space, case, or
   MAXPNAMELEN truncation each defeat `operator==`.

**Watch the scope rule.** If the string it wants encodes hardware identity that
only genuine Pioneer hardware can satisfy, this becomes licence/tier enforcement
and the honest finding is "NO-GO, hard wall". Establish that before building.

### System state changed this session

- `/usr/lib/wine/x86_64-unix/winealsa.so` now carries patches 0003, 0004 **and
  0006**. Backup at `.rbw-backup`; revert with
  `sudo research/retired/install-system-wine-patches.sh --revert`.
- `prefixes/rb7` has `cfgmgr32=native` plus the patched `cfgmgr32.dll` (T06).
- New: `bin/rekordbox-wine` (run-and-play + `--check`), `packaging/PKGBUILD`.


**Updated:** 2026-08-13 · **Phase:** 5 — **DDJ-400 audio solved** · **Runs so far:** 20 + probe runs + 2 human sessions

## Phase 5 — the DDJ-400 works, and it was a Wine driver gap

**Two Wine patches and two registry writes are the entire difference between
"unusable" and "usable".** All four are already applied here.

    wine reg add 'HKCU\Software\Wine\DllOverrides' /v dxgi     /d native /f   # T01
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v mmdevapi /d native /f   # T03
    wine reg add 'HKCU\Software\Wine\Drivers'      /v Audio    /d alsa   /f   # T03

**T03, part 2 — the one that actually populated the rate list.** The ALSA switch
was necessary but not sufficient: the user retested and the list was still
empty. Driving the real preferences pane showed rekordbox calling
`Initialize(EXCLUSIVE | AUDCLNT_STREAMFLAGS_EVENTCALLBACK)` — the standard
low-latency pattern — and `dlls/mmdevapi/client.c` `adjust_timing()` refusing it
outright with `AUDCLNT_E_DEVICE_IN_USE` on an idle device. That check sits
**above** the driver, which is why swapping drivers changed nothing visible.
Patched (`upstream/patches/0002-...patch`), the Sample Rate dropdown populates and
44100 Hz is selected.

**Not finished:** the stream opens and the event fires, but `GetBuffer` for a
full period returns `BUFFER_TOO_LARGE` with padding stuck at the whole buffer.
Wine does not free a period per event. Sustained playback through the controller
is **unconfirmed**.

**T03 root cause.** rekordbox builds its sample-rate list by probing
`IsFormatSupported` in **exclusive** mode — correct API use for a DJ
application. Wine's PulseAudio driver does not implement exclusive mode at all
(`dlls/winepulse.drv/pulse.c` says so in a comment), and Wine's default driver
order puts pulse first. Every probe on every device fails, so the list is empty
for everything — exactly what was seen. winealsa does a real hardware check.

Proved with `upstream/wasapitest.c`, one variable, transcripts kept:

| driver | exclusive probes (48) | exclusive `Initialize` 44100/4ch on the DDJ-400 |
|---|---|---|
| pulse | 48× `EXCLUSIVE_MODE_NOT_ALLOWED` | refused |
| **alsa** | **48× `S_OK`** | **`S_OK`, stream ran, 66150 frames** |

**MIDI needs no fix** — `upstream/miditest.c` finds `DDJ-400 MIDI 1` on winmm IN
and OUT. Whether rekordbox *binds* the controller is untested and separate.

**Packaging deliverable:** `docs/PATH-TO-GOLD.md` — the ordered recipe with the reason
and the evidence for each step, and what an AUR package has to do.
`bin/build-patched-dlls.sh` reproduces both patched native DLLs from source.

## Phase 4 — the "second bug" was not a bug. It was the launcher.

**Resolved same day.** The broken main UI (sidebar cut off and click-dead,
nav labels missing, rows unselectable, settings pane inert) was rekordbox
running on **stock, unpatched Wine**. It was started from the Plasma launcher
menu, whose `.desktop` reads

    Exec=env "WINEPREFIX=…" wine "…rekordbox 7.lnk"

with no `WINEDLLOVERRIDES=dxgi=n`. Wine therefore resolved the *builtin* dxgi
stub from its own dll dir and the patched build was never loaded. Every symptom
is the original one-frame bug seen on a big UI instead of a small dialog: a
sidebar frozen half-drawn, labels that never paint, clicks whose feedback never
appears.

Confirmed two ways: the `.desktop` provably lacks the override, and the user
watching `research/probes/uimatrix.sh` reported the first two variants (`patched-d2d`,
`patched-nod2d`) working and the third (`stock-dxgi`) showing exactly the
reported symptoms.

**Fixed for daily use — the real fix is the PREFIX REGISTRY, not the env var:**

    wine reg add 'HKCU\Software\Wine\DllOverrides' /v dxgi /d native /f

That makes every process in the prefix load the patched DLL regardless of how it
was started, so the Plasma menu, the stock `.desktop` and any future launcher
all work. Verified by launching with **no** environment variable and confirming
the `RBW-PATCH` marker in the log.

Belt and braces, also in place: the Plasma `.desktop` sets the env override too
(backup at `*.pre-rbw-backup`), `bin/rekordbox` is a wrapper that sets it and
refreshes the patched DLL, and `~/.local/share/applications/rekordbox-patched.desktop`
is a dedicated menu entry that bypasses the `.lnk` indirection.

Setting the env var alone was NOT enough in practice — the user still got stock
behaviour from the KDE start menu, which is what prompted the registry fix.

**Lesson worth keeping:** the patch lives in the prefix and is only used with an
explicit override, so *any* launch path that forgets it silently reverts to the
broken behaviour and looks like a brand-new bug. Until this is upstream, the
override is load-bearing and easy to lose.

### Adjudicated result, and an honest note on the metric

`research/probes/uimatrix.sh`, with the readiness gate, run `20260813T0914*`:

| variant | interactions responding | grid cells never changed |
|---|---|---|
| patched-d2d | 3/12 | 25/48 |
| patched-nod2d | 3/12 | 25/48 |
| **stock-dxgi** | **1/12** | **37/48** |

The *comparison* is sound and reproduces the visual result: stock is markedly
deader than patched, and d2d vs software renderer makes no difference (as
expected — the vblank path is renderer-independent).

**The absolute numbers are not trustworthy and must not be quoted as "the UI is
half dead".** The final screenshot of the patched run shows a completely healthy
application: full menu bar, full sidebar, 13-track library, a row selected by our
own scripted click, and a track dragged into the deck with waveform and beat
grid. Two flaws in the scenario cause the understatement:

1. Coordinates were guessed as blind fractions, so most clicks land in the large
   empty region in the lower half of the window rather than on controls.
2. "Dead cells" counts any cell that never changed, which includes static chrome
   and permanently-empty background — legitimately unchanging, not broken.

**Next for the harness:** calibrate `scenarios/main-ui.json` against a real
screenshot (`runs/20260813T091454-rb7-ui-patched-d2d/shots/015-settle-final.png`)
so steps hit actual controls, and score dead regions only within the areas a
step was supposed to affect.

### Tooling built for this — `research/probes/uiprobe.py` + `research/probes/uimatrix.sh`

The old oracle answers "did a window render and echo a keystroke", which is
useless here: a window can be 95% frozen and still show a big whole-window RMSE
because one clock digit ticked. The new prober works per region and per
interaction:

- window split into an 8×6 grid; every capture reduced to per-cell means
- each scripted interaction bracketed by captures → "did the UI respond, *where*"
- cells that never change all session are reported as **dead regions**
- fractional coordinates, so a scenario survives a window resize

`research/probes/uimatrix.sh` runs `scenarios/main-ui.json` across renderer/patch variants
unattended and prints a comparison table. Verdicts: `ui-live`, `ui-partial`,
`ui-dead`.

## rekordbox actually works

**User-driven session, 2026-08-13 ~08:30. Human observation, NO run id** — the
harness did not adjudicate this and must not be cited as if it had. Reproduce it
under `rbw run` before it goes in any report.

With the patched `dxgi.dll`, the user signed in and reached the full application:

- Sign-in **succeeded** — "sign in successful" dialog.
- One error on the way in: *"The configuration file cannot be read. Restart with
  a backup file."* Clicking OK restarted the app and it recovered.
- Preferences window opened; closing it revealed **the full rekordbox UI**.
- A demo track was dragged in, **played, with the spectrograph rendering** — and
  **audio was audible**.

So this is past rendering, past input, past sign-in, past library, past decode,
past audio out. That is far beyond anything published for rekordbox 7.x.

### The config-file error is probably OUR doing, not Wine's

`rekordbox3.settings` and `rekordbox3.backup.settings` are both 25,889 bytes and
were rewritten during the session, so config I/O is healthy now. The likely
cause of the startup error is that **every one of our ~15 harness runs ended in
`kill -9` plus `wineserver -k`**, which is an excellent way to truncate a
settings file mid-write. The app did exactly the right thing and fell back.

**Test before blaming Wine:** quit rekordbox cleanly from its own menu, start it
again, and see whether the dialog returns. If it does not, this is an artefact
of the harness and the harness should learn to close windows gracefully before
resorting to signals.

## Current status — the blocker is SOLVED

**`window-ok`.** rekordbox 7.2.17 renders, accepts input, and **repaints**, on
wine-staging 11.15 with a patched `dxgi.dll`. Run
`20260813T071026-rb7-PATCHED-vblank-native`. That is past Gate 1 and is ground
nobody has reached with any rekordbox 7.x under Wine.

**Root cause, proven by construction.** `IDXGIOutput::WaitForVBlank` is a stub
returning `E_NOTIMPL`. JUCE 8 drives every repaint from a VBlank listener built
on it; the call fails instantly instead of blocking, so the vblank thread spins
at ~860 Hz and never dispatches a tick. Nothing is ever told to repaint, so the
window paints once at creation and freezes — while staying fully alive and
accepting input. Implementing the call fixes it:

| dxgi build | load path | verdict |
|---|---|---|
| unpatched | native, marker stripped | `stale-surface` (`…071216`) |
| **patched** | identical | **`window-ok`** (`…071026`) |

Patch and Bugzilla draft: `upstream/`. Prebuilt DLL: `artifacts/dxgi-patched-native-11.15.dll`.

**Not rekordbox-specific.** Any JUCE 8 app on any GPU should be affected, which
explains why the Nvidia and AMD AppDB reports describe an identical symptom.

## Superseded hypothesis

**The blocker is presentation, not input.** rekordbox 7.2.17's sign-in window is
a JUCE window rendering through Direct2D. It presents its first frame perfectly
and then never presents again. Clicks work (Cancel really does close the app)
and typed text really does land in the email field — it is simply never drawn.

**Why it never repaints (H8, strongly supported):** JUCE 8 drives every repaint
from a VBlank listener rather than from `WM_PAINT`. Wine's
`dxgi_output_WaitForVBlank` is a pure stub returning `E_NOTIMPL` — still so in
current master, so there is no version to upgrade to. JUCE's vblank thread
therefore never blocks and never succeeds: it free-runs at **~860 calls/second**
(8,615 in 10 s idle, run `…065355`) and, because the call failed, never
dispatches the vblank event to its listeners. Nothing is ever told to repaint,
so the app paints once at window creation and never again.

If that holds, **this is not GPU-specific and not rekordbox-specific** — it
should hit every JUCE 8 app under Wine, which is exactly why the AppDB reports
on Nvidia and on AMD describe the identical symptom.

This overturns our own first verdict and probably the published one too. The
AppDB 7.2.14 report of "text boxes accept no keystrokes" is very likely the same
illusion: on screen, a window that ignores every keystroke and a window that
accepts them but never redraws are identical.

Still licence/anti-tamper-free: zero exceptions, no protection or activation
error anywhere in a 1.2M-line log.

## Proven

- **The instrument works.** `rbw selftest` returns `window-ok` for notepad with
  synthetic input echoed, and `window-rendered` for winecfg. Five harness faults
  found and fixed on the way — see `docs/investigation/THEMES/T00-instrument.md`. Two of them (X11
  capture returning pure black; OCR returning nothing) would have produced a
  false `blank-window`, i.e. a fake confirmation of the very bug we are hunting.
- **`BLANK_STDDEV = 0.02` is safe**, measured: known-good windows sit at 0.41–0.46.
- **rekordbox 7.2.17 installs cleanly under wine-staging 11.15** — silent, via
  NSIS `/S`, no wizard. 1.4 GB installed. (Predicted ~95%; confirmed.)
- **It launches and renders a correct sign-in window** — 682×562, stable for the
  full 120 s, stddev 0.1179, OCR reads the sign-in copy verbatim. **Zero
  exceptions in a 960k-line log.** So it is emphatically *not* the AppDB 7.2.8
  blank-grey-and-die mode. Run `20260812T201002-rb7-baseline-x11`.
- **It is not an embedded-browser app.** No libcef / WebView2 / chrome_elf across
  99 modules. H1 disproven; the dossier's Chromium premise was wrong.
- **The sign-in UI is JUCE on Direct2D.** Window class `JUCE_19ff98b3885`, title
  `ActivationEmailWindow`, with `d2d1.dll` and `DWrite.dll` loaded. JUCE draws
  its own controls, so there are no child `EDIT` windows and `WM_CHAR` arriving
  at the top-level window is correct routing. Run `…061437`.
- **Input works. All of it.**
  - Mouse: clicking Cancel destroys the window and exits the process; clicking
    dead space does not (control). Run `…061225`.
  - Keyboard: Wine posts `WM_CHAR` to the JUCE hwnd (`+key` trace), and a token
    typed *blind* into the email field was recovered verbatim through
    Ctrl+A/Ctrl+C. Run `…062048`, with a notepad control proving the read-back
    path in the same run.
- **The window presents exactly one frame.** Byte-identical captures across
  105 s and under typing, hover, press, minimise/restore, and occlude/expose.
- **Zero `WM_PAINT`, ever.** `+msg` sliced around idle / click / keystroke: no
  `WM_PAINT` and no invalidation in any slice, while `WM_USER ×240` and
  `WM_SYSTIMER ×28` show the pump is alive. Run `…064405`.
- **The vblank thread spins rather than dying.** 8,615 `WaitForVBlank` calls in
  10 s idle; `DwmGetCompositionTimingInfo` once in the whole run; `DwmFlush`
  never. Run `…065355`. *(This corrects an earlier claim of mine that it was
  called once — Wine logs both behind a once-guard, so at default debug levels a
  million calls look exactly like one. Measure rates with `+dxgi`, not fixmes.)*
- **Not Wine's Direct2D path.** `WINEDLLOVERRIDES=d2d1=d` forces JUCE's software
  renderer (`d2d1` absent from the log, override recorded in the manifest) and
  the surface is still stale. Run `…064144`.

## Disproven

- **`no-input` — our own first verdict, retracted.** Run `…201002` called it and
  it was wrong; run `…062048` recovered the very keystrokes it said were never
  accepted. H4 (input focus/IME routing) is dead.
- **The instrument that produced it is fixed.** OCR of a screenshot cannot tell
  "dropped the keystroke" from "never redrew", so `rbw`'s input probe now clicks
  into the window and reads the text back out via the clipboard, and
  `verdict.py` has a `stale-surface` verdict for exactly this state. Confirmed
  reproducing automatically: run `20260813T062324-rb7-stale-surface-confirm`.

## Active themes

- `docs/investigation/THEMES/T14-wine-upgrade-regression.md` — **RESOLVED 2026-09-02.** A Wine
  upgrade produced a mixed-ABI install that every instrument called healthy.
  Reopen if a Wine bump ever again reaches a user before it reaches CI.

- `docs/investigation/THEMES/T00-instrument.md` — RESOLVED. Re-verify after any Wine/KDE/IM/tesseract upgrade.
- `docs/investigation/THEMES/T01-first-window.md` — **RESOLVED 2026-08-13**, root cause proven and
  patched. Reopen only if a JUCE app still freezes with the patch applied.
- `docs/investigation/THEMES/T02-usb-export.md` — **OPEN and now the biggest gap.** Stick is
  formatted and mapped as E: removable; export itself has never been run.
- `docs/investigation/THEMES/T03-audio-device.md` — **OPEN, and now well posed.** Playback works
  with one output device (1.00x). With PC MASTER OUT the engine runs at 0.05x
  and the streams rebuild every 15.8 s. Wine's two-client service is measured
  clean; the queue that fills inside rekordbox is the open question. Read
  phase 25 onward.
- `docs/investigation/THEMES/T09-pipewire-coexistence.md` — **NEW, OPEN.** One exclusive `hw:` open
  can delete a device from PipeWire for the rest of the session, because
  WirePlumber's error handler crashes on its own error message. Reproduced
  Wine-free. Repair: `systemctl --user restart wireplumber`.
- `docs/investigation/THEMES/T04-menus.md` — **OPEN.** File menu never opens (0/5); creates no
  window at all, so it is not the repaint bug.
- `docs/investigation/THEMES/T05-controller.md` — **OPEN, critical path.** Binds only under a renamed
  MIDI port and then as a GENERIC device; the toolbar MIDI/pad indicators stay
  greyed. MIX and LEVEL confirmed driving the app by the user.
- `docs/investigation/THEMES/T07-session-lifecycle.md` — **RESOLVED 2026-08-14.** Leaked sessions and
  the lost ntsync. Reopen if orphans reappear after a launch through
  `bin/rekordbox-wine`.
- `docs/investigation/THEMES/T08-frame-rate.md` — **OPEN, and it is the current lag work.** Frame rate
  is healthy in a fresh session and decays ~34% over nine minutes; GPU memory
  climbing ~1 MB/s is the live lead.

## How to run rekordbox working, today

The fix is a Wine patch, so until it is upstream the prefix needs the patched
DLL loaded as native (Wine takes builtins from its own dll dir, not the prefix,
and refuses a native override on a file carrying winebuild's "Wine builtin DLL"
marker — `artifacts/dxgi-patched-native-11.15.dll` already has that marker
rewritten):

    cp artifacts/dxgi-patched-native-11.15.dll \
       prefixes/rb7/drive_c/windows/system32/dxgi.dll
    WINEDLLOVERRIDES=dxgi=n ./bin/rbw run --recipe rb7 --label whatever

The prefix is currently left in exactly this state, so it works as-is.

## Next action

**(0) SYSTEM CHANGES MADE THIS SESSION — reversible, not yet permanent:**
  - `sudo modprobe -r snd_seq_dummy` (restore: `sudo modprobe snd_seq_dummy`).
    Needs a blacklist file to survive a reboot.
  - `/etc/udev/rules.d/60-pioneer-ddj.rules` (delete the file to revert) — NOTE: earlier revisions of this file said 99-, which does not exist. Its
    `uaccess` tag needs a controller replug or reboot to take effect; for this
    session the ACL was set directly with `setfacl`.

**(0b) NEXT ACTION — build and test `upstream/patches/0003-winealsa-signal-event-only-when-a-period-is-free.patch`.**
It is the leading explanation for the controller connect/disconnect loop. Unlike
0001 and 0002 it is in `winealsa.drv`, a unix `.so`, so it cannot be overridden
per-prefix — back up and replace `/usr/lib/wine/x86_64-unix/winealsa.drv.so`.

**(0c) HUMAN, one minute, and it closes T03.** The rate list is confirmed
populated (44100 Hz, DDJ-400 selected). The open question is playback:
  a. with the DDJ-400 selected, **does a track load** — and does it *play*, with
     audio out of the controller and no dropouts?
  b. does a jog wheel move a deck? (MIDI ports are visible; binding is untested.)
If audio is broken or stutters, the cause is almost certainly the padding gap
above, and the next step is Wine's exclusive-mode buffer accounting rather than
anything in rekordbox.
Symptom B ("unable to load track") was never independently explained — the
working assumption that it was downstream of the same failed negotiation is
inference, not evidence, so this is the test that settles it. While in there,
moving a jog wheel would also settle whether the controller *binds*, which is
untested and is a different question from MIDI ports being visible.

**(1) File it upstream — this is now the main deliverable.** Draft and patch are
written (`upstream/reports/bugzilla-dxgi-waitforvblank.md`,
`upstream/patches/0001-dxgi-implement-WaitForVBlank.patch`). Two things must be done by
a human first:
  a. **Search Bugzilla by hand for duplicates** — bugs.winehq.org is behind
     Anubis and refuses automated fetches, so this could not be checked.
     Try `WaitForVBlank`, `dxgi vblank`, `JUCE repaint`, `IDXGIOutput`.
  b. Decide whether to send the patch to wine-devel as well as attaching it.

**(2) DONE, better than planned.** Instead of hunting a second JUCE app (whose
JUCE version cannot be verified from outside anyway), `upstream/vblanktest.c` is
a standalone reproducer that demonstrates the API defect with no toolkit, no GUI
and no proprietary software: 200 calls, `E_NOTIMPL`, 0 ms on stock Wine vs
`S_OK` at 60/s patched. Builds with clang against Wine's own headers, no root.
The report's "all JUCE 8 apps" scope is now explicitly labelled as an inference
from one tested app rather than asserted. A second JUCE app would still be nice
to have but is no longer load-bearing.

**(3) DONE — and it works.** Signed in, full UI, track plays with waveform and
audio. The AppDB 7.2.8 "blank main window, dies after Importing…" failure did
**not** reproduce here. Remaining sub-steps:
  a. Clean-restart test for the config-file dialog (above). One minute, and it
     decides whether that goes in the AppDB report as a Wine problem or as our
     own harness damage.
  b. Re-run the whole thing under `rbw run` so there is an adjudicated
     `window-ok` on the *main* UI, not just the sign-in window. Human
     observations are not citable evidence in this project.
  c. Then **T02, USB export** — the actual goal. Needs a FAT32 stick.

**(4) AppDB submissions — drafted, unfiled** (`upstream/reports/appdb-rekordbox-7217.md`):
a test report for 7.2.17 on wine-staging 11.15 / Intel Iris Xe, and a correction
to iId=43369's "accepts no keystrokes" diagnosis. Both need a logged-in AppDB
account, so they are yours to post.

**(5) 6.8.7** is now much lower priority. It was the fallback target for a
blocker that no longer exists.

## Blocked on

- Nothing right now — steps (1a)–(4) need no human and no credentials. Step (1b)
  needs a Wine rebuild (disk + ~1h compile), so confirm before starting it.
- **Human, NEXT:** the AlphaTheta sign-in. The window now repaints, so this is
  no longer a blind sign-in — you can see what you type. This is the one step
  that unblocks everything downstream:
  credentials are never given to the harness and must not be typed into a logged
  terminal. Every probe uses a throwaway token.
  - Credentials are held by the user outside this repository. They are never
    given to the harness and never typed into a logged terminal.
    **Hand over the keyboard.** Note that screenshots would capture the email
    address on screen, so `runs/**` stays gitignored.
    echo, `xdotool type --file` from stdin. `runs/**` is gitignored, but
    screenshots would still capture the email address on screen.
- **Human, NEXT:** a spare FAT32 USB stick — T02, and now the critical path.
- **Note:** the prefix now holds an **authenticated session**. Harness runs from
  here will screenshot a signed-in app, so shots may show the library and the
  account email. `runs/**` is gitignored so it stays local, but do not paste run
  screenshots into a public report without checking them first.

## Assets on hand

- `artifacts/Install_rekordbox_x64_7_2_17.zip` — supplied direct from
  rekordbox.com as a baseline reference. Pinned in `recipes/rb7.recipe` by
  sha256 `518fb7d1…b8b181`; inner payload `Install_rekordbox_x64_7_2_17.exe`,
  659536536 bytes, dated 2026-07-07. `rbw install` refuses to proceed on a
  hash mismatch.
- 6.8.7 is not downloaded yet; its CDN URL is in `recipes/rb6.recipe`.
- `prefixes/rb7` is built and rekordbox 7.2.17 is installed in it (1.4 GB) at
  `drive_c/Program Files/rekordbox/rekordbox 7.2.17/rekordbox.exe`. wine-mono and
  wine-gecko are installed, so .NET is not a confound.
- Installing rekordbox needs **no clicks**: NSIS `/S`, then send `Return` to the
  "Please select a language" dialog, which `/S` does not suppress.

## Time spent

| Session | Date | Hours | Outcome |
|---|---|---|---|
| 00 | 2026-08-12 | — | Scaffolding built. No experiments run. |
| 01 | 2026-08-12 | ~1.0 | Oracle built and validated against winecfg/notepad. 5 harness faults fixed (T00). No rekordbox run yet. |
| 02 | 2026-08-12 | ~0.8 | 7.2.17 silent-installed (NSIS `/S` + one Return on the language dialog). First baseline: renders, no crash, `no-input`. H1 disproven. |
| 03 | 2026-08-13 | ~1.5 | **GATE 1 PASSED.** `no-input` retracted (input always worked); root cause found and then **proven by construction** — `IDXGIOutput::WaitForVBlank` is an `E_NOTIMPL` stub, starving JUCE 8's vblank-driven repaint. Patched `dxgi.dll` → `window-ok`. Wine patch + Bugzilla draft written. Harness input oracle rebuilt around clipboard read-back; new `stale-surface` verdict. 15 runs. |

**Time box:** ~3.4h spent. Gate 1 passed well inside the ~6h box, and the 6.8.7
fallback is no longer needed for it. Remaining budget goes to filing upstream
and to Gate 2 (a working library + USB export). Hard ceiling 25h or two
consecutive failed gates — neither is close.
