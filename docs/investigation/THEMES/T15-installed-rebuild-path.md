# T15 — The rebuild the launcher prescribes cannot run from an installed package

**Status:** RESOLVED locally 2026-10-07 (CI not yet run on it) · **Opened:** 2026-10-07

## Symptom
Reported by the user as *"Your own command doesn't work"*, on wine-staging
11.18 (Arch upgraded 11.16 → 11.17 on 2026-09-13 and → 11.18 on 2026-09-28,
`/var/log/pacman.log:3627,4081`).

The user's literal command was `BW_ALLOW_UNTESTED_WINE=1 bin/build-patched-dlls.sh`.
The leading `R` was missing, so the script never saw the override and printed
its refusal, identical to the no-override case. The printed hint itself is
spelled correctly. That is a usability defect, not the root cause, but it is
fixed below: a near-miss `*ALLOW_UNTESTED*` variable is now named in the output.

Testing the path a **packaged** user actually takes, which is the command
`rekordbox-wine --check` prints (`/usr/share/rekordbox-wine/bin/build-patched-dlls.sh`),
found that it could never have worked:

1. **No patch series.** The script reads `$ROOT/upstream/patches/0*.patch`.
   `install-tree.sh` shipped the series only to `/usr/share/doc/rekordbox-wine/patches/`.
   Measured: `FAILED 0*.patch — the tree is not in a state this series expects`.
2. **The version gate was skipped without a word.** `supported-wine.txt` was
   missing too, and the check was `[[ -f "$SUPPORTED" ]] && ...`. The installed
   copy ran on untested 11.18 without the warning.
3. **Output into a root-owned directory.** Results went to `$ROOT/artifacts`,
   i.e. `/usr/share/rekordbox-wine/artifacts`. The launcher and README both say
   "no root".
4. **`make-private-wine.sh` bypassed its own ABI gate** when
   `RBW_ALLOW_UNTESTED_WINE=1` was set. A user who exported it for the build,
   and whose build then failed, got exactly the T14 mixed-ABI tree.

Also folded in, the same "marker present, function missing" class:
**GitHub issue #3.** A `winex11.so` built without GL headers has RBW-POPUP and no GLX.
The CI container had no `libglvnd`. Every check passed, and rekordbox died after its splash.

## Root cause
The packaged layout was never exercised for the rebuild. Every rebuild so far
ran in the source checkout, where `$ROOT` is writable and holds `upstream/`.
CI verifies the *built* package and runs the installed launcher's `--check`,
but never the installed *rebuild*. That rebuild is the one step every packaged
user must take after every Wine upgrade.

## Fix
- `install-tree.sh` ships the series + `supported-wine.txt` + `rbw-usbhcd.c` to
  `/usr/share/rekordbox-wine/upstream/patches/` (doc copy kept).
- `build-patched-dlls.sh`: output dir `$ART` = `$RBW_ARTIFACTS`, else
  `$ROOT/artifacts` if writable, else `~/.local/share/rekordbox-wine/artifacts`.
  Missing series or list → hard error. Reports patch **fuzz**; it previously applied
  fuzzed hunks silently, which is the very risk its own warning names.
  `--with-opengl` passed to configure, and the built winex11.so must contain `glX` strings.
  Names a mistyped override.
- `build-wineusb-hcd.sh` honours `RBW_ARTIFACTS`.
- `make-private-wine.sh` picks the first winedll set built for the running Wine,
  in this order: checkout `artifacts/winedll`, user dir, package `winedll`. The ABI gate has no override.
- launcher: PE artifacts looked up in `$DATADIR/artifacts`, then the user dir;
  `make-private-wine.sh` is called without forcing a directory.
- `libglvnd` / `libgl-dev` / `libglvnd-devel` added as build deps (PKGBUILD, debian, spec, CI).

## Evidence log
| Date | Run | Change | Verdict | Moves |
|---|---|---|---|---|
| 2026-10-07 | pristine 11.18 tree, `patch` per hunk | none | 0 fuzz; offsets only in 0007 (27), 0008 (5), 0009 (16–27) | series applies cleanly to 11.18 |
| 2026-10-07 | checkout build, `RBW_ALLOW_UNTESTED_WINE=1 bin/build-patched-dlls.sh` | none | exit 0, 8/8 components, all markers, `.built-for-wine = 11.18`, winex11.so 41 glX | builds on 11.18 |
| 2026-10-07 | installed 0.2.0.r12 `/usr/share/.../build-patched-dlls.sh dxgi` | none | `FAILED 0*.patch`, no version warning | defects 1+2 proven |
| 2026-10-07 | simulated install: /usr/share/rekordbox-wine copied, fixed bin/ + upstream/ overlaid, `chmod -R a-w`; cold cache `~/.cache/rbw-usertest` | T15 fix | exit 0, 8/8 ok, output in `~/.local/share/rekordbox-wine/artifacts/`, no root | installed rebuild works |
| 2026-10-07 | simulated installed launcher, `RBW_PREFIX=prefixes/rb7` | T15 fix | no FAIL; tree rebuilt `.built-for-wine=11.18`; DLLs installed; rekordbox 7.2.18 up; verifyloaded green; user saw UI | launch path works on 11.18 |
| 2026-10-07 | same session | none | user: "No controller detected" | → T16 (kernel, not Wine) |
| 2026-10-07 | CI 37648922489 (build, Arch) | T15 fix pushed | green on Arch's **wine 11.19**, GLX enforced | series builds on 11.19 too |
| 2026-10-07 | CI 37648922432 (packages) | T15 fix pushed | rpm green; **deb FAILED**: `configure: error: EGL 64-bit development files not found` | `--with-opengl` caught it: Debian needs `libegl-dev`, not only `libgl-dev`. Every earlier .deb was presumably built **without OpenGL** (issue #3's defect, invisible to CI). Added libegl-dev |

## Upstream
- [ ] Close GitHub issue #3 once CI builds with libglvnd and the GLX check is green.
