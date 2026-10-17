# T19 — Every system update broke rekordbox: ship a pinned Wine instead

**Status:** IN PROGRESS: built; to be measured on the hardware · **Opened:** 2026-10-17

## Symptom
The user, 2026-10-08: *"The installation feels so brittle right now. Every time
the system changes, rekordbox specifically does not work."* They asked whether a
pacman post-update hook could stop it.

## What actually broke, and how often
`/var/log/pacman.log` shows wine-staging upgraded 2026-08-27 (11.15→11.16),
09-13 (→11.17) and 09-28 (→11.18). Each was in an ordinary `pacman -Syu`,
alongside a `linux` upgrade. The failures that followed, one theme each:

| theme | class | cause |
|---|---|---|
| T14 | Wine upgrade | patched unix libs are ABI-locked to one Wine; an 11.15 winex11.so in an 11.16 tree means no GL and no window |
| T15 | Wine upgrade | the rebuild the launcher prescribed after an upgrade could not run from the installed package |
| T16 | kernel upgrade | no reboot, so the running kernel had no module tree and the controller got no MIDI port |
| T17 | prefix drift (suspect) | rb7 carried 11.15 native cfgmgr32/winmm forced by DllOverrides on 11.18 |
| T18 | menu entries | winemenubuilder deleted the user's working entry |

T14 and T15 are the same root cause: **the package depended on a Wine that the
distro moves on its own schedule.** Every fix so far (an ABI gate, a private
symlink tree, a rebuild path, a daily CI build against Arch's Wine) detected or
repaired that after the fact. None prevented it.

## Why not a pacman hook that rebuilds
- A PostTransaction rebuild compiles Wine components as root, inside pacman, for
  20–30 minutes, and fails whenever a patch no longer applies to the new Wine.
- A PreTransaction hook with AbortOnFail could hold Wine back, but that makes
  this project block the user's whole system update. That is hostile.
- Both keep the dependency on a Wine somebody else versions.

## Decision (user, 2026-10-17: "Lets go with option 1 - include wine in the package")
The package builds and carries a complete Wine and runs rekordbox on nothing else:
- **Pin:** `upstream/wine-runtime.conf`: wine 11.18 plus the wine-staging 11.18
  patchset (sha256-checked), plus the series and the RBW-USBHCD splice.
  Staging, because every measurement was made on staging.
- **Build:** `bin/build-wine-runtime.sh`, from scratch every time, WoW64 mode
  (`--enable-archs=i386,x86_64`). 32-bit Windows programs need no lib32
  packages, which settles the "does rekordbox need anything 32-bit" question.
  Configure is refused if it drops X, GL, ALSA, libusb, udev, dbus, gnutls or the
  fonts. Fuzz is refused unless the exact hunk is in
  `upstream/patches/reviewed-fuzz.txt`.
- **Install:** `/usr/lib/rekordbox-wine/wine`. Dev tools, headers, import libs
  and Wine's own `.desktop` files are trimmed.
- **Launcher:** runs `$RUNTIME/bin/wine` with `WINESERVER` and `PATH` pointing at
  the runtime. It has no system-Wine path at all. The PE fixes (dxgi, mmdevapi,
  setupapi) are now **builtins** of the runtime, so the launcher removes the
  native overrides older packages set. That includes rb7's stale cfgmgr32/winmm,
  and it restores the runtime builtin into system32. `winemenubuilder.exe=d` is
  set for every run.
- **What the distro can still break:** the system libraries the runtime loads.
  `bin/rbw-runtime-check` runs ldd on the key unix libraries and checks every
  soname recorded at build time (`.rbw-sonames`) that maps to a needed
  capability. The launcher turns each problem into a blocker. A pacman hook runs
  the same check after every transaction, and it only checks: no rebuild, no
  abort.
- **Kernel (T16):** `snd_seq_midi` and `snd_usb_audio` are added to
  `modules-load.d`, and `kernel-modules-hook` is an optdepend. The hook also
  reports a kernel upgrade that left no module tree.

Retired by this: the private symlink tree (`make-private-wine.sh`), the
per-prefix native DLL copies, the installed rebuild path (T15) and the ABI
stamps (T14). They are all now unreachable from the launcher.

## Staging + series: measured 2026-10-17
Against pristine 11.18 plus the full staging 11.18 patchset (120 patch sets),
applied in order:
- 0001–0008 and 0010: clean (0007/0008 offsets only).
- **0009 hunk 4: fuzz 2.** Staging gives `set_mount_point_id()` a fourth
  argument; those calls are the hunk's leading context. The inserted line
  `if (drive) rbw_set_volume_devnode( drive );` lands after them, unchanged, in
  the same function. Reviewed harmless, recorded in reviewed-fuzz.txt.
  On vanilla 11.18 the same hunk applied with zero fuzz (T15).
- RBW-USBHCD splice: applies (9 marker occurrences).

## Evidence log
| Date | Run | Change | Verdict | Moves |
|---|---|---|---|---|
| 2026-10-17 | staging+series apply, `~/.cache/rbw-vendor` | n/a | 1 fuzz (0009 h4), reviewed | series is compatible with staging 11.18 |
| 2026-10-17 | container build (archlinux:base-devel, mingw-w64-gcc, -j12) | runtime | built; 13/13 markers in the INSTALLED tree; **607 MB**; ldd check false-positive on Wine's own ntdll.so/win32u.so (fixed) | runtime builds |
| 2026-10-17 | `rbw-runtime-check` on this host; fake runtime naming libgnutls.so.99 | n/a | 0 problems; negative case reports "HTTPS, so signing in fails", exit 1 | check can fail |
| 2026-10-17 | `--check` then `--setup`, rb7 reflink copy | override cleanup | 5 stale native overrides found (incl. 11.15 cfgmgr32/winmm), all removed; system32 builtins restored | prefix drift cleaned |
| 2026-10-17 | 20261017T1443-runtime-rb7copy | runtime + builtins | window-ok, full UI; verifyloaded all PATCHED from the runtime, 0 maps from /usr/lib/wine; wineusb+winebus RUNNING | **rekordbox runs on the vendored runtime** |
| 2026-10-17 | 20261017T1446-runtime-rb7copy-lsass | lsass.exe (T20) | window-ok; repaints in-session | T20 fix |
| 2026-10-17 | makepkg in clean archlinux:base-devel, git+file of c006311 | packaging | first attempt: PKGBUILD failed to source (apostrophe in an optdepend, fixed 1320fb3). Second: build, check(), package all green; `rekordbox-wine-git-0.3.0.r291.gc006311-1`, **133 MB** compressed; verify-tree green on the extracted package; every depend already satisfied on the user's machine | package is real |
| 2026-10-17 | 20261017T1707-pkg-installed-rb7 | old package AND system wine-staging/mono/gecko removed; 0.3.0 installed; --setup on rb7 | window-ok, full UI; verifyloaded all PATCHED, 0 maps from /usr/lib/wine; wineusb RUNNING; pacman hook silent | **the package stands alone** |

## Open
- The DDJ-400 on the runtime: not connected during these runs. **This is the
  acceptance test and it is not yet done.**
- Build time in CI (4-core runner), measured.
- rekordbox on the runtime: window, audio, controller. The switch from native
  overrides to builtins for dxgi/mmdevapi/setupapi is a second variable on top
  of the runtime swap. If anything regresses, bisect those two first.
- Distro-specific: the deb and rpm runtime dependency lists are written, not yet
  measured in CI.
