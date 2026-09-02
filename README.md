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

**This is not on the AUR**, and deliberately so — AUR pushes have been blocked
over malware injection, and the point of this project is a chain you can audit.
Install it straight from this repository instead.

### Arch, from GitHub

```sh
git clone https://github.com/MrNorm/rekordbox-wine.git
cd rekordbox-wine/packaging
makepkg -si
```

`packaging/PKGBUILD` clones this repository by URL and records the exact commit it
built in the package version (`0.2.0.r<commits>.g<short-sha>`), so you can always
see what you installed. Everything is compiled on your machine against the Wine
you actually have — no binaries are downloaded.

The first build compiles the Wine components from the patch series and takes
roughly 20–30 minutes. Subsequent installs reuse the cached Wine source.

Prefer `paru` to do the installing? It builds from AUR or from package *files*,
not from a local PKGBUILD directory, so hand it the result:

```sh
paru -U rekordbox-wine-git-*.pkg.tar.zst
```

To update later:

```sh
cd rekordbox-wine && git pull
cd packaging && makepkg -si
```

### Then, on any distribution

```sh
rekordbox-wine --install ~/Downloads/rekordbox_7.2.18.exe
rekordbox-wine
```

Debian/Ubuntu and Fedora packaging live in `packaging/debian/` and
`packaging/rekordbox-wine.spec`. Both are complete and produce identical
payloads, but see the note on portability at the end — they have not yet been
built on their own distributions.

That is the whole setup, and none of it needs root. rekordbox itself is
proprietary and not included — download it from
[rekordbox.com](https://rekordbox.com) and sign in with your own AlphaTheta
account.

The launcher does the rest on **every** start, so it repairs itself if anything
drifts: builds its private Wine tree, installs the patched DLLs into the prefix,
applies the audio settings that make PC MASTER OUT work, and corrects Wine's own
menu entry. `rekordbox-wine --check` reports all of it without changing
anything.

### Using a DDJ-400? Two one-off system steps

These need root or a physical replug, so they cannot be done for you:

- **Replug the controller once**, so the udev rule the package installed applies.
- **Reboot, or `sudo modprobe -r snd_seq_dummy`**, so the module blacklist takes
  effect. Without it rekordbox binds an ALSA loopback instead of your controller.

`rekordbox-wine --check` tells you if either is still outstanding.

### Updates: one thing to do, and only when Wine moves

- **rekordbox updates itself** — the launcher always starts the newest version
  it finds, and re-corrects Wine's regenerated menu entry.
- **Your distribution updates Wine** — this one is *not* free, and the README
  used to claim it was. The patched components are compiled against Wine's
  internal interfaces, which change between releases, so a Wine upgrade means a
  rebuild. What the launcher guarantees is that it will **tell you** rather than
  start a session that cannot work: it checks the Wine each component was built
  for and refuses, naming the rebuild command. See *When your distribution
  upgrades Wine* below.

### Starting it: use the launcher, not Wine's own menu entry

When rekordbox's installer runs, Wine writes its own Start Menu entries named
**"rekordbox 7"**. Those launch the system Wine directly, bypassing the private
Wine tree and the prefix overrides — so they start an *unpatched* rekordbox,
which paints one frame and freezes. The obvious-looking entry is the broken one.

`rekordbox-wine` fixes this rather than asking you to remember it: on every
`--setup` and every launch it rewrites those entries to call the launcher, keeps
the original beside them as `*.desktop.rbw-original`, and leaves the uninstaller
alone. `--check` reports them without changing anything.

So all of these work, and all start the same, correctly configured rekordbox:

```sh
rekordbox-wine                       # the command
```

- **rekordbox 7 (via rekordbox-wine)** — Wine's entry, corrected
- **rekordbox (Wine)** — the entry this package installs

### Updates

The launcher finds the newest `rekordbox.exe` in the prefix, so a **rekordbox**
update just works, and Wine's regenerated menu entry is corrected again on the
next start.

### When rekordbox updates itself

Nothing to do, and nothing to rebuild.

rekordbox updates itself from inside the prefix — its update manager offers the
new build at startup, and you can take it. No Wine component is tied to a
rekordbox version, and the launcher starts the newest `rekordbox.exe` it finds
rather than a path anyone typed, so the new install is picked up automatically.

The launcher does tell you where you stand:

```
ok    rekordbox 7.2.18 — measured; see docs/GOLD-STATUS.md
```

or, on a version this project has not put through its tests:

```
warn  rekordbox 7.3.0 has not been measured by this project
      Known: 7.2.17, 7.2.18
      Starting anyway — the fixes are Wine-side and a rekordbox update does
      not invalidate them.
```

**It warns and starts. It does not refuse** — and that is the opposite of what
it does for an unlisted *Wine* version, deliberately:

| axis | an unlisted version means | the launcher |
|---|---|---|
| **Wine** | the patched libraries cannot load — nothing will work | **refuses**, and says what to rebuild |
| **rekordbox** | unmeasured, almost certainly fine | **warns**, and starts |

Our fixes implement Windows APIs that rekordbox calls, so a rekordbox point
release does not invalidate them; a Wine release routinely does. Refusing to
start over an unmeasured rekordbox would be stopping you from DJing to satisfy
a paperwork gap. The one cross-version measurement there is supports this: on
2026-08-18 the audio-engine numbers on 7.2.18 matched 7.2.17 to two decimal
places.

If a new version works for you, `upstream/supported-rekordbox.txt` is a one-line
contribution. If something regressed, that is worth an issue — **this axis
cannot be tested in CI**: rekordbox is proprietary, the installer is 660 MB
behind a JavaScript download page, and signing in needs a real AlphaTheta
account. It is human-measured by construction, which is why it is written down
rather than remembered.

### When your distribution upgrades Wine

This is the one update that costs you something, and it is worth understanding
because getting it wrong looks exactly like the software randomly breaking.

Four of the fixes are Wine's own unix libraries and two are PE drivers. They are
compiled against Wine's **internals**, which are not a stable interface — Wine
changes them freely between releases. A library built for one Wine is not valid
for the next one. When Arch went 11.15 → 11.16, our `winex11.so` answered
OpenGL driver interface **38** to an `opengl32` that wanted **39**, so there was
no OpenGL, so rekordbox could not render, so it did not open.

What this package now guarantees:

- The patched libraries carry the Wine version they were built for
  (`winedll/.built-for-wine`), and the private tree records both that and the
  Wine it was assembled against. Before, the tree recorded only the system Wine
  — a stamp that said "fine" no matter what was inside it.
- `rekordbox-wine` **refuses to launch** on a mismatch and prints the rebuild
  command. It used to print the failure and start anyway, which turned a legible
  error into a mystery.
- Rebuilding is one command and no root:

  ```sh
  /usr/share/rekordbox-wine/bin/build-patched-dlls.sh   # 20–30 min
  /usr/share/rekordbox-wine/bin/make-private-wine.sh
  ```

  If the new Wine is not in `upstream/patches/supported-wine.txt` it will ask
  you to confirm with `RBW_ALLOW_UNTESTED_WINE=1`. That is a speed bump, not a
  wall — trying a new Wine is how the list grows.

- Or hold Wine where it works, which is a legitimate answer for a machine you
  perform on:

  ```
  # /etc/pacman.conf
  IgnorePkg = wine-staging
  ```

The full account is `docs/investigation/THEMES/T14-wine-upgrade-regression.md`.

### Prebuilt packages, and how breakage gets found before you do

`.github/workflows/` builds this package against **whatever wine-staging Arch
ships today**, on every push and once a day, and verifies the markers in the
files that actually ended up inside the package. A Wine release that breaks the
patch series becomes a red pipeline naming the failing patch, instead of
becoming somebody's dead set.

- **`build.yml`** — daily and per-push build + marker verification. Attaches the
  `.pkg.tar.zst` as a workflow artifact.
- **`wine-watch.yml`** — asks Arch daily what wine-staging is, and keeps one
  issue open while it is ahead of `supported-wine.txt`.
- **`release.yml`** — on a `v*` tag, publishes an installable package to GitHub
  Releases. **Every asset names the Wine it is bound to**, because that is the
  only thing that makes a binary safe to hand someone.
- **`aur.yml`** — manual dispatch only, and only if an `AUR_SSH_KEY` secret
  exists. Publishing here is opt-in for the reason at the top of this file.

To install a prebuilt package instead of compiling:

```sh
wine --version                       # note the version
# download the asset whose name matches it, from the Releases page
sudo pacman -U rekordbox-wine-git-*-wine<version>.pkg.tar.zst
```

If no published asset matches your Wine, build from source — that path compiles
against the Wine you actually have and is always correct.

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
loaded rather than what is on disk. See [`docs/investigation/THEMES/T13`](docs/investigation/THEMES/) for why that
distinction cost a day.

To uninstall completely, remove the package and delete
`~/.local/share/rekordbox-wine`. Nothing outside it was ever modified.

## Where this is written down publicly

`docs/PUBLISHING.md` is the honest ledger: this repository — README,
`docs/GOLD-STATUS.md`, Releases, and the patches themselves — is the only thing
published so far. The WineHQ Bugzilla reports, the WirePlumber report and the
two AppDB submissions are **written and unfiled**; each needs an account and a
human, and `docs/PUBLISHING.md` says exactly which and why.

That matters most for one of them: `IDXGIOutput::WaitForVBlank` is an
`E_NOTIMPL` stub in Wine, and without it **no JUCE 8 application paints a second
frame**. Until that is filed, every other person hitting it starts from zero.

## What works

Measured, with a run id behind every claim in
[`docs/GOLD-STATUS.md`](docs/GOLD-STATUS.md):

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

Twelve defects, ten fixed. The patches are in [`upstream/patches/`](upstream/patches/) and are
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
[`upstream/reports/NOTES-mmdevapi-buffer-widening.md`](upstream/): patch 2 widened the
exclusive buffer to four periods, rekordbox reads that back through
`GetBufferSize()` and uses it as its audio block size, and that single factor of
four broke PC MASTER OUT for five days. *Widening a client's buffer is not
invisible to the client.*

## How this was found

The investigation is deliberately reproducible, because it outlived many
sessions:

| | |
|---|---|
| [`docs/investigation/STATE.md`](docs/investigation/STATE.md) | current hypothesis and the single next action |
| [`docs/investigation/JOURNAL.md`](docs/investigation/JOURNAL.md) | append-only timeline |
| [`docs/investigation/THEMES/`](docs/investigation/THEMES/) | one file per investigation theme, each with its root-cause analysis |
| [`docs/GOLD-STATUS.md`](docs/GOLD-STATUS.md) | every capability, its state, and the evidence |
| [`docs/REMAINING-STEPS-TO-GOLD.md`](docs/REMAINING-STEPS-TO-GOLD.md) | what is left, who can do it, and how we would know |
| [`docs/PACKAGE.md`](docs/PACKAGE.md) | what the package installs and why |
| [`docs/REGRESSION.md`](docs/REGRESSION.md) | the tests that must pass before a release |
| `runs/` | per-run evidence: manifest, log, screenshots, verdict |

`bin/rbw` is the harness. Run it with no arguments for the commands.

The technique that broke the hardest bug open, after DWARF unwinding gave
nothing and gdb crashed the application three times out of three, was
**LBR call-graph profiling** — `perf record -e cycles:u --call-graph lbr` needs
no unwind information at all — combined with **hardware execute breakpoints**
(`perf record -e mem:<addr>:x`) to count how often a specific instruction in a
stripped 100 MB binary actually ran. See [`docs/investigation/THEMES/T10`](docs/investigation/THEMES/).

## Licence

The Wine patches are LGPL-2.1-or-later, matching Wine. The harness and launcher
scripts are MIT.
