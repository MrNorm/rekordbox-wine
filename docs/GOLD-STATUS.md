# Where this project stands against Gold — 2026-08-20

**One page, then the evidence.** Read `docs/investigation/STATE.md` for what to do next and
`docs/PATH-TO-GOLD.md` for how to build the thing. This document answers a different
question: *how close is rekordbox under Wine to the standard the user set?*

## The two standards being measured against

1. **AppDB Gold.** "Installs and runs with no workarounds the user has to
   discover for themselves." A workaround the *package* applies silently is not
   a workaround the user has to discover; a setting they must find in a forum is.
2. **The user's standard, stated 2026-08-13, which is stricter.** Full function
   and feature, and *real performance use*, at 1:1 with the Windows build, with
   the **DDJ-400 as the acceptance test**.

Against (1) the honest verdict today is **Gold, with one asterisk**: every
capability works, and the only thing standing between here and a clean claim is
that one of the fixes is a stopgap script rather than a Wine patch, and that no
exported stick has yet been read by a real CDJ.
Against (2) it is **not finished**, and the two things standing in the way are
named at the bottom — one of them needs a USB stick and thirty minutes, the
other is a genuine open bug.

## Verdict by capability

Every row is a measurement with a date. Rows marked **(today)** were re-verified
in this session; the rest carry the date they were last measured.

### The application

| capability | state | evidence |
|---|---|---|
| installs unattended | works | NSIS `/S` + one Return |
| main window renders and repaints | works — **needs the `dxgi` patch** | T01; `20260813T071026` vs `…071216` |
| keyboard and mouse input | works | `20260813T062048` |
| sign-in to an AlphaTheta account | works | human session, 2026-08-13 |
| library, waveform, deck playback | works **(today)** | `bin/soak.sh`, two decks |
| Preferences, all panes | works **(today)** | `runs/PREFS/20260819T175136` |
| UI frame rate, track playing | 58 fps | T08, `bin/damagefps` |
| UI frame rate over 27 minutes | 58.1 → 57.5 fps — no decay | T08, 2026-08-17 |
| clean session at every launch | works — **needs `bin/rbclean.sh`**, which the launcher runs | T07 |
| **File menu** | **FIXED (today)** — 4/4 with the window at x=0, needs `winex11` patch `0005` | T04, `runs/T04-filemenu-fixed.png` |
| **View-mode selector** / EXPORT mode | **FIXED (today)** — 4/4, same patch | T04, `runs/T04-modeselector-fixed.png` |

### Audio

| capability | state | evidence |
|---|---|---|
| audio out, default device | works | shipped config |
| audio out, DDJ-400 exclusive 44100 | works — **needs the ALSA driver + `mmdevapi` patch** | `upstream/wasapitest-output-*.txt` |
| sample-rate list populated | works, 44100 selected — **T03's 2026-08-14 regression is cleared** | Preferences screenshot **(today)** |
| playback engine keeps real time | **1.000x** | `bin/deckclock.sh`, 120 s, `runs/SOAK/deckclock` **(2026-08-20)**. The earlier 1.00 cited `bin/soak.sh`, whose pixel-sampling rate meter returns 0.74-1.00 on a healthy config and saturates at 1.0 — see T00 |
| **PC MASTER OUT** (controller *and* computer speakers) | **WORKS** — was 0.05x with a 1.2 s dropout four times a minute | T10 phases 33-45 **(today)** |
| ↳ stream teardowns | **0 in 465 s continuous** | `bin/soak.sh` x3 **(today)** |
| ↳ audio actually at the wire | continuous, −19.7 to −22.5 dBFS RMS | `parec` on the sink monitor **(today)** |
| ↳ what Wine is handed | `fail=0`, `signal in every buffer`, both devices | `RBW-CLIENTS` **(today)** |
| **two decks playing at once** | works, 0 teardowns in 120 s, real mix | T10 phase 43 **(today)** |
| **track load time** | **0.9 s with PC MASTER OUT on** — was 3-9x slower | `bin/loadtime.sh` **(today)** |
| desktop keeps its audio devices | healthy after a full day of exclusive opens | `pactl list sinks` **(today)**; T09 |
| reported latency | 512 samples = **11.6 ms**, mid-slider | Preferences **(today)** |

### The controller — the acceptance test

| capability | state | evidence |
|---|---|---|
| MIDI ports visible and named | works — **needs the `winealsa` MIDI patch** | `miditest`, T05 |
| HID interface reachable | works — **needs a udev rule** | `hidtest`, T05 |
| `\\.\HCDn` present | works — **needs the `wineusb` HCD driver** | `hcdtest`, T05 |
| device authenticates (`@AuthResponseE`) | works — **needs the rawmidi SysEx fix** | T05 phases 23-24 |
| LEDs, jog wheels, decks driven | works, on a plain launch | T05, user-confirmed 2026-08-17 |
| MIDI unaffected by the audio fix | works **(today)** | `aconnect -l`, `/dev/snd/midiC0D0` held |
| **full performance pass** — every pad, fader, filter, FX, cue | **NEVER DONE** | needs hands on the hardware |

### Library and export

| capability | state | evidence |
|---|---|---|
| **USB export to a CDJ-readable stick** | **WORKS (today)** — device listed, initialised, track exported, database validated outside Wine | T02, `bin/pdbcheck.py` |
| ↳ exported audio | byte-for-byte the source file | `Contents/…/Demo Track 1.mp3` |
| ↳ analysis files a CDJ reads | `ANLZ0000.DAT/.EXT/.2EX`, all `PMAI` | `PIONEER/USBANLZ/…` |
| ↳ `export.pdb` | 4096-byte pages, 20 tables, all ranges in bounds, track present | `bin/pdbcheck.py` |
| ↳ read by a real CDJ | **NEVER TESTED** | needs hardware |
| removable-drive detection | **FIXED (today)** — `E: REMOVABLE / REKORDBOX / FAT32`, was `FIXED / NTFS` | `upstream/patches/0006` + device-node access |
| storage descriptor honesty | **FIXED (today)** — removable media and bus type were faked for every device | `upstream/patches/0007` |
| volume devnode for SetupAPI | **FIXED** — now written by `mountmgr.sys` itself; `research/probes/usbdevnode.sh` retired | `upstream/patches/0009`, T02 |
| Export Collection in xml | reachable — the File menu opens | T04 |

## What was actually wrong with Wine, and what each defect cost

Twelve defects, ten fixed. This is the part worth publishing.

| # | defect | symptom it caused | state |
|---|---|---|---|
| 1 | `dxgi`: `IDXGIOutput::WaitForVBlank` unimplemented | any JUCE 8 app paints **one frame** and freezes — this is why nobody had ever reported rekordbox 7.2.x reaching its window | **fixed**, `upstream/patches/0001` |
| 2 | `mmdevapi`: event-driven exclusive streams refused outright | empty sample-rate list; no DJ controller usable at all | **fixed**, `upstream/patches/0002` |
| 3 | `winealsa`: exclusive-mode event never signalled on a free period | stream starves and collapses | **fixed**, `upstream/patches/0003` |
| 4 | `winealsa`: SysEx split across two USB transfers | DDJ-400 never authenticates; LEDs flash, no control works | **fixed**, `upstream/patches/0004` |
| 5 | `winex11`: `is_window_managed()` calls a `WS_POPUP\|WS_SYSMENU` window managed | KWin moves JUCE's off-screen drop shadow; JUCE dismisses the menu 11 ms after mapping. **No File menu, no EXPORT mode** | **fixed**, `upstream/patches/0005` |
| 6 | `mountmgr`: a removable UDisks drive with empty `MediaCompatibility` stays `DEVICE_UNKNOWN` | `GetDriveType` never returns `DRIVE_REMOVABLE` for a USB stick | **fixed**, `upstream/patches/0006` |
| 7 | `mountmgr`: `StorageDeviceProperty` is faked — `RemovableMedia = FALSE`, `BusType = BusTypeScsi` for **every** device | applications that filter on removability or bus type see a USB stick as a fixed SCSI disk | **fixed**, `upstream/patches/0007` |
| 8 | `setupapi`: `SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` is a NULL placeholder | an application cannot match an enumerated device to a drive letter, so a USB stick can never be found | **fixed**, `upstream/patches/0008` |
| 9 | `mountmgr` does not write a `GUID_DEVCLASS_VOLUME` devnode | SetupAPI enumerates no volumes at all, so a USB stick can never be found however healthy the mount is | **fixed**, `upstream/patches/0009` |
| 10 | `wineusb`: no `\\.\HCDn` device object exists at all | rekordbox validates a Pioneer controller by walking the USB bus the way `usbview.exe` does; ten `CreateFileW` on `HCD0..9` all fail, so it **destroys the device object it just built** and never opens the controller's MIDI port | **fixed**, `upstream/patches/rbw-usbhcd.c` |
| — | **host**: `rtkit-daemon` absent, so the desktop portal advertises no realtime budget and `libpipewire-module-rt` sets `RLIMIT_RTTIME` to zero **inside every PipeWire ALSA client** | any thread later put on a real-time policy is killed by `SIGXCPU` with no error — this is what killed rekordbox 3/3 in T10 phase 45 | **fixed**, install `rtkit`; T12 |
| 12 | `mmdevapi`: `RegisterAudioSessionNotification` returns `S_OK` and never calls back | a client that registers and waits is told it succeeded and waits forever; a stub that *fails* would leave the documented `GetState` fallback available | **reported**, `upstream/reports/bugzilla-mmdevapi-session-notification.md`. Impact on rekordbox not measured |
| 11 | `avrt`: `AvSetMmThreadCharacteristics` is a **stub** | no audio thread gets real-time priority | **WON'T FIX, measured** — an RT policy is *fatal* with `WasapiPolling=1` (a non-blocking spinner is `SIGKILL`ed against any finite `RLIMIT_RTTIME`), and a nice boost changes nothing (2 teardowns either way). T12 |

And one defect that was **ours**: `0002` widened the exclusive buffer to four
periods, which rekordbox reads back through `GetBufferSize()` and uses as its
audio block size. That single factor of four is what broke PC MASTER OUT for
five days. Written up for upstream in
`upstream/reports/NOTES-mmdevapi-buffer-widening.md` — *widening a client's buffer is
not invisible to the client.*

## What is left between here and Gold

**The actionable list lives in [`docs/REMAINING-STEPS-TO-GOLD.md`](REMAINING-STEPS-TO-GOLD.md)** — who can do each item and what would count as done. What follows is the reasoning behind it.

### Blocking Gold

1. ~~The volume devnode belongs in `mountmgr.sys`.~~ **Done** —
   `upstream/patches/0009`. mountmgr now writes and removes the `STORAGE\Volume`
   devnode itself, as `set_volume_info()` and `delete_dos_device()` already know
   every field it needs. The stopgap `research/probes/usbdevnode.sh` wrote that key from
   outside, keyed on a `\Device\HarddiskN` name that is assigned in plug order
   and is not stable across boots, so it was per-stick and per-session.
2. **An exported stick has never been read by a real CDJ**, and has not been
   through a full `rekordcrate` / `crate-digger` parse. `bin/pdbcheck.py` is the
   gate, not the finish line.

### Blocking the user's stricter standard

3. **No full DDJ-400 performance pass.** Jog wheels and LEDs are confirmed;
   every pad mode, the FX section, filters, the crossfader curve, headphone cue
   and hot cues are not. Needs hands on the hardware, and a script cannot do it.
4. ~~`AvSetMmThreadCharacteristics` is a stub.~~ **Closed 2026-08-20, measured
   both ways (T12).** An RT policy is *fatal* in the shipping configuration:
   `WasapiPolling=1` makes the audio thread a 114,871-call/s spinner, and a
   non-blocking real-time thread is `SIGKILL`ed against any finite
   `RLIMIT_RTTIME`. A nice boost to -15 changes nothing: 2 teardowns in 330 s
   either way. So this stub is **not** the latency ceiling it was assumed to be,
   and 512 samples stands — which is what a DDJ-400 user runs on Windows.
   The 256-frame teardowns have some other, still unidentified cause.

### Blocking the AUR release specifically

5. ~~Nothing has ever been built from a clean prefix.~~ **Done 2026-08-20.**
   The package was installed with `pacman -U`, and `rekordbox-wine --setup`,
   `--install` and a first launch were run from `/usr/bin` into an empty path:
   prefix created, all six system libraries verified, rekordbox installed
   unattended, window mapped in ~5 s and repainting, sign-in dialog reached.
   See T11.
6. **The package has never been installed on a SECOND MACHINE.** It has now
   been installed and exercised from scratch here, which is a different and
   weaker claim: same kernel, same Wine, same PipeWire, same hardware. Nobody
   has followed `docs/PACKAGE.md` end to end anywhere else.

## What a user gets today, honestly stated

One command, `rekordbox-wine`, which checks and repairs its own configuration
and then launches. rekordbox 7.2.18 runs, signs in, shows the library, analyses
and plays tracks on two decks at real time, drives a DDJ-400 with working jog
wheels and LEDs, and plays to the controller and the laptop speakers at the same
time with no dropouts. The File menu opens, EXPORT mode is reachable, and a USB
stick exports with a database that parses cleanly outside Wine.

The two named holes left are that no exported stick has been carried to a real
CDJ, and that the DDJ-400 has never been through a full performance pass. Both
need hands on hardware. That is a real DJ setup with two unverified edges, not a
demo.
