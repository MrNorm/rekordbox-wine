# rekordbox under Wine

[![build](https://github.com/MrNorm/rekordbox-wine/actions/workflows/build.yml/badge.svg)](https://github.com/MrNorm/rekordbox-wine/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/MrNorm/rekordbox-wine)](https://github.com/MrNorm/rekordbox-wine/releases/latest)
[![licence](https://img.shields.io/badge/licence-LGPL--2.1%20%2F%20MIT-blue)](LICENSE)

Runs **rekordbox 7.2.x** on Linux with a **Pioneer DDJ-400**, including
**PC MASTER OUT** — audio to the controller and the computer's speakers at once.

Ten Wine patches and a launcher that applies and verifies them.

> **rekordbox is not included.** Download it from
> [rekordbox.com](https://rekordbox.com) and sign in with your own AlphaTheta
> account.

**Contents:** [Requirements](#requirements) · [Install](#install) ·
[First run](#first-run) · [DDJ-400 setup](#ddj-400-setup) ·
[Troubleshooting](#troubleshooting) · [Keeping it working](#keeping-it-working) ·
[What works](#what-works) · [What is not proven](#what-is-not-proven)

## Requirements

| | |
|---|---|
| Distribution | **Arch** (packaged and tested). Debian and Fedora packaging exists but has never been built on those distributions. |
| Architecture | x86_64 |
| Wine | **wine-staging**, currently **11.16**. Plain `wine` is untested. |
| GPU | Tested on Intel Iris Xe. Nvidia and AMD untested here. |
| Controller | DDJ-400 for the controller and PC MASTER OUT claims. Other hardware untested. |
| Root needed | Only to install the package and replug/reboot for the udev and module rules. |

## Install

### Prebuilt package

```sh
wine --version    # note the version
```

Download the asset from [Releases](https://github.com/MrNorm/rekordbox-wine/releases/latest)
whose name matches that version, then:

```sh
sudo pacman -U rekordbox-wine-git-*-wine11.16.pkg.tar.zst
```

Assets are named for the Wine they were built against. The patched libraries are
compiled against Wine internals and work with that version only. If no asset
matches your Wine, build from source.

### From source

Compiles the Wine components against the Wine you have. Takes 20–30 minutes.

```sh
git clone https://github.com/MrNorm/rekordbox-wine.git
cd rekordbox-wine/packaging
makepkg -si
```

The package version records the commit it was built from
(`0.2.0.r<commits>.g<short-sha>`). To update: `git pull`, then `makepkg -si`.

`paru` installs from AUR or from package files, not from a local PKGBUILD
directory, so hand it the result: `paru -U rekordbox-wine-git-*.pkg.tar.zst`.

**Not on the AUR.** AUR pushes have been blocked over malware injection; this
project distributes from GitHub instead.

### Other distributions

`packaging/debian/` and `packaging/rekordbox-wine.spec` are complete and produce
the same payload, but neither has been built on its own distribution.

## First run

```sh
rekordbox-wine --install ~/Downloads/rekordbox_7.2.18.exe
rekordbox-wine
```

Neither needs root. The installer shows one language dialog — press Return.

The launcher runs on every start and repairs drift: builds its private Wine tree,
installs the patched DLLs into the prefix, applies the audio settings PC MASTER
OUT needs, and corrects Wine's own menu entry.

`rekordbox-wine --check` reports all of it and changes nothing.

## DDJ-400 setup

Two one-off steps that need root or physical access:

- **Replug the controller**, so the installed udev rule applies.
- **Reboot, or `sudo modprobe -r snd_seq_dummy`.** Without this rekordbox binds
  an ALSA loopback instead of the controller.

`rekordbox-wine --check` reports whether either is outstanding.

## Troubleshooting

Run `rekordbox-wine --check` first. It names the problem in most cases.

| symptom | cause | fix |
|---|---|---|
| `Not launching` and a list of blockers | Wine was upgraded; the patched components are built for the old version | Rebuild — see [Wine updates](#wine-updates) |
| Starts, one frame, then frozen | Started through Wine's own menu entry, bypassing the patches | Use `rekordbox-wine`, or the entry marked *(via rekordbox-wine)* |
| Two menu entries, one broken | Wine regenerates its entry on install | The launcher corrects it on every start |
| Controller absent, or MIDI binds to something else | udev rule or `snd_seq_dummy` | [DDJ-400 setup](#ddj-400-setup) |
| Sample-rate list empty in Preferences | Audio driver is `winepulse`, which has no exclusive mode | `--check` reports the driver; it must be `alsa` |
| A sound device vanishes from PipeWire mid-session | WirePlumber 0.5.15 crashes in its own ALSA error handler | `systemctl --user restart wireplumber` |
| PC MASTER OUT stalls | `WasapiPolling` / `AudioBufferSize` | The launcher seeds both; `--check` verifies them |

## Keeping it working

### rekordbox updates

Nothing to do. rekordbox updates itself inside the prefix and the launcher starts
the newest version it finds. No Wine component is tied to a rekordbox version.

The launcher names the version it starts:

```
ok    rekordbox 7.2.18 — measured; see docs/GOLD-STATUS.md
warn  rekordbox 7.3.0 has not been measured by this project
```

It warns and starts. Measured versions are listed in
[`upstream/supported-rekordbox.txt`](upstream/supported-rekordbox.txt).

### Wine updates

A Wine upgrade requires a rebuild. The patched components are compiled against
Wine's internal interfaces, which change between releases.

The launcher **refuses to start** on a mismatch and prints the commands:

```sh
/usr/share/rekordbox-wine/bin/build-patched-dlls.sh   # 20–30 min, no root
/usr/share/rekordbox-wine/bin/make-private-wine.sh
```

Or install a release built for your Wine, or hold Wine back:

```
# /etc/pacman.conf
IgnorePkg = wine-staging
```

Untested Wine versions need `RBW_ALLOW_UNTESTED_WINE=1` to build. Tested versions
are listed in [`upstream/patches/supported-wine.txt`](upstream/patches/supported-wine.txt).

**The two version lists behave differently.** An unlisted Wine cannot load, so
the launcher refuses. An unlisted rekordbox is only unmeasured, so it warns.

## What works

Every claim has a run id in [`docs/GOLD-STATUS.md`](docs/GOLD-STATUS.md).

- Renders and repaints. Stock Wine paints one frame and freezes.
- Library, waveforms, analysis, two decks at 1.00× real time.
- DDJ-400 exclusive-mode audio at 44100 Hz; jog wheels and LEDs.
- PC MASTER OUT with zero stream teardowns over 465 s.
- File menu and the view-mode selector that gates EXPORT mode.
- USB export, with `export.pdb` validated outside Wine.

Measured on wine-staging 11.15 with rekordbox 7.2.17/7.2.18. On 11.16 only
"launches and repaints" has been re-measured.

## What is not proven

- **No exported stick has been read by a real CDJ.** `bin/pdbcheck.py` validates
  the database structurally.
- **No full DDJ-400 performance pass** — pad modes, FX, filters, crossfader
  curve, headphone cue, hot cues.
- Latency is 512 samples (11.6 ms), the same as a DDJ-400 on Windows. Lower costs
  about one stream teardown every 330 s, because `AvSetMmThreadCharacteristics`
  is a stub in Wine.

## System impact

Six fixes are unix libraries and drivers that Wine cannot override per-prefix.
Instead of overwriting files owned by your `wine` package, the launcher builds a
private Wine tree on first run: ~16 MB of symlinks plus the six patched files.
Other Wine applications are unaffected.

```sh
/usr/share/rekordbox-wine/bin/verifyloaded.sh          # what rekordbox mapped
/usr/share/rekordbox-wine/bin/verifyloaded.sh <pid>    # any other Wine app
```

Reads `/proc/<pid>/maps`, so it reports what a process loaded rather than what is
on disk.

To remove: uninstall the package and delete `~/.local/share/rekordbox-wine`.

## Wine defects found

Twelve, ten fixed. Patches in [`upstream/patches/`](upstream/patches/).

| # | component | defect |
|---|---|---|
| 1 | `dxgi` | `IDXGIOutput::WaitForVBlank` unimplemented — any JUCE 8 application paints one frame and freezes |
| 2 | `mmdevapi` | event-driven exclusive streams refused outright — no DJ controller usable |
| 3 | `winealsa` | exclusive-mode event signalled with no period free — 343 buffer refusals in 344 periods |
| 4 | `winealsa` | SysEx split across two USB transfers — the DDJ-400 never authenticates |
| 5 | `winex11` | popup menus handed to the window manager, which places them offscreen — no File menu, no EXPORT mode |
| 6 | `mountmgr` | removable drive with unknown media type reported as no media |
| 7 | `mountmgr` | `StorageDeviceProperty` faked: every device claims fixed media on a SCSI bus |
| 8 | `setupapi` | `SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` is a NULL placeholder — a device cannot be matched to a drive letter |
| 9 | `mountmgr` | no `STORAGE\Volume` device node written, so SetupAPI enumerates no volumes |
| 10 | `wineusb` | no `\\.\HCDn` device object, so rekordbox's USB validation fails and it discards the controller |
| 11 | `avrt` | `AvSetMmThreadCharacteristics` is a stub — **won't fix**: granting real-time priority is fatal while the audio thread polls |
| 12 | `mmdevapi` | `RegisterAudioSessionNotification` returns `S_OK` and never calls back — **reported** |

One defect was ours: patch 2 widened the exclusive buffer to four periods,
rekordbox read that back via `GetBufferSize()` and used it as its audio block
size. Written up in
[`upstream/reports/NOTES-mmdevapi-buffer-widening.md`](upstream/reports/NOTES-mmdevapi-buffer-widening.md).

## CI

- **`build.yml`** — builds the package daily and per push against Arch's current
  wine-staging, and verifies the patch markers inside the built package.
- **`wine-watch.yml`** — checks Arch's wine-staging version daily and opens an
  issue when it is ahead of `supported-wine.txt`.
- **`release.yml`** — publishes a package per `v*` tag, Wine version in the asset
  name.
- **`aur.yml`** — manual dispatch, gated on a secret.

The rekordbox axis cannot be tested in CI: proprietary, 660 MB installer behind a
JavaScript download page, sign-in needs a real account.

## Documentation status

This repository is the only thing published. The WineHQ Bugzilla reports, the
WirePlumber report and the two AppDB submissions are written and **unfiled** —
[`docs/PUBLISHING.md`](docs/PUBLISHING.md) lists what each needs.

The `WaitForVBlank` report matters most: without that fix no JUCE 8 application
paints a second frame.

## Investigation

| | |
|---|---|
| [`docs/investigation/STATE.md`](docs/investigation/STATE.md) | current hypothesis and next action |
| [`docs/investigation/JOURNAL.md`](docs/investigation/JOURNAL.md) | append-only timeline |
| [`docs/investigation/THEMES/`](docs/investigation/THEMES/) | one file per theme, each with root-cause analysis |
| [`docs/GOLD-STATUS.md`](docs/GOLD-STATUS.md) | every capability, its state, the evidence |
| [`docs/REMAINING-STEPS-TO-GOLD.md`](docs/REMAINING-STEPS-TO-GOLD.md) | what is left and who can do it |
| [`docs/PACKAGE.md`](docs/PACKAGE.md) | what the package installs and why |
| [`docs/REGRESSION.md`](docs/REGRESSION.md) | tests that must pass before a release |

`bin/rbw` is the harness; run it with no arguments for the commands.

The hardest bug was broken open with **LBR call-graph profiling**
(`perf record -e cycles:u --call-graph lbr`, which needs no unwind information)
plus **hardware execute breakpoints** (`perf record -e mem:<addr>:x`) to count
how often one instruction in a stripped 100 MB binary ran. See
[`docs/investigation/THEMES/`](docs/investigation/THEMES/) T10.

## Licence

Wine patches LGPL-2.1-or-later, matching Wine. Harness and launcher scripts MIT.
