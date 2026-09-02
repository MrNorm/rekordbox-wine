# T14 — A Wine upgrade silently produces a mixed-ABI install

**Status: RESOLVED 2026-09-02.** Root cause proven, both defects fixed, the
series rebased onto 11.16, and rekordbox verified running again.
Reported by the user as *"my rekordbox instance no longer opens from the
launcher"*, on a machine where it demonstrably worked on 2026-08-20.

## Symptom

Clicking the menu entry starts nothing usable. No dialog, no error the user can
read. `rekordbox-wine` prints three red FAIL lines and then **launches anyway**.

## The trigger, dated

    /var/log/pacman.log:2928
    [2026-08-27T10:06:00+0100] [ALPM] upgraded wine-staging (11.15-1 -> 11.16-1)
    [2026-08-27T10:06:01+0100] [ALPM] upgraded wine-mono  (11.2.0-1 -> 11.3.0-1)

`upstream/patches/supported-wine.txt` lists **11.15** and nothing else. Every
patched binary on this machine was built against 11.15.

## What actually breaks — measured

Launch log (`WINEDEBUG=err+all,warn+module`, prefix `prefixes/rb7`, 2026-09-02):

    0044:err:wgl:X11DRV_OpenGLInit version mismatch, opengl32 wants 39 but driver has 38
    0144:warn:module:load_dll Failed to load module L"SETUPAPI.dll"; status=c0000135
    0144:err:module:import_dll Library SETUPAPI.dll ... not found
    0134:err:msi:execute_script Execution of script 0 halted; action L"INSTALLFAKEDLLS" returned 1627
    0134:err:mscoree:install_wine_mono MsiInstallProduct failed, err=1627

1. **No OpenGL.** 11.16's `opengl32` negotiates driver interface **39**; our
   `winex11.so` is the 11.15 build and answers **38**. A JUCE/D3D application
   with no GL is an application that does not open. This single line is the
   whole user-visible failure.
2. **The `native` DllOverrides now point at unloadable files.** The prefix
   forces `dxgi`, `mmdevapi`, `setupapi` to `native`, and the native copies in
   `system32` are the 11.15 PE builds. 11.16 cannot load them
   (`c0000135`), which additionally killed wine-mono 11.3.0's post-upgrade
   install.

## Root cause — two defects, both of the "reports success while wrong" family

### D1. The private-tree version stamp is a lie

`bin/make-private-wine.sh` ends with

    echo "$WINE_VER" > "$TREE/.wine-version"

`$WINE_VER` is the **system** Wine version. The patched binaries it just
installed came from `$SRCDIR` (`winedll/`), which carries **no version
information at all** — unlike the PE artifacts, which are version-stamped in
the filename (`dxgi-patched-native-11.15.dll`).

So on 2026-09-02T14:08 the launcher saw `11.15 != 11.16`, "rebuilt" the tree,
copied 11.15 binaries into an 11.16 tree, and stamped it `11.16`. Afterwards
`--check` reported:

    ok    private Wine tree matches system wine 11.16 — system Wine untouched
    ok    winealsa.so patched in the private tree: RBW-DIAG RBW-EVENT ...

Both lines are true and both are useless. The version check compared the stamp
against itself, and the marker greps prove *provenance*, not *ABI*. The tree
was mixed-ABI and every instrument said healthy.

### D2. `FAIL` is advisory in launch mode

`bad()` sets `FAIL=1`. Only `--check` and `--setup` return it. The launch path
falls through to `exec` regardless, so the three correct FAIL lines — the ones
that named the exact problem — scrolled past into a window that never appeared.

A launcher whose entire stated design rule is *"every step must be verifiable"*
verified the steps, found them broken, and started anyway.

## Why the 2026-08-20 verification did not catch it

Every test that session ran against **the Wine that was installed at the time**.
Nothing ever ran the tree against a *different* Wine, because that requires
either a Wine upgrade or a deliberate downgrade. The failure mode needs a
version skew, and a same-day test cannot produce one. Same shape as the
prefix-discarding bug in 389ee04: the test environment could not express the
variable that mattered.

## Fixes

- **F1 (D1):** `build-patched-dlls.sh` stamps `winedll/.built-for-wine` with the
  version it compiled against; `make-private-wine.sh` refuses to build a tree
  whose patched binaries were built for a different Wine, and records both
  versions in the tree. `RBW_ALLOW_UNTESTED_WINE=1` overrides, as elsewhere.
- **F2 (D2):** a new `fatal()` for conditions that make the launch pointless.
  Launch mode stops with an explanation and the exact rebuild command.
- **F3 (structural):** CI builds the package against whatever Wine Arch ships
  today, so a Wine bump surfaces as a red pipeline rather than as a user whose
  DJ software stopped opening. See `.github/workflows/`.

## Reversal / recovery on this machine

Either rebuild the series against 11.16 (and add it to `supported-wine.txt`
with evidence), or pin Wine:

    # /etc/pacman.conf
    IgnorePkg = wine-staging

## The rebase onto 11.16 — what it actually took

Three upstream renames, every one of them touching our patches only as
**context**. No patch body changed, so no fix had to be rethought:

| patch | context line that moved |
|---|---|
| 0007 | `device->serial` → `device->disk_serial` |
| 0009 | `harddisk_driver` → `disk_driver` |
| 0009 | `set_volume_info( … const char *device,` → `const char *unix_device,` |

**A dead end worth recording, because it looks obviously right.** The first
attempt trimmed each hunk's trailing context away, on the reasoning that these
are pure insertions and would then apply to 11.15 *and* 11.16. GNU patch cannot
do it: a hunk with no trailing context fails to place, at any offset. Reduced to
seven lines and confirmed —

    printf 'a\nb\nc\nd\ne\nf\ng\n' > f.txt
    printf -- '--- a/f.txt\n+++ b/f.txt\n@@ -2,3 +2,4 @@\n b\n c\n d\n+NEW\n' | patch -p1 --dry-run
    → Hunk #1 FAILED at 2.

So the series targets one Wine at a time, which is now stated in
`supported-wine.txt` rather than implied. Verified, not assumed: the rebased
series **does not** apply to 11.15 (0007 hunk 1, 0009 hunks 1 and 3 fail against
a pristine 11.15 tree). 11.15 users want commit `9ae9739` or earlier.

## Verified after the fix — 2026-09-02

- **Builds.** All eight components against pristine 11.16, 9/9 markers.
- **Runs.** rekordbox 7.2.18 launches: full UI, 187-track library, both decks,
  artwork and waveform previews, PAD/MIDI indicators.
- **The libraries are ours.** `bin/verifyloaded.sh` on pid 185106: loader is the
  private tree's `wine-preloader`; `winealsa.so` and `winex11.so` both PATCHED
  and both resolved inside the private tree. Nothing stock was mapped.
- **It repaints.** The clock region of the main window differs over 65 s
  (`compare -metric AE` → 16.5 differing pixels). That is past the T01
  one-frame freeze, which is the whole point of the project.
- **The launcher refuses correctly.** Before the rebuild it named all four
  causes and did not start. Verified by running it.

Not re-measured on 11.16 and therefore **not claimed**: audio, USB export, the
DDJ-400. Those need the hardware.

## Still open

- `opengl32` interface 38→39 is an internal Wine ABI that changes without
  notice. Any `winex11` patch is version-locked by construction. That is a
  permanent property of this project, not a one-off — which is why the fix for
  this theme is a *pipeline*, not a patch.
- Re-run the audio, export and controller measurements on 11.16 before
  `supported-wine.txt` can claim more than "it launches and repaints".
