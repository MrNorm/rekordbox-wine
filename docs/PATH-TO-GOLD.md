# PATH TO GOLD — everything needed to make rekordbox 7.2.17 work on Linux

This is the packaging-facing document: the ordered, reproducible set of steps
that takes a bare Arch install to a working rekordbox, with the reason for each
step and the run id that proves it. It exists so the result can be turned into
an AUR package by someone who was not here for the investigation.

Everything below has been executed and observed on this machine. Where a step is
reasoned but not yet demonstrated it says so explicitly — those are the gaps
between here and an actual Gold rating.

**Tested on:** Arch Linux, wine-staging 11.15, Intel Iris Xe / Mesa 26.1.6,
KDE Plasma on Wayland (XWayland), PipeWire 1.6.8, rekordbox 7.2.17,
Pioneer DDJ-400.

---

## Wine version, and the system changes made on 2026-09-02

**The whole table below was measured on wine-staging 11.15. On 2026-09-02 the
project moved to 11.16 and only two of those rows have been re-measured there
(the window renders, and it repaints). Everything else on 11.16 is unproven.**

Arch upgraded wine-staging 11.15 → 11.16 on 2026-08-27, which broke the install
silently — see `docs/investigation/THEMES/T14-wine-upgrade-regression.md`. The
patch series is now rebased onto 11.16 and does **not** apply to 11.15.

System-level changes made this session, with their reversals:

| change | reversal |
|---|---|
| replaced package `rekordbox-wine 0.2.0-1` with `rekordbox-wine-git 0.2.0.r7.ga8cd0da-1` | `sudo pacman -R rekordbox-wine-git` then reinstall the old package file |
| rebuilt `~/.local/share/rekordbox-wine/wine` against 11.16 | `bin/make-private-wine.sh` after checking out the series for your Wine |
| `prefixes/rb7` system32 dxgi/mmdevapi/setupapi replaced with 11.16 builds | the launcher rewrites them on every start; previous copies are in `artifacts/removed-from-prefix/` |

No `sudo` beyond the package swap; no udev, modprobe or kernel changes.

## Status at a glance

**Refreshed 2026-08-17 (night); measured on wine-staging 11.15.** Every row is a
measurement, and the rows that changed are marked.

| capability | state | evidence |
|---|---|---|
| installs unattended | works | NSIS `/S` + one Return |
| window renders and repaints | **needs the dxgi patch** | `20260813T071026` vs `…071216` |
| keyboard and mouse input | works | `…062048` |
| sign-in | works | human session 2026-08-13 |
| library, waveform, playback | works | human session 2026-08-13 |
| audio out, default device | works | shipped config |
| audio out, DDJ-400 exclusive | **needs the ALSA driver + the mmdevapi patch** | `upstream/wasapitest-output-*.txt` |
| sample-rate list populated | **needs both**; confirmed populated, 44100 selected | screenshot, 2026-08-13 |
| event-driven exclusive stream | **works** *(was "partial")* — sustains at 1.00x real time, no rebuilds | `20260817T172154-enginerate` |
| **playback engine keeps real time** | **works** — 1.00x, verified again at session close | `bin/enginerate.sh` |
| **PC MASTER OUT (controller + laptop speakers together)** | **BROKEN** — engine drops to 0.05x, streams rebuilt every 15.8 s | `20260817T172004-enginerate`, T03 phase 25 |
| **track load time** | works (0.9 s) / **3-9x slower with PC MASTER OUT on** | `bin/loadtime.sh` |
| controller MIDI ports visible | works | `miditest`, 2026-08-13 |
| controller identified by the app | **needs a udev rule** (HID) + the HCD driver | T05, `hidtest` |
| **controller actually driving decks** | **works** *(was "partial/generic")* — auth, LEDs, jog wheels, on a plain launch | T05 phases 23-24, user-confirmed |
| UI frame rate | **works** — 58 fps with a track playing | T08, `bin/damagefps` |
| **UI frame rate over a long session** | **works** *(was "degrades — restart between sets")* — 58.1 → 57.5 fps over 27 minutes | T08, 2026-08-17; the old finding was a soak confound |
| GPU memory leak | **real but asymptomatic** — ~1.9 MB/s, 4.5 GB in 27 min, no frame-rate cost | T08 |
| a clean session at every launch | **needs `bin/rbclean.sh`** — otherwise orphans accumulate and ntsync is lost | T07 |
| **desktop keeps its audio devices** | **needs the launcher's repair** — an exclusive `hw:` open can cost PipeWire the device permanently | T09, `research/probes/pwclash.sh` |
| USB export to a stick | **untested — blocked on a FAT32 stick** | T02 |
| File menu | **broken** | T04, 0/5 opens |

Two Wine patches and two prefix registry settings account for every difference
between "unusable" and "usable".

**A third thing accounts for the difference between "usable" and "usable an hour
later": `/dev/ntsync` must be loaded *before the wineserver starts*, and the
prefix must not be carrying processes from previous sessions.** See Step 0.

---

## Step 0 — start from a clean session, with ntsync loaded (mandatory for performance)

This is first because it is the step whose absence looks exactly like "the
application is just slow", and because it is invisible: nothing prints a warning.

**`wineserver -k` kills the server, not its clients.** Every previous session
therefore leaves a full set of orphans — `services.exe`, `explorer.exe`,
`rpcss.exe`, two `winedevice.exe`, and a whole `rekordboxAgent` Electron tree,
which is what puts a rekordbox icon in the system tray. Measured on 2026-08-14
with rekordbox not even running: **36 orphaned processes, 3.1 GB resident,
650 CPU-seconds burned, and three duplicate tray icons**
(`runs/CLEANDOWN/20260814T210239-before.txt`).

**And a stale wineserver never gets ntsync.** `wineserver` opens `/dev/ntsync`
once at startup and caches the fd for life (`wine/server/inproc_sync.c`:
`static int fd = -2`). It never retries. Without it every Windows wait becomes a
server round-trip:

| | without ntsync | with ntsync |
|---|---|---|
| wineserver CPU, app idle | **43-65%** | **1.5-1.9%** |

    sudo modprobe ntsync                                  # once, now
    echo ntsync | sudo tee /etc/modules-load.d/rekordbox-wine.conf   # every boot
    bin/rbclean.sh                                        # before every launch

`bin/rekordbox-wine` runs the cleandown itself, so a user who uses the launcher
never has to know any of this. The AUR package ships both the script and the
`modules-load.d` entry.

Verify — this must print `0`, and `pgrep -x wineserver` must be empty:

    for p in /proc/[0-9]*; do tr '\0' '\n' 2>/dev/null < $p/environ \
      | grep -q "WINEPREFIX=$WINEPREFIX" && echo ${p#/proc/}; done | wc -l

---

## Step 1 — a patched `dxgi.dll` (mandatory; nothing works without it)

`IDXGIOutput::WaitForVBlank` is a stub returning `E_NOTIMPL` in Wine. JUCE —
rekordbox 7.2.17 is built on **JUCE 7.0.9** — drives every repaint from a
`VBlankDispatcher` listener rather than from `WM_PAINT`. The stub never blocks, so
the vblank thread spins at ~860 Hz and never dispatches a tick, and the application
paints exactly one frame and then freezes while still processing input.

(An earlier version of this document said JUCE 8 and attributed the rendering to
Direct2D. Both are wrong, measured from the binary's RTTI and import table: there is
no Direct2D renderer in it at all, and `rekordbox.exe` imports exactly one symbol
from `dxgi.dll` — `CreateDXGIFactory`. dxgi is this application's frame **clock**,
never its renderer. The fix is unaffected; the scope of the upstream report is: it
applies to any JUCE 7.0.x-or-later application using `VBlankAttachment`, not
specifically to JUCE 8.)

    bin/build-patched-dlls.sh dxgi          # -> artifacts/dxgi-patched-native-<ver>.dll

That script is the whole recipe, including the two steps that silently produce a
null result if you skip them:

- Wine loads builtin PE DLLs from **its own** dll directory, not from the
  prefix. Copying a patched dxgi into the prefix and launching normally uses the
  stock one and looks like "the patch does not work".
- Wine ignores a `native` override for any file carrying winebuild's
  `"Wine builtin DLL"` marker string, so the marker has to be blanked.

Neither failure prints anything. The patch therefore carries a deliberate
`FIXME("RBW-PATCH ...")`, so "is my build actually loaded" is
`grep RBW-PATCH wine.log` rather than a guess.

Install it, and make the override survive every launch path:

    cp artifacts/dxgi-patched-native-11.15.dll \
       "$WINEPREFIX/drive_c/windows/system32/dxgi.dll"
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v dxgi /d native /f

**Use the registry, not `WINEDLLOVERRIDES`.** The environment variable only
covers launch paths you remember to edit. We patched the `.desktop` file and the
user still got stock behaviour from the Plasma start menu, reported it as a new
bug, and it cost a whole round trip to work out that it was the launcher. The
registry setting applies to every process in the prefix however it was started.

Upstream: `upstream/patches/0001-dxgi-implement-WaitForVBlank.patch`, report draft in
`upstream/reports/bugzilla-dxgi-waitforvblank.md`, standalone reproducer
`upstream/vblanktest.c` (no GUI, no toolkit, no proprietary software).

**For a package:** either ship a patched wine (`wine-rekordbox`) or build the
single DLL as above at install time. The DLL approach is far cheaper and is what
`bin/build-patched-dlls.sh` does — it needs the matching Wine source tarball, a
`./configure`, and `make dlls/dxgi`, not a full Wine build.

---

## Step 2 — the ALSA audio driver (mandatory for any DJ controller)

**Symptom:** every audio device lists an empty sample-rate dropdown, and
selecting the DDJ-400 as output stops tracks loading.

**Cause:** rekordbox builds its rate list by probing
`IAudioClient::IsFormatSupported` in **exclusive** mode — which is the correct
thing for a DJ application to do, and is what the API is for. Wine's PulseAudio
driver does not implement exclusive mode at all:

    dlls/winepulse.drv/pulse.c, pulse_is_format_supported()
        /* This driver does not support exclusive mode. */
        if (params->share == AUDCLNT_SHAREMODE_EXCLUSIVE)
            params->result = AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED;

Wine's default driver order puts pulse first, so this is what everyone gets out
of the box. The ALSA driver does a real hardware check
(`dlls/winealsa.drv/alsa.c`, `alsa_is_format_supported()`) and answers properly.

Measured with `upstream/wasapitest.exe`, one variable changed between runs:

| driver | `IsFormatSupported` exclusive, 6 rates × 2 channel counts × 4 depths | `Initialize` exclusive 44100/4ch on the DDJ-400 |
|---|---|---|
| pulse (default) | 48/48 `AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED` | `AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED` |
| **alsa** | **48/48 `S_OK`** | **`S_OK`, stream started, 66150 frames written** |

The fix:

    wine reg add 'HKCU\Software\Wine\Drivers' /v Audio /d alsa /f

This is prefix-scoped, so it does not disturb any other Wine application.
Ordinary playback still goes through PipeWire, because winealsa's `default`
endpoint is ALSA's default PCM, which is PipeWire. Selecting
`Speakers (Out: DDJ-400 - USB Audio)` gets direct hardware access instead.

Notes for packaging:

- winealsa enumerates every card as a separate endpoint, so the device list
  becomes longer and more literal (`Out: sof-hda-dsp - HDMI 1` and so on). This
  is a cosmetic regression versus pulse and worth mentioning in a package
  description.
- winealsa opens `plughw:<card>,<dev>`, i.e. through ALSA's conversion layer, so
  it answers `S_OK` for rates the hardware cannot do natively (the DDJ-400 is
  44100-only but 192000 is accepted). Functionally fine — ALSA converts — but it
  means the rate list is optimistic rather than a true hardware capability list.
- If PipeWire is actively streaming to the controller, a direct open can
  contend. Freeing the card avoids it entirely:
  `pactl set-card-profile alsa_card.usb-Pioneer_DJ_Corporation_DDJ-400_------00 off`
  Not needed in our testing — the exclusive stream opened with PipeWire holding
  the card on its `pro-audio` profile — so treat it as a fallback, not a step.

Upstream: this is a genuine Wine gap worth reporting.
`upstream/wasapitest.c` is the reproducer and needs no proprietary software.

**The ALSA driver alone is not enough.** It makes `IsFormatSupported` answer
honestly, but the rate list stayed empty until step 2b as well. Do both.

---

## Step 2b — a patched `mmdevapi.dll` (this is the one that populates the list)

With the ALSA driver in place, rekordbox's rate probes all returned `S_OK` and
the dropdown was *still* empty. A `+mmdevapi` trace of the real application
showed why — after the probes it calls:

    IAudioClient::Initialize(EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                             duration = period = 58050, float32)

which is the standard low-latency pattern for professional audio on Windows. In
`dlls/mmdevapi/client.c`, `adjust_timing()` refuses that combination outright:

    else if (flags & AUDCLNT_STREAMFLAGS_EVENTCALLBACK) {
        if (*duration != *period)
            return AUDCLNT_E_BUFDURATION_PERIOD_NOT_EQUAL;
        FIXME("EXCLUSIVE mode with EVENTCALLBACK\n");
        return AUDCLNT_E_DEVICE_IN_USE;
    }

`AUDCLNT_E_DEVICE_IN_USE` with no device in use. This sits **above** the driver,
so it applies to PulseAudio and ALSA alike — which is why switching drivers on
its own changed nothing that the user could see.

The refusal is a placeholder rather than a limitation: the backends already
signal the client event from their timer loops regardless of share mode, and
winealsa already runs a 4-period ALSA ring underneath
(`alsa_bufsize_frames = mmdev_period_frames * 4`), so the mmdevapi-visible
buffer size and the hardware ring are already decoupled exactly as on Windows.
The patch drops the refusal and lets the two constraints checked immediately
above it stand.

    bin/build-patched-dlls.sh mmdevapi
    cp artifacts/mmdevapi-patched-native-11.15.dll \
       "$WINEPREFIX/drive_c/windows/system32/mmdevapi.dll"
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v mmdevapi /d native /f

**Result:** with the DDJ-400 selected, the Sample Rate dropdown populates —
44100 Hz selected, and the full list offered. Verified by screenshot.

`upstream/wasapitest.exe event` reproduces the call on its own
(`upstream/wasapitest-output-event.txt`):

| mmdevapi | `Initialize(EXCLUSIVE\|EVENTCALLBACK)` |
|---|---|
| stock | `AUDCLNT_E_DEVICE_IN_USE` |
| **patched** | **`S_OK`, buffer 256 frames = one period, event fires** |

**Known incomplete, and it matters.** The stream opens and the event fires, but
`GetBuffer` for a full period then returns `AUDCLNT_E_BUFFER_TOO_LARGE` with
padding stuck at the whole buffer, so the probe services one period and stops.
Wine's padding accounting does not free a full period per event the way the
Windows contract requires. rekordbox gets far enough to build its rate list; it
is **not yet confirmed** that it can sustain playback through the controller.
That is the next thing to establish, and if it cannot, the remaining work is in
Wine's exclusive-mode buffer accounting rather than anywhere near rekordbox.

Upstream: `upstream/patches/0002-mmdevapi-allow-event-driven-exclusive-streams.patch`.
This one is worth more than the rekordbox result — every professional audio
application on Windows uses this pattern, and under Wine they all get
"device in use" from a device that is idle.

---

## Step 3 — the controller (MIDI ports, HID access, and the loopback trap)

Wine exposes the controller's MIDI ports through winmm with no configuration.
That is necessary and nowhere near sufficient. Two more things are needed, and
both are system-level rather than prefix-level. See `docs/investigation/THEMES/T05-controller.md`.

### 3a — remove the `Midi Through` loopback

    sudo modprobe -r snd_seq_dummy       # permanent: blacklist the module

`snd_seq_dummy` provides ALSA's "Midi Through" virtual port, which echoes back
anything sent to it. Wine enumerates it as a MIDI device *ahead of* the real
hardware, and rekordbox's port scan stops at the first port that answers — so it
binds the loopback and talks to itself. Measured: rekordbox opened devices 0, 1
and 2, kept 2 (Midi Through), and **never opened device 3 (the DDJ-400)**, with
the controller's rawmidi counters at `Tx bytes: 0, Rx bytes: 0`.

Any host that probes MIDI ports for a reply will be caught by this, so it is
worth doing on any Wine DJ/audio setup, not just this one.

### 3b — grant access to the controller's HID interface

    sudo cp packaging/99-pioneer-ddj.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules
    # then REPLUG the controller — the uaccess tag only applies on a real add event

rekordbox identifies a controller through the Windows HID stack
(`HidD_GetHidGuid`, `SetupDiEnumDeviceInterfaces`, `HidD_GetAttributes`,
`HidD_GetProductString`), not through MIDI. The DDJ-400's HID interface surfaces
as `/dev/hidraw0`, which is **root-only by default**, so Wine's `winebus.sys`
cannot enumerate it and the application never sees the controller at all.

Verify with `upstream/hidtest.exe` — it walks the HID interface class the same
way rekordbox does and should report:

    \\?\hid#vid_2b73&pid_0026&mi_04#...  VID_2B73 PID_0026  product: DDJ-400

**For a package:** ship the udev rule and the modprobe blacklist. Both are
one-line files, both are needed, and neither is discoverable from the
application's behaviour — it simply acts as though no controller is attached.

### Still broken after both

The controller is now identified, but rekordbox connects and disconnects it
repeatedly and no control reaches the decks. Leading hypothesis and a proposed
third Wine patch are in T05: winealsa signals the audio event once per period
regardless of whether a buffer was freed, so a client that trusts the
"event means a buffer is ready" contract sees a stream error and rebuilds.

---

## Step 4 — the prefix and the application

    WINEPREFIX=... wineboot -i            # win10 default is fine
    # wine-mono and wine-gecko installed, so .NET is not a confound

    wine Install_rekordbox_x64_7_2_17.exe /S
    # /S does NOT suppress the "Please select a language" dialog.
    # Send it a single Return; everything after that is unattended.

1.4 GB installed. No winetricks verbs, no DLL overrides beyond dxgi, and the
documented `HideWineExports` shim is **not** needed.

---

## Step 5 — USB export target

rekordbox looks specifically for removable media, so a plain drive letter is not
enough — the drive type has to be set as well:

    ln -s /run/media/<user>/REKORDBOX "$WINEPREFIX/dosdevices/e:"
    ln -s /dev/sda1                   "$WINEPREFIX/dosdevices/e::"
    wine reg add 'HKLM\Software\Wine\Drives' /v 'e:' /d removable /f

Stick formatted msdos / single primary FAT32 / lba, labelled `REKORDBOX`.
`wine cmd /c dir e:\` reports `Volume in drive e is REKORDBOX`.

Also remove stale auto-detected device links — we had `d::` pointing at a
partition that no longer existed after repartitioning and `f::` pointing at the
whole disk, either of which can confuse device enumeration.

**Export itself is not yet tested.** This is the biggest single gap between the
current state and a Gold claim.

---

## What an AUR package would contain

1. `rekordbox-wine` — a wrapper + `.desktop` that owns a dedicated prefix under
   `~/.local/share/rekordbox-wine/prefix`, not the user's default prefix.
2. A build step producing the patched `dxgi.dll` **and** `mmdevapi.dll` from the
   Wine source matching the installed `wine`/`wine-staging`, per
   `bin/build-patched-dlls.sh`. These must be rebuilt whenever Wine is upgraded,
   so the package needs to either pin the Wine version or rebuild on upgrade — a
   stale DLL built against a different Wine is the most likely support burden.
3. First-run setup applying steps 2, 4 and 5: the two registry writes, the
   installer invocation (the user supplies the installer — it cannot be
   redistributed), and optional USB drive mapping.
4. A doctor command that checks the four things that silently revert to broken:
   `RBW-PATCH` present in the loaded dxgi, `RBW-MMDEV` in the loaded mmdevapi,
   `DllOverrides\dxgi = native` and `DllOverrides\mmdevapi = native`, and
   `Drivers\Audio = alsa`. All four fail silently — you get stock behaviour and
   a plausible-looking application bug.

The licence position is unchanged and must stay that way: prefix configuration
and Wine fixes are in scope, and nothing here touches licence or subscription
enforcement. No sign-in credential ever goes near the tooling.

---

## Gaps between here and Gold

**Rewritten 2026-08-17 (night).** The previous list had three items that are now
resolved and was missing the one feature that is actually broken.

### Blocking

1. **USB export untested** (T02). Still the biggest unknown, and it is the point
   of the application for most users. **Blocked on hardware:** the prefix maps
   `E:` to `/run/media/<user>/REKORDBOX` and no stick is attached.
2. **PC MASTER OUT is broken** (T03 phase 25). Playing to the controller and the
   computer's speakers at the same time drops the playback engine to **0.05x
   real time** and rebuilds both streams every 15.8 s; track loads take 3-9x
   longer. With it off everything runs at 1.00x. Wine's WASAPI path is measured
   clean, so this is above WASAPI and still open.
3. **File menu never opens** (T04). Reproducible, 0/5, no popup window is
   created at all.
4. **No clean-prefix rerun.** The current prefix has been through dozens of
   harness runs, several ended with `kill -9`. Everything here should be
   reproduced from scratch before it is published as a recipe.
5. **The package has never been installed from scratch.** `packaging/PKGBUILD`
   exists and `docs/PACKAGE.md` is the authoritative list, but nobody has built the
   package on a clean machine and followed it end to end.

### Resolved since this list was written

- ~~Controller binding untested~~ — **works.** The DDJ-400 authenticates, lights
  up and its jog wheels drive the decks on a plain launch (T05 phases 23-24,
  user-confirmed). Root cause was a SysEx split across two USB transfers.
- ~~Event-driven exclusive playback only half-implemented~~ — **it sustains.**
  Measured at 1.00x real time with zero stream rebuilds over 40 s windows, and
  58 fps held for 27 minutes with a track playing.
- ~~No DDJ-400 driver exists to install~~ — still true, still not a problem: the
  device is USB Audio Class compliant.

### Not blocking, but a user should be told

- The sample-rate list is optimistic under winealsa: it offers rates the
  hardware cannot do natively (the DDJ-400 is 44100-only). Pick 44100.

## The run-and-play deliverable (added 2026-08-13)

Everything above is now executable rather than a list of instructions:

| file | what it does |
|---|---|
| `bin/rekordbox-wine` | the single command. `--check` verifies every step and launches nothing; `--setup` configures only; no argument configures then launches. |
| ~~`research/retired/install-system-wine-patches.sh`~~ | **SUPERSEDED by step 13** — it replaced files owned by the distro's `wine` package. Use `bin/make-private-wine.sh`, which needs no root. |
| `bin/build-patched-dlls.sh` | rebuilds `dxgi`, `mmdevapi` and `cfgmgr32` from source against the installed Wine version. |
| `packaging/PKGBUILD` | AUR skeleton. |
| `packaging/rekordbox-wine.install` | the three manual steps a package cannot do, printed at install time. |

`--check` is the important one. This configuration has silently reverted on us
repeatedly — a launcher that forgot an override, a prefix update that restored a
stock DLL over the patched one, a udev rule that parsed cleanly and applied
nothing. Every failure looked like a brand-new application bug. So each check is
a measurement of the installed artefact, not a record of what we did:

- the DLL in the prefix is **byte-compared against the artifact**, because a
  prefix update restores the stock builtin over the top;
- the installed file is **grepped for its patch marker**, because a stock build
  loads perfectly and just behaves as though unpatched;
- the override and driver values are **read back out of the registry**.

Two bugs in the checker itself were found by running it: `wine reg query` emits
CRLF, so `"native" != "native\r"` reported a correct prefix as broken.

### Honest status for a packager

Do not describe this as "rekordbox works on Linux". What is solid:

- **the application runs** — this is the whole `dxgi`/`WaitForVBlank` result,
  the difference between one frozen frame and a usable UI;
- **audio works**, including exclusive-mode output at 44100 Hz to the controller.

What does not:

- **controller binding** — identified, never bound, zero MIDI bytes. Performance
  mode with real hardware is not usable.
- the File menu, and USB export is untested.

---

## RETRACTED — "the session degrades, restart between sets"

**This section previously told packagers to ship the advice "restart rekordbox
between sets", on the strength of a measured decay from 58 to 41 fps with GPU
memory climbing at 1.2 MB/s and a correlation of r = -0.963.**

**That advice is withdrawn. The decay was a measurement confound.** rekordbox
renders at ~58 fps with a track *playing* and runs its own ~33 ms frame limiter
otherwise. The demo track is 2:08 long and the soaks were 9-27 minutes, so every
one of them spent most of its length measuring the limiter after the deck had
stopped — a step down in the first minute, read as a gradual decay.

With `research/probes/playkeep.sh` keeping the deck playing (it checks the deck's own
elapsed-time readout and presses CUE+PLAY only when it has stopped):

| run | duration | fps first → last | GPU memory |
|---|---|---|---|
| OpenGL | 10 min | 58.0 → 57.9  (**-0.3%**) | 244 → 1368 MB |
| OpenGL | 27 min | 58.1 → 57.5  (**-1.2%**) | 1497 → **4514 MB** |
| software (`DisableOpenGL=1`) | 10 min | 41.4 → 41.9 (+1.2%) | 94 → 94 MB flat |

**Three gigabytes of leaked GPU memory bought no measurable frame-rate cost.**

What survives: the leak is real, is entirely in the GL stream, runs at ~1.9 MB/s
with no plateau, and is worth fixing. What does not survive: that it costs the
user anything over a set-length session, and the restart advice built on it.
`DisableOpenGL=1` is likewise **not** a recommendation — it is stable, but stable
at 41 fps against OpenGL's 58.

The residual risk is duration: 1.9 MB/s reaches ~20 GB over a three-hour set,
which is a different regime and has not been tested.

Check it yourself at any time — no rebuild, no root:

    bin/loadplay.sh              # get a track playing, with proof
    research/probes/playkeep.sh 660 &        # keep it playing
    research/probes/uisoak.sh 10             # fps, jitter and gpu_mb per sample

A soak whose deck stopped is not evidence. `playkeep` prints how many times it
had to intervene; if that number is large, the deck was not playing.

## Step 3c — a patched `wineusb` that exposes `\\.\HCDn` (mandatory for the controller)

**Without this the DDJ-400 cannot work under its own name at all.** rekordbox
identifies the controller over HID, builds its native `djplay::MidiMapDDJ400`
object, and then validates it by walking the USB bus the way `usbview.exe` does:
`CreateFile` on `\\.\HCD0`..`\\.\HCD9`, then the USB hub IOCTLs, to read the
device's `bcdDevice`. Wine implements none of that — no `\\.\HCDn` device object
exists and `ddk/usbioctl.h` defines only `IOCTL_INTERNAL_USB_SUBMIT_URB` — so all
ten opens fail with `STATUS_OBJECT_NAME_NOT_FOUND`, the validation returns
negative, and rekordbox **destroys the device object it just built** and never
opens the MIDI port.

Measured before the patch (`runs/20260815T140305`): zero ALSA subscriptions,
`Tx 0`, `Rx 0`, for a whole run. After it: subscriptions both ways, `Tx 202`,
`Rx 63`.

    bin/build-wineusb-hcd.sh            # -> artifacts/winedll/wineusb.{sys,so}
    sudo research/retired/install-wineusb-hcd.sh     # replaces both, backups at *.rbw-backup
    bin/rbclean.sh                      # restart the session so it loads

Verify — the driver announces itself, and a probe walks the bus without
involving rekordbox at all:

    WINEDEBUG=+err wine cmd /c exit 2>&1 | grep RBW-USBHCD
    wine upstream/hcdtest.exe

`hcdtest` must report the controller with its real `bcdDevice`:

    port 4: VID_2B73 PID_0026 rev 0103   <== Pioneer DJ

**Both halves must be installed together.** `wineusb.so` gains a new unixlib
entry point and `wineusb.sys` is its only caller; installing one without the
other gives a driver that calls past the end of the function table. The install
script refuses unless both carry the `RBW-USBHCD` marker.

**Reversal:** `sudo research/retired/install-wineusb-hcd.sh --revert`, then `bin/rbclean.sh`.

> **SUPERSEDED by step 13.** `wineusb` now ships inside the private Wine tree;
> nothing is installed into `/usr/lib/wine` any more.

**What it reports:** device and configuration descriptors copied verbatim from
`/sys/bus/usb/devices/<dev>/descriptors` — what the kernel already knows about
hardware you own. The one simplification is topology: each HCD maps to a real
Linux USB bus and each port to a real device on it, rather than reproducing the
exact hub tree.

**Still open after this patch:** the toolbar PAD and MIDI indicators remain
greyed, so something beyond the USB gate is still unsatisfied. Whether the jog
wheels work is untested and needs a human at the hardware.

## Debug-host changes — NOT part of the package (2026-08-16)

Installed only to instrument this machine. An AUR package must never require
any of it; listed here because the project rule is that every system-level
change is recorded with its exact reversal.

| change | why | reversal |
|---|---|---|
| `sudo modprobe usbmon` | passive USB capture for `research/probes/usbwire.sh`; without it the DDJ's URBs are invisible | `sudo rmmod usbmon` |
| `pacman -S wireshark-cli` | `tshark` captures the `usbmon3` interface | `sudo pacman -Rs wireshark-cli` |
| `pacman -S lsof` | find who holds the DDJ's PCM open | `sudo pacman -Rs lsof` |

`usbmon` is passive: it copies URBs already on the bus and submits none of its
own, so it cannot itself disturb the controller. That matters here, because the
fault under investigation is a device that stops accepting output — an
instrument that touched the bus would be a confound.

## Gold blocker, identified 2026-08-17 — the SysEx split (T05 phase 23)

**The DDJ-400 hangs when a MIDI SysEx is split across two USB transfers**, and
Wine's `midi_out_long_data` can do exactly that because it sends through the
ALSA sequencer, whose 32-byte chunking races the USB packetiser. Proven by
controlled experiment; see `docs/investigation/THEMES/T05-controller.md` phase 23b.

**What this means for packaging.** Until winealsa delivers SysEx contiguously,
a launch either authenticates the controller or it does not, and a failed launch
leaves the device needing a **physical power cycle** before the next attempt.
There is no setting, script or environment variable a user can apply — the race
is internal to the driver. That is precisely the class of thing Gold forbids
("no workarounds the user has to discover for themselves"), so **the package
cannot ship as Gold until the winealsa fix lands.**

The fix is a Wine patch, it is in scope, and it is the single highest-value
remaining item in this project. Everything else on the controller path — USB
enumeration via `\\.\HCDn`, the Pioneer auth handshake, `enableDevice`, LEDs and
controls — is measured working.

### RESOLVED 2026-08-17 — the Gold blocker above is fixed

`upstream/0011-winealsa-send-midi-to-hardware-via-rawmidi.patch` makes winealsa
deliver MIDI to hardware destinations through the rawmidi node, so a SysEx
reaches the device in one USB transfer as it does on Windows. Four gated runs,
four completed handshakes, no wedges, and **the user confirmed lights and jog
wheels working at the hardware**.

Build and install it with the other winealsa patches — it is in the same file
and the same `bin/build-patched-dlls.sh` / `research/retired/install-system-wine-patches.sh`
flow. Verify with `strings /usr/lib/wine/x86_64-unix/winealsa.so | grep RBW-RAWOUT`.
`RBW_NO_RAWOUT=1` reverts to the old sequencer path at runtime for comparison.

The package still cannot be called Gold until the patch is upstream or the AUR
build applies it reproducibly — see the reproducibility defects in
`AUDIT-2026-08-16-wine-stack.md` §1.4, which are now the top packaging risk.

### Temporary system change — 2026-08-18, debugging only (NOT for packaging)

`kernel.yama.ptrace_scope` set to 0 so `gdb` can attach to an already-running
rekordbox (scope 1 permits ptrace only of one's own descendants, and rekordbox
is launched detached via `setsid`). Needed to breakpoint
`rb::AudioIODeviceType::Listener` slot 2 inside rekordbox and read the caller of
the spurious device-change announcement (docs/investigation/THEMES/T10 phase 7).

This is a **debugging-only** change. It is not required to run rekordbox and
must never appear in the AUR package or the run-and-play script.

    reversal:  sudo sysctl -w kernel.yama.ptrace_scope=1

It is not persisted (no sysctl.d file written), so a reboot also restores it.

**RESTORED 2026-08-19** — `ptrace_scope` is back to 1. Nothing to undo.

### Experimental winealsa build installed — 2026-08-19 (measurement in progress)

`debug/wip-exclusive-buffer-contract.diff.txt` applied to `alsa.c.pre-dbg` (the
exact base it was cut against, and the same base the previously installed
shipping driver was built from — so this is a one-variable change) and installed
as the system `winealsa.so`. Markers `RBW-DBLBUF/RBW-TOOBIG/RBW-GETOK/RBW-POS`
are present in the installed file, verified with `strings`.

Being measured against `research/probes/queuescope.py`: does the DDJ's exclusive-mode queue
still outgrow the PC endpoint's by 4 buffers (docs/investigation/THEMES/T10 phase 9)?

    reversal:  sudo cp -f /usr/lib/wine/x86_64-unix/winealsa.so.rbw-shipping-baseline \
                          /usr/lib/wine/x86_64-unix/winealsa.so

The stock (distro) driver is still preserved separately at
`/usr/lib/wine/x86_64-unix/winealsa.so.rbw-backup`.

**REVERTED 2026-08-19** — the patch was refuted (docs/investigation/THEMES/T10 phase 10: it removes
every `BUFFER_TOO_LARGE` refusal and the fault survives unchanged), so the
shipping driver is back in place. Verified with `strings`: the installed
`winealsa.so` carries `RBW-DIAG RBW-EVENT RBW-PAD RBW-RAWFMT RBW-WD` and none of
the `RBW-DBLBUF/TOOBIG/GETOK/POS` markers.

### `perf` installed and tracing enabled — 2026-08-19 (debugging only)

Installed to find the ~15 s alarm behind the PC MASTER OUT teardown
(docs/investigation/THEMES/T10 phase 21 proved the alarm exists; three candidate constants have
already been refuted). The plan is to trace `timer:hrtimer_start` and read the
expiry of every timer armed by rekordbox: a ~13.65 s timeout will name the
thread that armed it outright.

    sudo pacman -S perf
    sudo sysctl -w kernel.perf_event_paranoid=-1
    sudo sysctl -w kernel.kptr_restrict=0

**Debugging only. None of this belongs in the AUR package or the run-and-play
script.**

    reversal:  sudo sysctl -w kernel.perf_event_paranoid=2
               sudo sysctl -w kernel.kptr_restrict=1
               sudo pacman -Rs perf      # if the tool is not wanted afterwards

The two sysctls are not persisted (no file written under /etc/sysctl.d), so a
reboot restores them on its own.

### RBW-GAP probe build installed — 2026-08-19 (measurement only)

`winealsa.so` rebuilt from the shipping base (`alsa.c.pre-dbg`, the same source
the installed driver came from) with one addition: the **RBW-GAP** probe, which
records the interval between consecutive successful `ReleaseBuffer` calls per
stream and, for any gap over 50 ms, logs how many times the client asked
(`tries`), how many times Wine refused (`fails`), and the last HRESULT. The
timestamp is `CLOCK_MONOTONIC`, matching `research/probes/queueburst.py`.

Marker verified in the installed file with `strings`: `RBW-GAP`.

    reversal:  sudo cp -f /usr/lib/wine/x86_64-unix/winealsa.so.rbw-shipping-baseline \
                          /usr/lib/wine/x86_64-unix/winealsa.so

**Measurement build. Not for the package.** It only adds counters and a
rate-limited `ERR`, but it has not been measured in the single-device daily
configuration, so it must be reverted before that path is trusted.

## Step 6 — the two rekordbox settings that make PC MASTER OUT work (2026-08-19)

**This is a mandatory step for anyone who wants sound out of the computer as
well as the controller.** Root cause and every measurement: `docs/investigation/THEMES/T10` phases
33-42. Short version:

    WasapiPolling   = 1        without it, PC MASTER OUT plays at 0.05x of real
                               time and rekordbox tears down and rebuilds BOTH
                               audio streams every 15.9 s, four times a minute
    AudioBufferSize = 512      at 256 a single teardown still arrives about
                               once every three minutes

Both live in

    $WINEPREFIX/drive_c/users/$USER/AppData/Roaming/Pioneer/rekordbox6/rekordbox3.settings

and **must be edited with rekordbox stopped** — it rewrites that file every
~15 seconds while it runs, so an edit made against a running application is
silently discarded. `bin/rekordbox-wine` does this for you: `--check` reports
both under **Audio settings**, and `--setup` (or a normal launch) repairs them
and keeps `rekordbox3.settings.rbw-backup`.

    reversal:  edit the two values back, or restore the .rbw-backup file,
               with rekordbox closed

**No Wine change is needed for this fix.** The measured configuration is 1.00x
of real time with **zero** stream teardowns over 465 s of continuous playback,
real audio at the PC endpoint (-19.7 to -22.5 dBFS RMS off the sink monitor),
the DDJ substream RUNNING throughout, and MIDI unaffected.

### Why `WasapiPolling` matters, in one paragraph

rekordbox's engine services every output device from one loop and keeps each
device's queue three buffers deep; when one device runs four buffers deeper than
the shallowest it trims the excess, and after 100 corrections less than 100 ms
apart it decides the audio device has changed and rebuilds everything. With
`WasapiPolling=0` the writer sizes each block from `GetBufferSize()`, which under
Wine is four periods on the exclusive controller stream and one on the shared PC
endpoint — so the two devices run at 43 and 172 callbacks a second, the queues
diverge by about 129 entries a second, and the 100-trim threshold is reached in
under a second, for ever. With `WasapiPolling=1` the writer uses the device
*period* instead, both devices run at 172, and the divergence is zero.

## Debug-host changes to reverse — 2026-08-19 (afternoon session)

    sudo sysctl -w kernel.perf_event_paranoid=-1      RAISED for tracing
    sudo sysctl -w kernel.kptr_restrict=0             RAISED for tracing
    sudo sysctl -w kernel.yama.ptrace_scope=0         RAISED for /proc/pid/mem

    reversal:  sudo sysctl -w kernel.perf_event_paranoid=2 \
                              kernel.kptr_restrict=1 \
                              kernel.yama.ptrace_scope=1

    pw-metadata -n settings 0 clock.force-rate 44100  tried, no effect, REVERTED
    reversal (already applied):  pw-metadata -n settings 0 clock.force-rate 0

    renice -15 on rekordbox's threads                 tried, no effect; the
                                                      process is gone, nothing
                                                      to reverse
    chrt -r 20 on the callback threads                DO NOT REPEAT: it stopped
                                                      rekordbox's audio and the
                                                      process did not survive

A **rebuilt `mmdevapi.dll`** was installed into `prefixes/rb7` this session. It
is not a behaviour change: it adds the `RBW_EXCL_PERIODS` / `RBW_SHARED_PERIODS`
environment knobs whose defaults (4 and 3) reproduce the shipping behaviour
exactly, and it is what made the root cause provable. Greppable as
`RBW-PERIODS exclusive`. It supersedes `artifacts/mmdevapi-patched-native-11.15.dll`,
which was rebuilt in place.

## Step 7 — a patched `winex11.so` (fixes the File menu, and EXPORT mode) — 2026-08-19

**Mandatory.** Without it rekordbox's **File menu** and its **view-mode
selector** never open while the window is maximised at x = 0, which also makes
**EXPORT mode — and therefore USB export — unreachable**. Root cause and every
measurement: `docs/investigation/THEMES/T04`, and the patch is written up for upstream in
`upstream/patches/0005-winex11-popup-not-managed.patch`.

One line of it, in `dlls/winex11.drv/window.c`, `is_window_managed()`:

    if (style & WS_POPUP)
    {
        if (ex_style & (WS_EX_TOOLWINDOW | WS_EX_LAYERED)) return FALSE;   /* RBW-POPUP */
        if (style & WS_SYSMENU) return TRUE;

JUCE's popups carry `WS_SYSMENU`, so Wine was handing them and their four drop
shadows to KWin, which moved the off-screen left shadow from x = -13 to x = 0;
JUCE saw its own chrome move and dismissed the menu 11 ms after mapping it.

    build:    (in the wine source tree) make dlls/winex11.drv/winex11.so
    install:  sudo cp -a /usr/lib/wine/x86_64-unix/winex11.so \
                         /usr/lib/wine/x86_64-unix/winex11.so.rbw-backup
              sudo cp -f <src>/dlls/winex11.drv/winex11.so /usr/lib/wine/x86_64-unix/winex11.so
    verify:   strings /usr/lib/wine/x86_64-unix/winex11.so | grep -c RBW-POPUP    # 1
    reversal: sudo cp -f /usr/lib/wine/x86_64-unix/winex11.so.rbw-backup \
                         /usr/lib/wine/x86_64-unix/winex11.so

**Applied on this machine 2026-08-19**, backup in place. A copy of the built
library is kept at `artifacts/winedll/winex11.so`.

Note this is a **system-wide** Wine change, like the `winealsa.so` one: it
affects every Wine application on the machine. It is conservative — it makes
tool-window and layered popups unmanaged, which is what Windows does — and
`get_mwm_decorations_for_style()` in the same file already treats those two
ex-styles as undecorated chrome.

## Step 8 — removable-drive detection (needed for USB export) — 2026-08-19

Two things, one Wine patch and one permission.

**8a. `upstream/patches/0006-mountmgr-removable-unknown-media.patch`.** Wine's UDisks
integration derives a drive's device type from `MediaCompatibility`, which is
empty for a plain USB stick, so the drive was added as `DEVICE_UNKNOWN` and
`GetDriveTypeW` never returned `DRIVE_REMOVABLE`. `device.c` already maps
`DEVICE_HARDDISK` to `DRIVE_REMOVABLE`; the patch makes the UDisks path agree.

    build:    make dlls/mountmgr.sys/mountmgr.so
    install:  sudo cp -a /usr/lib/wine/x86_64-unix/mountmgr.so \
                         /usr/lib/wine/x86_64-unix/mountmgr.so.rbw-backup
              sudo cp -f <src>/dlls/mountmgr.sys/mountmgr.so /usr/lib/wine/x86_64-unix/mountmgr.so
    verify:   strings /usr/lib/wine/x86_64-unix/mountmgr.so | grep -c RBW-REMOVABLE   # 1
    reversal: sudo cp -f /usr/lib/wine/x86_64-unix/mountmgr.so.rbw-backup \
                         /usr/lib/wine/x86_64-unix/mountmgr.so

**8b. read access to the raw device node.** Without it mountmgr cannot open
`/dev/sdX1` (`err 5`) and reports a FAT32 stick as **NTFS**. Applied here as an
ACL; a package should ship a udev rule instead.

    applied:  sudo setfacl -m u:$USER:rw /dev/sda1 /dev/sda
    reversal: sudo setfacl -x u:$USER /dev/sda1 /dev/sda
    packaged: a udev rule granting the seat user access to removable block
              devices, in the same spirit as 60-pioneer-ddj.rules

**Verify both with `upstream/drivetest.exe`** (built by the `build-probes.sh`
recipe), which prints one line per drive:

    E: REMOVABLE  label "REKORDBOX"  fs "FAT32"      <- correct
    E: FIXED      label "REKORDBOX"  fs "NTFS"       <- either step missing

## Step 9 — make removable drives visible to the export browser — 2026-08-19

**Mandatory for USB export.** rekordbox finds a device by intersecting SetupAPI's
`GUID_DEVCLASS_VOLUME` enumeration with `GetDriveType`/`QueryDosDevice`, joined on
`SPDRP_PHYSICAL_DEVICE_OBJECT_NAME == QueryDosDeviceW(letter)` (`docs/investigation/THEMES/T02`).
Two pieces:

**9a. `upstream/patches/0008-setupapi-physical-device-object-name.patch`.**
`SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` was a NULL placeholder in setupapi's
`PropertyMap`, so every read of it failed and the join could never succeed.

    build:    make dlls/setupapi/x86_64-windows/setupapi.dll
    install:  sudo cp -a /usr/lib/wine/x86_64-windows/setupapi.dll \
                         /usr/lib/wine/x86_64-windows/setupapi.dll.rbw-backup
              sudo cp -f <src>/dlls/setupapi/x86_64-windows/setupapi.dll \
                         /usr/lib/wine/x86_64-windows/setupapi.dll
    verify:   strings /usr/lib/wine/x86_64-windows/setupapi.dll | grep -c PhysicalDeviceObjectName   # 2
    reversal: sudo cp -f /usr/lib/wine/x86_64-windows/setupapi.dll.rbw-backup \
                         /usr/lib/wine/x86_64-windows/setupapi.dll

**9b. `upstream/patches/0009-mountmgr-volume-devnodes.patch`.** `mountmgr.sys` now
publishes every removable volume as a `GUID_DEVCLASS_VOLUME` device node under
`Enum\STORAGE\Volume\WineVolume<letter>`, written when the drive's volume
information is set and removed when the drive goes. The `PhysicalDeviceObjectName`
it writes is the same string `\DosDevices\X:` points at, so the join key matches
by construction. Volatile keys, so nothing is left behind across boots.

    build/install/verify: as for 0007 (same mountmgr.sys binary)
    verify:   strings /usr/lib/wine/x86_64-windows/mountmgr.sys | grep -c RBW-VOLNODE   # 1

`research/probes/usbdevnode.sh` is **superseded** by this and kept only as a fallback for a
Wine without 0009, and as a diagnostic: run `research/probes/usbdevnode.sh --remove` and
check whether `Enum\STORAGE\Volume\WineVolume<letter>` reappears by itself.

**Verified end to end 2026-08-19**: with 9a + 9b and **no helper script**, a
fresh rekordbox lists `E:REKORDBOX` in EXPORT mode
(`runs/T02-device-listed-from-mountmgr.png`),
initialises it, and exports a track — `Contents/`, `PIONEER/USBANLZ/…/ANLZ*`
and `export.pdb`, validated outside Wine by `bin/pdbcheck.py`.

---

## Step 10 — the four system-owned Wine files, replaced together — 2026-08-20

Earlier steps replaced `winealsa.so` alone. The series now also replaces
`winex11.so` (the File menu and EXPORT mode), `mountmgr.so` and `mountmgr.sys`
(USB export). All four are owned by the `wine` package, so **a wine upgrade
silently reverts every one of them** and the launcher's marker checks are the
only thing that will say so.

    change:    sudo research/retired/install-system-wine-patches.sh
               installs, with a .rbw-backup of each stock file first:
                 /usr/lib/wine/x86_64-unix/winealsa.so     RBW-EVENT / RBW-EVENT3
                 /usr/lib/wine/x86_64-unix/winex11.so      RBW-POPUP
                 /usr/lib/wine/x86_64-unix/mountmgr.so     RBW-REMOVABLE
                 /usr/lib/wine/x86_64-windows/mountmgr.sys RBW-BUSTYPE / RBW-VOLNODE

    reversal:  sudo research/retired/install-system-wine-patches.sh --revert
               restores all four from their .rbw-backup files.

The script refuses to install a file that does not carry its marker, so it
cannot bury the real system file behind a backup of an unpatched build, and it
re-checks the marker after installing and rolls back if it is absent.

**Currently installed on this machine (verified 2026-08-20):** all four, each
with a backup present, built from a **pristine** Wine tree plus `0001..0009` —
so what is running here now is what the package ships, not the working tree's
debug build. Behaviour after the swap: **1.000x, 0 teardowns**
(`runs/SOAK/deckclock`).

`research/probes/usbdevnode.sh` is retired by `upstream/patches/0009` and is no longer part of any
step; the volume devnode is written by `mountmgr.sys` itself.

---

## Step 11 — the package installed as a package — 2026-08-20

    change:    sudo pacman -U rekordbox-wine-0.2.0-1-x86_64.pkg.tar.zst
               67 files: /usr/bin/rekordbox-wine, /usr/share/rekordbox-wine/{bin,artifacts,winedll},
               the udev rule, the modprobe blacklist, the modules-load entry,
               the .desktop file, and the docs.

    reversal:  sudo pacman -R rekordbox-wine
               (this does NOT revert the system Wine libraries — the package
                never installed them. Undo those with step 10's --revert, and
                research/retired/install-wineusb-hcd.sh --revert.)

**The whole recipe was then run from the installed copy**, into an empty prefix
at `~/.local/share/rekordbox-wine/prefix-clean`:

    RBW_PREFIX=~/.local/share/rekordbox-wine/prefix-clean rekordbox-wine --setup
    RBW_PREFIX=... rekordbox-wine --install artifacts/Install_rekordbox_x64_7_2_17.exe
    RBW_PREFIX=... rekordbox-wine

Result: prefix created, three patched builtins installed and overridden, all six
system libraries verified, rekordbox 7.2.17 installed unattended, window mapped
in about five seconds and **repainting** (two screenshots four seconds apart
differ — past the T01 one-frame freeze), and the AlphaTheta sign-in dialog
reached.

The harness stops at sign-in and always will: credentials are never given to it
and never typed into a logged terminal. The prefix is left in place, signed out,
for a human to take from there.

**`--install` is new.** It runs the full prefix preparation first and only then
the vendor installer, because rekordbox's installer launches the application
when it finishes — on an unprepared prefix the first thing a new user would see
is the one-frame freeze.

---

## Step 12 — `rtkit`, which makes real-time priority possible at all — 2026-08-20

    change:    sudo pacman -S rtkit
               sudo systemctl start rtkit-daemon
               systemctl --user restart xdg-desktop-portal   # it caches the values

    reversal:  sudo systemctl stop rtkit-daemon
               sudo pacman -R rtkit
               systemctl --user restart xdg-desktop-portal

**Why.** Without `rtkit-daemon`, `xdg-desktop-portal` advertises
`MaxRealtimePriority = 0` and no realtime time budget.
`libpipewire-module-rt`, which is loaded **inside every PipeWire ALSA client**
— rekordbox included, via `libasound_module_pcm_pipewire.so` — asks the portal,
gets nothing, and sets `RLIMIT_RTTIME` to `{0, 0}`. Soft *and* hard, which is
irreversible without `CAP_SYS_RESOURCE`.

At a zero budget, any thread placed on a real-time policy is killed by
`SIGXCPU` the moment it runs without blocking. That is what killed rekordbox
three times out of three in T10 phase 45, silently and with no Wine error.

With rtkit installed: `RLIMIT_RTTIME` becomes 200 ms, PipeWire's `data-loop`
becomes `SCHED_RR` priority 20, and the previously fatal `chrt -r` survives.

**It is a prerequisite, not a cure.** Measured straight afterwards at
`AudioBufferSize=256`: 1 teardown in 260 s, no better than before, because the
real-time priority reaches PipeWire's own thread and not rekordbox's callback
threads. Those still need `AvSetMmThreadCharacteristics` — which this change
makes safe to implement. See `docs/investigation/THEMES/T12`.

---

## Step 13 — SUPERSEDES step 10: a private Wine tree, no system files touched — 2026-08-20

**Step 10 is withdrawn.** It replaced six files owned by the distro's `wine`
package. That was a file conflict, it was undone by every wine upgrade, and —
the serious part — it changed the behaviour of **every Wine application on the
machine**: our MIDI renaming, our window-management change and our
storage-descriptor rewrite were forced on software that never asked for them.

Wine resolves its libraries relative to the loader binary's own path, so
`rekordbox-wine` now runs against a private tree instead.

    change:    bin/make-private-wine.sh          (no root required)
               builds ~/.local/share/rekordbox-wine/wine:
                 16 MB, 2430 symlinks into the system Wine, 11 real files
                 - the six patched libraries
                 - the loader chain: bin/wine, wine-preloader, ntdll.so
               The launcher builds and refreshes it automatically.

    reversal:  rm -rf ~/.local/share/rekordbox-wine/wine
               Nothing outside it was ever modified, so there is nothing else
               to undo.

**Undo step 10 if you applied it**, because those files are still patched from
before:

    sudo research/retired/install-system-wine-patches.sh --revert
    sudo research/retired/install-wineusb-hcd.sh --revert

Verify with: every system Wine file reports **zero** `RBW-` markers, and
`bin/verifyloaded.sh` reports rekordbox on the private tree while any other Wine
application reports the system one.

**The loader chain must be real files, not symlinks.** `wine-preloader` and
`ntdll.so` both cause Wine to re-derive its tree from a resolved path; leave
either as a symlink and rekordbox silently runs on stock libraries while every
marker check still passes. Measured. See `docs/investigation/THEMES/T13`.
