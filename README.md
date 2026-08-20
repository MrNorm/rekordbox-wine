# rekordbox under Wine

Runs **rekordbox 7.2.x** on Linux with a **Pioneer DDJ-400**, including
**PC MASTER OUT** — sound to the controller and the computer's own speakers at
the same time.

This repository is two things: the Wine fixes that make that possible, and the
investigation that found them. If you just want to DJ, read the next section and
stop. If you want to know *why* Wine needed nine patches, everything after
"How this was found" is the paper trail.

> **rekordbox is not included.** It is proprietary. Download it from
> [rekordbox.com](https://rekordbox.com) and sign in with your own AlphaTheta
> account. This project ships only the Wine fixes and a launcher.

## Install

```sh
# from the AUR
paru -S rekordbox-wine        # or: yay -S rekordbox-wine

# install rekordbox itself and start it. No root, no further setup.
rekordbox-wine --install ~/Downloads/rekordbox_7.2.18.exe
rekordbox-wine
```

`rekordbox-wine` checks its own configuration before every start and repairs
what it can. `rekordbox-wine --check` reports without changing anything.

### It does not touch your system Wine

Six of the fixes are unix libraries and drivers that Wine cannot override
per-prefix. Rather than overwrite files owned by your distribution's `wine`
package — which would be a file conflict, would be undone by every Wine
upgrade, and would change the behaviour of **every other Wine application on
your machine** — rekordbox-wine builds a private Wine tree on first run: about
16 MB of symlinks into your system Wine, plus the six patched files.

Everything else on your machine keeps using your distribution's Wine, unchanged.
You can prove it at any time:

```sh
/usr/share/rekordbox-wine/bin/verifyloaded.sh          # what rekordbox mapped
/usr/share/rekordbox-wine/bin/verifyloaded.sh <pid>    # any other Wine app
```

That reads `/proc/<pid>/maps`, so it reports what the running process actually
loaded rather than what is on disk. See [`THEMES/T13`](THEMES/) for why that
distinction cost a day.

To uninstall completely, remove the package and delete
`~/.local/share/rekordbox-wine`. Nothing outside it was ever modified.

## What works

Measured, with a run id behind every claim in
[`GOLD-STATUS.md`](GOLD-STATUS.md):

- The application renders and repaints. **Stock Wine paints one frame and
  freezes** — this is why nobody had reported rekordbox 7.2.x running at all.
- Library, waveforms, analysis, and two decks playing at once at 1.00× real time.
- DDJ-400 exclusive-mode audio at 44100 Hz, and the jog wheels and LEDs.
- **PC MASTER OUT** with zero stream teardowns over 465 s of continuous play.
- The File menu, and the view-mode selector that gates EXPORT mode.
- USB export, with the resulting `export.pdb` validated outside Wine.

## What is not proven

Stated plainly, because a DJ turning up to a gig deserves to know which edges
have been tested:

- **No exported stick has been read by a real CDJ.** `bin/pdbcheck.py` validates
  the database structurally; that is a gate, not a finish line.
- **The DDJ-400 has never been through a full performance pass** — every pad
  mode, the FX section, filters, crossfader curve, headphone cue, hot cues.
- Latency is 512 samples (11.6 ms), which is what a DDJ-400 user runs on
  Windows too. Going lower costs roughly one stream teardown every 330 s,
  because `AvSetMmThreadCharacteristics` is still a stub in Wine and no audio
  thread gets real-time priority.

## What was actually wrong with Wine

Twelve defects, ten fixed. The patches are in [`upstream/`](upstream/) and are
meant to go upstream — that is the point of the exercise.

| # | component | defect |
|---|---|---|
| 1 | `dxgi` | `IDXGIOutput::WaitForVBlank` unimplemented — any JUCE 8 application paints one frame and freezes |
| 2 | `mmdevapi` | event-driven exclusive streams refused outright — no DJ controller usable at all |
| 3 | `winealsa` | the exclusive-mode event is signalled even when no period is free — 343 buffer refusals in 344 periods |
| 4 | `winealsa` | SysEx split across two USB transfers — the DDJ-400 never authenticates |
| 5 | `winex11` | popup menus are handed to the window manager, which places them offscreen — no File menu, no EXPORT mode |
| 6 | `mountmgr` | a removable drive with unknown media type is reported as no media |
| 7 | `mountmgr` | `StorageDeviceProperty` is faked: every device claims fixed media on a SCSI bus |
| 8 | `setupapi` | `SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` is a NULL placeholder, so a device cannot be matched to a drive letter |
| 9 | `mountmgr` | no `STORAGE\Volume` device node is ever written, so SetupAPI enumerates no volumes at all |
| 10 | `wineusb` | no `\\.\HCDn` device object exists, so rekordbox's USB validation fails and it discards the controller it just detected |
| 11 | `avrt` | `AvSetMmThreadCharacteristics` is a stub — **won't fix**, measured: granting real-time priority is fatal while the audio thread polls |
| 12 | `mmdevapi` | `RegisterAudioSessionNotification` returns `S_OK` and never calls back — **reported** |

And one defect that was ours, written up in
[`upstream/NOTES-mmdevapi-buffer-widening.md`](upstream/): patch 2 widened the
exclusive buffer to four periods, rekordbox reads that back through
`GetBufferSize()` and uses it as its audio block size, and that single factor of
four broke PC MASTER OUT for five days. *Widening a client's buffer is not
invisible to the client.*

## How this was found

The investigation is deliberately reproducible, because it outlived many
sessions:

| | |
|---|---|
| [`STATE.md`](STATE.md) | current hypothesis and the single next action |
| [`JOURNAL.md`](JOURNAL.md) | append-only timeline |
| [`THEMES/`](THEMES/) | one file per investigation theme, each with its root-cause analysis |
| [`GOLD-STATUS.md`](GOLD-STATUS.md) | every capability, its state, and the evidence |
| [`REMAINING-STEPS-TO-GOLD.md`](REMAINING-STEPS-TO-GOLD.md) | what is left, who can do it, and how we would know |
| [`PACKAGE.md`](PACKAGE.md) | what the package installs and why |
| [`REGRESSION.md`](REGRESSION.md) | the tests that must pass before a release |
| `runs/` | per-run evidence: manifest, log, screenshots, verdict |

`bin/rbw` is the harness. Run it with no arguments for the commands.

The technique that broke the hardest bug open, after DWARF unwinding gave
nothing and gdb crashed the application three times out of three, was
**LBR call-graph profiling** — `perf record -e cycles:u --call-graph lbr` needs
no unwind information at all — combined with **hardware execute breakpoints**
(`perf record -e mem:<addr>:x`) to count how often a specific instruction in a
stripped 100 MB binary actually ran. See [`THEMES/T10`](THEMES/).

## Licence

The Wine patches are LGPL-2.1-or-later, matching Wine. The harness and launcher
scripts are MIT.
