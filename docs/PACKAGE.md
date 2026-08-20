# What the package must install, and why — 2026-08-17, current as of 2026-08-20

This replaces the scattered patch list that had accumulated in `docs/PATH-TO-GOLD.md`
and `docs/investigation/STATE.md`. It is the authoritative set. Every entry here is **verified
loaded and load-bearing**; anything that could be removed without breaking a
measured behaviour has been removed.

## The Wine patch series — `upstream/patches/0001..0009`, plus the `wineusb` splice

`0005-winex11-popup-not-managed.patch` was added 2026-08-19: `winex11.drv`'s
`is_window_managed()` handed `WS_POPUP | WS_SYSMENU` windows to the window
manager, so KWin repositioned JUCE's off-screen drop shadows and JUCE dismissed
the menu 11 ms after mapping it. Without it the **File menu** and the
**view-mode selector** never open, and EXPORT mode — hence USB export — is
unreachable. It builds as `make dlls/winex11.drv/winex11.so` and installs
system-wide alongside `winealsa.so`; verify with
`strings /usr/lib/wine/x86_64-unix/winex11.so | grep -c RBW-POPUP` (expect 1).


Regenerated 2026-08-17 against pristine wine-11.15. **All four apply cleanly to
a stock tree with no fuzz, and applying them reproduces the built sources
byte-for-byte** (verified by md5 against the build tree). The previous series
did neither: 0002 and 0003 were corrupt diffs that `patch` and `git apply` both
refused, 0004 was not a patch file at all, and six of the ten markers in the
installed binary existed in no patch.

| patch | file | why it is needed |
|---|---|---|
| `0001-dxgi-implement-WaitForVBlank` | `dlls/dxgi/output.c` | the stub returns `E_NOTIMPL`, so a vblank-driven toolkit never repaints. Without it rekordbox paints one frame and freezes. |
| `0002-mmdevapi-exclusive-event-streams` | `dlls/mmdevapi/client.c` | event-driven exclusive mode was refused outright, and the buffer was not usable a period at a time. Without it the sample-rate list is empty and playback does not sustain. |
| `0003-winealsa-exclusive-audio` | `dlls/winealsa.drv/alsa.c` | signal the client event only when a period is free; validate exclusive formats against the raw hardware rather than the plug layer. |
| `0004-winealsa-midi` | `dlls/winealsa.drv/alsamidi.c` | port naming, subscribable-only enumeration, and **rawmidi output** — the fix for the SysEx split that hangs the DDJ-400. |

Plus the user-mode USB host controller driver, which is not a diff but a spliced
source file: `upstream/patches/rbw-usbhcd.c`, applied by `bin/build-wineusb-hcd.sh`.
rekordbox validates the controller by walking `\\.\HCD0..9`; Wine has no such
device and without it the controller is never recognised as Pioneer hardware.

## Prefix configuration — exactly two overrides

    wine reg add 'HKCU\Software\Wine\DllOverrides' /v dxgi     /d native /f
    wine reg add 'HKCU\Software\Wine\DllOverrides' /v mmdevapi /d native /f
    wine reg add 'HKCU\Software\Wine\Drivers'      /v Audio    /d alsa   /f

The ALSA driver is mandatory: Wine's PulseAudio driver implements no exclusive
mode at all, so every rate probe fails and the device list is empty.

## Removed 2026-08-17, with the evidence

| removed | why |
|---|---|
| `cfgmgr32` patch and its native DLL | **never loaded.** `RBW-CFGMGR` appears in no run log; Wine takes builtins from its own directory. The device-tree work it did was superseded by the HCD driver. |
| patched `d2d1.dll` in the prefix | never loaded, same mechanism. rekordbox is JUCE 7.0.9 and has no Direct2D renderer, so it was aimed at a DLL off the frame path. |
| native `winmm.dll` + the `DRV_QUERYDEVICEINTERFACE` patch | **measured unnecessary.** The interface-path table in rekordbox.exe contains no `pid_0026`, stock `lolvldrv.c` already routes both interface queries, and the handshake completes 3 of 3 with the override deleted and the driver half removed. |
| the MIDI port-rename workaround | obsolete. It forced the controller onto the generic path, which was the only way to get MIDI flowing before the auth worked. The native path now works and the generic path cannot drive the jog wheels. |
| the `RBW-WIRE` / `RBW-RAW` hex probes | debug-only, and both truncated (64 bytes out, 32 in with no marker) which actively misled the investigation. Superseded by `research/probes/usbwire.sh`, which reads the USB wire and is external to the shipped code. |

## How to verify an install

    strings /usr/lib/wine/x86_64-unix/winealsa.so | grep -c 'sending directly to'   # 1 = rawmidi fix present
    strings /usr/lib/wine/x86_64-windows/wineusb.sys | grep -c RBW-USBHCD           # 1 = HCD driver present
    wine upstream/miditest.exe        # must list exactly one MIDI IN and one OUT, named DDJ-400
    wine upstream/hcdtest.exe         # must report the Pioneer with its real bcdDevice
    ./research/probes/authprobe.sh --runs 3       # must report "@AuthEnd RECEIVED" every time

## rekordbox settings the package must set — added 2026-08-19

Two values in `rekordbox3.settings`, with the application **stopped** (it
rewrites the file every ~15 s):

| setting | value | why |
|---|---|---|
| `WasapiPolling` | `1` | Without it PC MASTER OUT runs at **0.05x** of real time and both audio streams are torn down and rebuilt every 15.9 s. `docs/investigation/THEMES/T10` phases 34-38. |
| `AudioBufferSize` | `512` (floor) | At 256 a teardown still arrives about once every three minutes, because no rekordbox thread gets real-time priority under Wine. `docs/investigation/THEMES/T10` phases 40-42. |

`bin/rekordbox-wine` applies both under **Audio settings** and reports them under
`--check`. Verify an install with:

    grep -o 'name="\(WasapiPolling\|AudioBufferSize\)" val="[^"]*"' \
      "$WINEPREFIX"/drive_c/users/*/AppData/Roaming/Pioneer/rekordbox6/rekordbox3.settings

    expected:  WasapiPolling = 1     AudioBufferSize = 512 or larger

and prove it plays with `bin/soak.sh 140`, which must report **1.00 of real
time** and **0 teardowns**.

## USB export — added 2026-08-19

Needs, in addition to the audio steps:

| piece | what |
|---|---|
| `upstream/patches/0008-setupapi-physical-device-object-name.patch` | `SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` was a NULL placeholder; without it rekordbox can never match a device to a drive letter. System-wide `setupapi.dll`; verify with `strings … \| grep -c PhysicalDeviceObjectName` (expect 2). |
| `upstream/patches/0006` + `0007` | the drive must report `DRIVE_REMOVABLE`, and the storage descriptor must not claim every device is a fixed SCSI disk. |
| read access to `/dev/sdX1` | otherwise Wine reports a FAT32 stick as NTFS. Ship a udev rule. |
| `upstream/patches/0009-mountmgr-volume-devnodes.patch` | writes the `STORAGE\Volume` devnode from inside `mountmgr.sys`, on every `set_volume_info()`, and removes it on `delete_dos_device()`. Without a devnode, SetupAPI enumerates no volumes at all and rekordbox's USB panel is empty however healthy the mount is — it intersects the SetupAPI volume list with `GetDriveType`. This **retires `research/probes/usbdevnode.sh`**, which wrote the same key from outside keyed on a `\Device\HarddiskN` name that is assigned in plug order and so was per-stick and per-session. |

Verify an export with `bin/pdbcheck.py <stick>/PIONEER/rekordbox/export.pdb`,
which must print **"structurally sound and the exported track is present"**. A
full `rekordcrate` / `crate-digger` parse is still required before real hardware.

## The controller's two halves — added 2026-08-20

`wineusb` is **mandatory for the DDJ-400** and arrives by two different
mechanisms, which is why it went missing from the package for a day:

| half | where it lives | what it does |
|---|---|---|
| `wineusb.sys` (PE driver) | `upstream/patches/rbw-usbhcd.c`, **spliced** into `wineusb.c` by `bin/build-wineusb-hcd.sh` | creates the `\\.\HCDn` device objects and answers the USB hub IOCTLs |
| `wineusb.so` (unix side) | `upstream/patches/0010-wineusb-hcd-unixlib.patch` | reads the kernel's own view of the bus out of `/sys/bus/usb/devices`, so the descriptors an application reads back are the device's real ones |

**Both must be built and installed together** — the unix half gains a unixlib
entry point that the spliced PE half is the only caller of. Verify with
`strings … | grep -c RBW-USBHCD` on each: expect 7 in `wineusb.sys` and 2 in
`wineusb.so`.

Without them, rekordbox identifies the controller over HID, builds the right
per-model object, validates it by walking the USB bus the way `usbview.exe`
does — ten `CreateFileW` on `HCD0..9`, ten `STATUS_OBJECT_NAME_NOT_FOUND` — and
then **destroys the device object it just built and never opens the MIDI port**.

## Building the patched components — added 2026-08-19

`bin/build-patched-dlls.sh` is the whole build. It fetches the Wine source
matching the *installed* Wine, applies `upstream/patches/0001..0009` in order, configures
once, and builds eight components, refusing to finish unless each one carries its
marker string.

Three traps are handled in the script because each one produced a **silently
wrong package** rather than an error:

| trap | what it looks like | why it happens |
|---|---|---|
| a component is skipped | build "succeeds", `artifacts/` is empty, exit status 0 | `$#` inside a shell function is the *function's* argument count, so a "no arguments means build everything" test read as "build nothing" |
| `winex11` or `winealsa` missing | package installs, menus or audio behave exactly as unpatched | Wine's `configure` does **not** fail on a missing `libx11`/`libasound`; it prints a note and drops the driver |
| the build pulls in most of Wine, then stops at `cannot find the 'dlltool' tool` | build fails late | `tools/winebuild` is a prerequisite of **every** import library, so building it makes all 258 seeded ones look stale at once |

The last of those is worth spelling out, because the obvious fix is the wrong
one. The import libraries are seeded from the installed Wine so that a
seven-component build does not become a whole-Wine build. Stamping them current
is not sufficient — `winebuild` is built *during* the run and is newer than the
stamp, and some import libraries (ucrtbase's) additionally depend on object
files that do not exist yet and get compiled mid-build. So: build `winebuild`
first, seed, then stamp the seeded libraries a day ahead of anything the build
can produce.

Regenerating them instead requires `dlltool` from `mingw-w64-binutils`, and
winebuild's `--without-dlltool` fallback is **not** a substitute: it emits `.rva`
directives that clang's integrated assembler rejects for `ntoskrnl`, so it
appears to work — dxgi, mmdevapi and setupapi all build — and then fails on the
one component that needs it. The package therefore needs neither
`mingw-w64-binutils` nor `llvm`.

Install the four system-owned files with
`sudo research/retired/install-system-wine-patches.sh`, which backs up each stock file and
refuses to install anything that does not carry its marker. Undo the lot with
`--revert`.

## makepkg — added 2026-08-20

`options=('!lto' '!strip' '!debug')` is **required**, not tidy-up: makepkg's
default `-flto=auto` drops the symbols ntdll's syscall dispatcher references
from assembly and the build dies with `undefined reference to
init_syscall_frame`.

`build()` must export `RBW_WINE_BUILD="$srcdir/wine-build"`. Left to its default
the build reuses `~/.cache/rbw-wine-build`, a developer tree that carries debug
instrumentation on top of the series — so the package would ship it.

Verified end to end on 2026-08-20: `rekordbox-wine-0.2.0-1-x86_64.pkg.tar.zst`,
all eight functional markers present in the packaged files and both debug
markers absent. See `docs/investigation/THEMES/T11-reproducible-build.md`.

## Co-existence with other Wine installations — added 2026-08-20

**The package no longer modifies the system Wine at all**, and needs no root
beyond what the package manager does for its own files.

Six of the fixes are unix libraries or PE drivers that `DllOverrides` cannot
reach. They used to overwrite files in `/usr/lib/wine`, which are owned by the
distro's `wine` package. Instead, `bin/make-private-wine.sh` builds a private
Wine tree — symlinks into the system Wine plus our six patched files, about
16 MB — and the launcher runs against that.

| | before | after |
|---|---|---|
| files owned by `wine` overwritten | 6 | **0** |
| other Wine apps affected | all of them | **none** |
| survives a `wine` upgrade | no, silently reverted | yes — version recorded, rebuilt automatically |
| root needed by the user | two scripts | **none** |
| uninstall | manual `--revert` | delete one directory |

`install-system-wine-patches.sh` and `install-wineusb-hcd.sh` are **retired and
no longer shipped**.

**Two files in the private tree must be real copies, not symlinks:**
`wine-preloader` and `ntdll.so`. Wine re-derives its tree from the resolved path
of each, so a symlink sends it back to `/usr/lib/wine` — and it does so
silently, with every on-disk marker check still passing. `bin/verifyloaded.sh`
reads `/proc/<pid>/maps` and is the only check that catches it. See
`docs/investigation/THEMES/T13`.

The package still installs three additive system files: the DDJ-400 udev rule
(matches USB `2b73:0026` only), a `modprobe.d` blacklist of `snd_seq_dummy`, and
a `modules-load.d` entry for `ntsync`. The blacklist is the only one with reach
beyond us — anything relying on ALSA's "Midi Through" loopback loses it — and it
is a one-line file the user can delete.

## Menu entries and updates — added 2026-08-20

**Wine's own Start Menu entry is a trap.** rekordbox's installer makes Wine
write entries named "rekordbox 7" whose `Exec` is the system `wine` plus a
`.lnk` path. They bypass the private Wine tree and the prefix DLL overrides, so
they start an unpatched rekordbox: one frame, then a freeze. A user sees two
entries and the obvious one is broken.

`bin/rekordbox-wine` rewrites them to `Exec=rekordbox-wine` on every `--setup`
and launch, marks them with `X-RBW-Rewritten=1`, keeps the original as
`*.desktop.rbw-original`, drops the now-meaningless `Path=`, and skips the
uninstaller entry. `--check` reports without changing anything.

**Detecting "already rewritten" must not look at the `Exec` line.** The original
`Exec` embeds the prefix path, and the default prefix is
`~/.local/share/rekordbox-wine/prefix` — so a naive `Exec=.*rekordbox-wine`
test matches the *path* and every entry looks already-done. Measured: the repair
silently did nothing. Hence the explicit `X-RBW-Rewritten` key.

**Nothing is pinned to a rekordbox version.** Both launchers resolve the newest
`rekordbox.exe` with `find … | sort -V | tail -1`, so an application update is
transparent. `bin/rekordbox` used to hardcode `rekordbox 7.2.18` and would have
kept launching a stale build after any update; fixed.

**Wine upgrades** are handled by the private tree recording its Wine version and
the launcher rebuilding on mismatch. The patch series itself is deliberately
pinned — see `upstream/patches/supported-wine.txt`.
