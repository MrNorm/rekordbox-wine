# Remaining steps to Gold — 2026-08-20

**This is the to-do list, not the status page.** `GOLD-STATUS.md` records what
works and the evidence for it; `STATE.md` says what to do next session. This
document answers one question: *what is actually left, who can do it, and how
would we know it was done?*

Nothing below is speculative. Every item is either a deliverable the mission
statement names, or a gap a measurement exposed.

## Where the line is

Two standards, and they are not the same distance away.

**AppDB Gold** — "installs and runs with no workarounds the user has to
discover for themselves." The *software* is there: every capability has been
exercised and measured. What is missing is **distribution** — the package has
never been published, so the workaround a user must currently discover is
"clone a git repository and read it".

**The stricter standard set on 2026-08-13** — full function and feature, real
performance use, 1:1 with Windows, **the DDJ-400 as the acceptance test**. Not
met, for one blunt reason: **the acceptance test has never been run.**

---

## A. Deliverables that are named in the mission and are not done

These need no hardware and no luck. They are simply not finished.

### A1. Publish the package — **blocked on a repository URL**

`packaging/PKGBUILD` still carries `url="https://github.com/REPLACE-ME/..."`
and `sha256sums=('SKIP')`. The build, check and install stages are all verified
(and now for three formats — see D1), but nothing has been published anywhere.

**Done when:** the AUR package installs on a machine that has never seen this
repository, by name, and `rekordbox-wine --check` passes on it.

**Needs from you:** the repo URL and a tagged release to hash. Everything else
is mechanical.

### A2. File the upstream reports — **blocked on accounts**

`CLAUDE.md` calls the WineHQ report "a project deliverable in its own right".
Four drafts exist in `upstream/`, all marked unfiled:

| draft | target |
|---|---|
| `bugzilla-dxgi-waitforvblank.md` | WineHQ Bugzilla — the defect that makes *every* JUCE 8 app paint one frame and freeze |
| `bugzilla-winealsa-sysex-split.md` | WineHQ Bugzilla — SysEx split across two USB transfers |
| `appdb-rekordbox-7217.md` | WineHQ AppDB — two submissions |
| `wireplumber-alsa-node-error-handler.md` | WirePlumber |

**Also not written up:** two defects found since the drafts were made —
`mountmgr`/`setupapi` volume enumeration (patches 0006-0009), and the
`\\.\HCDn` gap (`rbw-usbhcd.c` + patch 0010).

**And one correction to make before anything is sent:**
`upstream/appdb-rekordbox-7217.md` line 52 states *"Bug report and patch filed
upstream; see the linked bug."* That is **false** — nothing is filed — and it
would be published as written.

**Needs from you:** a WineHQ Bugzilla account and an AppDB login. Bugzilla also
sits behind Anubis, which a script cannot pass.

### A3. Submit the patches

Ten patches plus a source splice, none sent. `upstream/0001` (dxgi
`WaitForVBlank`) is the one with reach far beyond rekordbox — it is why nobody
had ever reported rekordbox 7.2.x reaching its own window.

---

## B. The acceptance test, which has never been run

### B1. Full DDJ-400 performance pass — **needs hands on hardware**

Confirmed working: jog wheels, LEDs, MIDI in both directions, the device
authenticating, and audio to the controller. **Never tested:** every pad mode,
the FX section, filters, the crossfader curve, headphone cue, hot cues, loop
controls, and the tempo fader under real use.

**Done when:** someone plays a set on it and nothing behaves differently from
Windows. A script cannot do this and should not pretend to.

### B2. An exported stick read by a real CDJ — **needs a CDJ**

USB export works and `bin/pdbcheck.py` validates the resulting `export.pdb`
outside Wine — 4096-byte pages, 20 tables, all ranges in bounds, track present.
That is a **gate, not a finish line**. Nothing has been carried to real
hardware, and no full `rekordcrate` / `crate-digger` parse has been run either.

### B3. Sign in and play on the clean prefix — **needs your credentials**

The clean-room install was verified end to end *up to the AlphaTheta sign-in
dialog*, which is where the harness stops by rule — credentials are never given
to it and never typed into a logged terminal. So the from-scratch prefix has
proven **"installs and renders"**, not **"installs and DJs"**.

The prefix is sitting signed-out at
`~/.local/share/rekordbox-wine/prefix-clean`. Signing in and playing one track
closes this.

### B4. A second machine

The recipe has been reproduced from zero *here*: same kernel, same Wine, same
PipeWire, same hardware, new prefix. That is a weaker claim than portability,
and `winepaths.sh` (D1) is the first serious attempt to make another distro
work at all — untested off Arch by definition.

---

## C. Open technical questions

### C1. What causes ~2 teardowns per 330 s at a 256-frame buffer?

**Not** scheduling priority — that was measured and closed (T12): a real-time
policy is *fatal* with `WasapiPolling=1` because the audio thread never blocks,
and a nice boost changes nothing (2 teardowns either way, matched protocol).

This is latency **headroom**, not correctness: the shipped 512-sample buffer is
11.6 ms and is what a DDJ-400 user runs on Windows. But the cause is genuinely
unknown, and the previous explanation turned out to be wrong.

### C2. ~~`RegisterAudioSessionNotification` is a lying stub~~ — written up

Now defect 12 in `GOLD-STATUS.md`, with a report drafted at
`upstream/bugzilla-mmdevapi-session-notification.md`. Still **unfiled** (A2),
and its impact on rekordbox is still **unmeasured** — stated as such in the
draft rather than guessed at.

### C3. ~~The audit method keeps being the wrong shape~~ — fixed

`bin/treediff.sh` now diffs the **whole** Wine tree against
"pristine + the series" and fails on anything not in a human-reviewed allowlist,
`upstream/expected-divergence.txt`. Wired into `REGRESSION.md` as a release
gate, and negative-tested: removing an allowlist line makes it exit 1.

The first version of this tool reported a clean pass because it read the wrong
`awk` field — a check that could not fail, in the very tool written to stop
checks that cannot fail.

---

## D. Done since the last review

### D0. Co-existence — the package no longer touches the system Wine

The design that shipped until today overwrote six files owned by the distro's
`wine` package, which changed the behaviour of **every Wine application on the
machine**. `rekordbox-wine` now runs against a private Wine tree (16 MB of
symlinks plus our six patched files and the loader chain), and the distro's Wine
is left alone.

Proven with both applications running at once: rekordbox on patched libraries,
`notepad` on stock, neither affecting the other. Zero `RBW-` markers remain in
the system Wine. No root is required of the user any more, and uninstall is
deleting one directory. See `THEMES/T13`.


### D1. Three package formats, one payload

`packaging/install-tree.sh` is the single definition of what ships. All three
formats call it, and their payloads were verified **identical file-for-file**:

| format | built with | result |
|---|---|---|
| Arch | `makepkg` | `rekordbox-wine-0.2.0-1-x86_64.pkg.tar.zst` |
| Debian | `packaging/debian/` + `dpkg-deb` | `rekordbox-wine_0.2.0-1_amd64.deb` |
| Fedora/RHEL | `packaging/rekordbox-wine.spec` + `rpmbuild` | `rekordbox-wine-0.2.0-1.x86_64.rpm` |

All nine component markers verified inside each built package.

Two portability fixes came out of it. `bin/winepaths.sh` now **detects** Wine's
library directories instead of hardcoding the Arch layout — Debian, Fedora and
the WineHQ builds all differ, and the old code would have reported "your Wine is
broken" on every one of them. And all three formats disable LTO, because Wine
cannot be built with it.

**Caveat, stated plainly:** the `.deb` and `.rpm` were *built on Arch*. The
packaging definitions are correct and the payloads are right, but a genuinely
distribution-native build — with `debhelper`, real dependency resolution, and
that distro's Wine layout — has to happen on Debian and on Fedora. That is part
of B4, not a separate claim.

---

## The short version

| # | what | who |
|---|---|---|
| A1 | publish the package | you (repo URL), then me |
| A2 | file the upstream reports, fix the false "filed" line | you (accounts), me (drafts) |
| A3 | submit the ten patches | you (accounts) |
| B1 | full DDJ-400 performance pass | **only you** |
| B2 | exported stick read by a real CDJ | **only you** |
| B3 | sign in and play on the clean prefix | **only you** |
| B4 | install on a second machine, ideally not Arch | you |
| C1 | why teardowns at 256 frames | me |
| C2 | ~~write up the lying session-notification stub~~ **done** — filing is A2 | — |
| C3 | ~~make full-tree diff the default audit~~ **done** — `bin/treediff.sh` | — |

**Nothing on the software side is known to be broken.** What is left is
distribution, publication, and the acceptance test — and the acceptance test is
the one that decides whether this was worth doing.
