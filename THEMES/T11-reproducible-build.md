# T11 — Can the package be rebuilt from the patch series alone?

**Opened 2026-08-19.** Every measurement in this project was made against Wine
libraries built in one long-lived working tree, `~/.cache/rbw-wine-build/wine-11.15`,
which has been edited by hand for a week. The AUR package instead builds from a
pristine Wine tarball plus `upstream/0001..0009`. Those are two different
artefacts, and nothing had ever checked that they behave the same.

The question is narrow and it is the one that decides whether the package is
publishable: **does a build from the patch series alone lose any fix?**

## Verdict — NO FIX IS LOST

Proven twice over, on 2026-08-19/20:

| check | result |
|---|---|
| every touched file reconstructs from the series | 6 of 8 byte-identical; 2 differ, and **both differences are debug-only** |
| every functional marker present in a clean build | 9 of 9 |
| every debug marker absent from a clean build | 4 of 4 absent — `RBW-PERIODS`, `RBW-FORCESHARED`, `RBW-SEC`, `RBW-GAP` |
| behaviour with the clean-built libraries installed | **1.000x, 0 teardowns** — `runs/SOAK/deckclock`, 120 s, PC MASTER OUT on |

## The reconstruction diff

Extracted `wine-11.15` pristine, applied `0001..0009`, and diffed every touched
file against the working tree:

| file | result |
|---|---|
| `dlls/dxgi/output.c` | identical |
| `dlls/winealsa.drv/alsamidi.c` | identical |
| `dlls/winex11.drv/window.c` | identical |
| `dlls/mountmgr.sys/dbus.c` | identical |
| `dlls/mountmgr.sys/device.c` | identical |
| `dlls/setupapi/devinst.c` | identical |
| `dlls/mmdevapi/client.c` | **differs, 355 lines** |
| `dlls/winealsa.drv/alsa.c` | **differs, 105 lines** |

Both divergences were read line by line, and both are instrumentation:

- **mmdevapi** — the `rbw_periods()` helper reading `RBW_EXCL_PERIODS` /
  `RBW_SHARED_PERIODS`, and `RBW_FORCE_SHARED`, which serves an EXCLUSIVE
  `Initialize` as SHARED. The env knobs **default to 4 and 3, which is exactly
  what `0002` hardcodes**, so the shipping behaviour is identical with them
  compiled out. These existed to bisect the buffer-widening defect and have no
  business in a package.
- **winealsa** — `rbw_now()`, `rbw_tick()` and the per-second `RBW-SEC` /
  `RBW-GAP` counters (`clock_gettime`, pad-poll min/max, tries/fails, max gap).
  Counters and `ERR()` logging only; no control flow depends on them.

Crucially the *functional* markers are present in **both**: `RBW-EVENT`,
`RBW-EVENT3`, `RBW-DIAG`, `RBW-RAWFMT`, `RBW-WD`, and the `0004` rawmidi path.

**So the series is complete, and the working tree is the series plus debug
code.** That is the healthy direction for this to have come out. It is worth
stating the alternative that was being tested for: had a fix existed only in the
working tree, every published patch would have been subtly wrong and nobody
would have found out until a user built from the AUR.

## Three ways the build lied about succeeding

Each of these produced a **wrong package with exit status 0** and is now guarded
in `bin/build-patched-dlls.sh`.

1. **Everything skipped, "success" reported.** `want()` tested `$#` inside a
   function — which is the *function's* argument count, not the script's — so
   "no arguments means build everything" evaluated as "build nothing". The run
   printed `built and verified:` with an empty list and exited 0. An empty build
   is now a hard failure.
2. **A component silently dropped by configure.** Wine's `configure` does not
   fail on a missing `libx11` or `libasound`; it notes it and drops the driver.
   The package would install, and menus or audio would behave exactly as
   unpatched. Configure output is now checked for both drivers.
3. **A seeded import library in the wrong place.** Import libraries are seeded
   from the installed Wine so a seven-component build does not become a
   whole-Wine build. The seeding derived `dlls/<name>/` from `lib<name>.a` —
   which is wrong for `libntoskrnl.a`, whose directory is `dlls/ntoskrnl.exe/`.
   Invisible until `mountmgr.sys`, the one component that links it, failed.
   Destinations are now read from the Makefile instead of guessed.

### And the timestamp trap underneath them

`tools/winebuild` is a prerequisite of **every** import library. Building it —
which the run must do — makes all 246 seeded libraries look stale at once, so
make regenerates them, which needs `dlltool` from `mingw-w64-binutils`.

`winebuild --without-dlltool` looks like the answer and **is a trap**: it builds
dxgi, mmdevapi and setupapi perfectly and then emits `.rva` directives that
clang's integrated assembler rejects for `ntoskrnl`. A workaround that fails on
one component out of seven, late, is worse than no workaround.

The fix is ordering: build `winebuild` first, seed, then stamp the seeded
libraries a day ahead — a plain `touch` is not enough, because some import
libraries additionally depend on object files compiled *during* the build. The
package therefore needs neither `mingw-w64-binutils` nor `llvm`.

## The launcher was demanding deleted artefacts

`bin/rekordbox-wine` still installed and verified `cfgmgr32` and `winmm`, both
removed from the series **on 2026-08-17 with evidence** (`RBW-CFGMGR` appears in
no run log; the winmm work was measured unnecessary once the HCD driver landed).
Nothing builds them any more, so a correctly installed system was being reported
as broken. It also never checked `winex11.so`, `mountmgr.so` or `mountmgr.sys` —
three of the four system-owned files, covering the File menu and USB export
entirely. Both fixed.

`bin/install-system-wine-patches.sh` knew only about `winealsa.so` and now
handles all four, each with its own backup and its own `--revert`.

## A real `makepkg` run — 2026-08-20

`makepkg -f --nodeps --skipinteg` against a tarball of the tree, building into
`$srcdir` rather than the developer's cache. Result:
**`rekordbox-wine-0.2.0-1-x86_64.pkg.tar.zst`**, and every marker verified in
the *packaged* files — which is a different claim from verifying them in
`artifacts/`, and is the only version a user ever sees.

Three things it caught that nothing else would have:

1. **Wine cannot be built with LTO.** makepkg's default `-flto=auto` drops the
   symbols ntdll's hand-written syscall dispatcher references from assembly:
   `undefined reference to init_syscall_frame`. Fixed with
   `options=('!lto' '!strip' '!debug')`, as Arch's own wine package does.
2. **`build()` must not use the developer's cache.** `build-patched-dlls.sh`
   defaults to `~/.cache/rbw-wine-build`, which holds a tree that already has
   the series applied *plus* whatever diagnostic code was being measured that
   week. A package built there would have silently shipped the debug
   instrumentation this theme exists to keep out. `build()` now exports
   `RBW_WINE_BUILD="$srcdir/wine-build"`.
3. **`install-system-wine-patches.sh` looked in the wrong directory.** It
   resolved its sources to `<prefix>/artifacts/winedll`, the layout of the
   *source tree*; the package installs them to `<prefix>/winedll`. So the one
   command a user must run as root would have failed on every real
   installation, while working perfectly in development — the exact shape of
   bug that only a packaged artefact can reveal. It now tries both.

Remaining warning, not fixed: `Package contains reference to $srcdir` on the
four PE builtins. That is the build path in their DWARF, harmless at runtime,
and it is a `-ffile-prefix-map` away if it ever needs to be clean.

## The verification missed a component — 2026-08-20

**Correction to this theme's own verdict.** "No fix is lost" was established for
the `0001..0009` patch series, and that result stands. But the package needs an
**eighth** component that is not in the series and was therefore never checked:

`wineusb.sys` / `wineusb.so`, built by `bin/build-wineusb-hcd.sh` from the
source splice `upstream/rbw-usbhcd.c`. It exposes `\\.\HCDn`. Without it,
rekordbox identifies the Pioneer controller over HID, builds the right
per-model object, then validates it by walking the USB bus the way `usbview.exe`
does — ten `CreateFileW` on `HCD0..9`, ten `STATUS_OBJECT_NAME_NOT_FOUND` — and
on that failure **destroys the device object it has just built and never opens
the controller's MIDI port** (`runs/20260813T163916-hidopen/wine.log`).

`PATH-TO-GOLD.md` step 3c already called it *mandatory for the controller*. It
was nonetheless absent from `bin/build-patched-dlls.sh`, from the PKGBUILD's
`build()`, `check()` and `package()`, and from the launcher's checks. **A user
installing the AUR package would have had no DDJ-400 support at all** — the
hardware that is this project's acceptance test.

The lesson generalises past this one file: the completeness check was scoped to
*the patch series* when the thing that needed checking was *the component list*.
A fix that arrives by a different mechanism — a source splice rather than a
patch — sits outside a series-shaped audit and is invisible to it.

Now built by `bin/build-patched-dlls.sh` as an eighth component, verified by
marker `RBW-USBHCD` in **both** halves, shipped by the package along with
`build-wineusb-hcd.sh`, `install-wineusb-hcd.sh` and `rbw-usbhcd.c`, and checked
by the launcher on every start. Both halves are checked because they must match:
`wineusb.so` gains a unixlib entry point that `wineusb.sys` is the only caller
of, so installing one without the other is worse than installing neither.

## Clean-room install, end to end — 2026-08-20

The package was installed with `pacman -U` and the **entire recipe run from the
installed copy**, touching nothing in the source tree:

| step | result |
|---|---|
| `pacman -U rekordbox-wine-0.2.0-1-x86_64.pkg.tar.zst` | 67 files installed |
| `rekordbox-wine --setup` into an empty path | prefix created; three patched builtins installed and overridden; **all six system libraries verified** including both wineusb halves |
| `rekordbox-wine --install <installer>.exe` | rekordbox 7.2.17 installed unattended |
| first launch | window mapped in ~5 s and **two screenshots four seconds apart differ** — past the T01 one-frame freeze |
| sign-in | reached the AlphaTheta dialog, which is where the harness stops |

**This closes the "nothing has ever been built from a clean prefix" blocker.**
Every prior result in this project came from one prefix that had survived dozens
of harness runs and several `kill -9`s; the recipe now has a second, from-zero
witness, and the launcher that produced it was the packaged one at
`/usr/bin/rekordbox-wine`, not the working copy.

It is not the *second machine* blocker, which stands. Same kernel, same Wine,
same PipeWire, same everything but the prefix.

### `--install` did not exist

The README and the package's post-install message both told users to run
`rekordbox-wine --install <exe>`. That flag was never implemented — it was
written into the documentation before it was written into the launcher, which is
the same class of error as a marker check that cannot fail. It now exists, and
it deliberately runs *after* the prefix has been prepared: rekordbox's installer
launches the application when it finishes, so on an unprepared prefix the first
thing a new user would see is the one-frame freeze this project exists to fix.

## Open

- The package has still never been installed on a **second machine**, and no
  prefix has ever been built from scratch. T11 answers "does the series
  reproduce the libraries", not "does the recipe reproduce the prefix".

## Related

`PACKAGE.md` for what the package installs, [[T00-instrument]] for why a
measurement that cannot fail is worse than no measurement, and [[T10]] for the
debug instrumentation this theme is about *removing*.
