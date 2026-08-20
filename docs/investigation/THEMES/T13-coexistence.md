# T13 — Not breaking everyone else's Wine

**Opened 2026-08-20**, from a direct question: *how does this co-exist with
other Wine installations? I don't want us breaking other installs because our
fixes break theirs.*

The honest answer at the time was **it doesn't**, and the design was not
shippable.

## What the old design did

Ten fixes, split by how they reach Wine:

| fix | mechanism | blast radius |
|---|---|---|
| `dxgi`, `mmdevapi`, `setupapi` | native DLL in the prefix + `DllOverrides` | **our prefix only** |
| `winealsa.so`, `winex11.so`, `mountmgr.so`, `wineusb.so` | **overwrote `/usr/lib/wine/x86_64-unix/`** | **every Wine app on the machine** |
| `mountmgr.sys`, `wineusb.sys` | **overwrote `/usr/lib/wine/x86_64-windows/`** | **every Wine app on the machine** |

Six files, `pacman -Qo`-owned by `wine-staging`. Three consequences, in
increasing order of seriousness:

1. **File conflict.** A package cannot own a file another package owns, which
   is why the PKGBUILD had to tell the user to run a script by hand.
2. **Silently undone.** Any `wine` upgrade restores the stock files, and
   nothing tells the user their DJ software just lost its fixes.
3. **It changed other people's software.** This is the one that matters.
   Somebody's game, their Photoshop, their accounting package all got our MIDI
   port renaming (`0004`), our window-management change (`0005`), and our
   storage-descriptor rewrite (`0007` — which alters `RemovableMedia` and
   `BusType` for *every* device, not just USB sticks). None of them asked for
   any of it, and if one of those changes is wrong for them, we broke it.

None of that is acceptable in something published to the AUR.

## The fix: a private, relocated Wine tree

Wine resolves its libraries and `share/wine` **relative to the loader binary's
own path**. So `rekordbox-wine` now runs against a parallel tree that carries
our patches, and the distro's Wine is never touched.

The tree is almost entirely **symlinks** into the system Wine — a full copy is
984 MB, which is not a reasonable thing to ship or to duplicate per user:

    16 MB   2430 symlinks   11 real files

The real files are the six patched libraries plus the loader chain.

### The trap: which files must be real

Symlink the wrong thing and the whole mechanism silently reverts to the system
Wine **while every check still passes**. Two files must be real copies:

- **`wine-preloader`** — `wine` execs it, and from that moment Wine derives its
  tree from `/proc/self/exe`. Leave it a symlink and the resolved path is
  `/usr/lib/wine`.
- **`ntdll.so`** — one step further along. The loader `dlopen`s it through our
  symlink, the kernel resolves that to `/usr/lib/wine`, and Wine re-derives its
  tree from the *resolved* path and uses stock libraries for everything after.

**Both failures were measured, not reasoned about.** With `ntdll.so` symlinked,
rekordbox ran with a private tree containing a real, correctly patched
`winex11.so` — and mapped the **stock** one. Every marker check passed
throughout, because they all inspected files on disk.

That is a measurement that cannot fail, which [[T00-instrument]] exists to
catch. The answer is `bin/verifyloaded.sh`, which reads `/proc/<pid>/maps` and
reports what the **running process** actually mapped. Nothing else counts.

## The proof

System Wine reverted to stock (`RBW` markers: 0 in all six files), then both
applications run **at the same time**:

    rekordbox.exe   loader: <private>/lib/wine/x86_64-unix/wine-preloader
      winealsa.so   PATCHED   <private>/...  RBW-DIAG RBW-EVENT3 RBW-PAD RBW-RAWFMT RBW-WD
      winex11.so    PATCHED   <private>/...  RBW-POPUP

    notepad.exe     loader: /usr/lib/wine/x86_64-unix/wine-preloader
      winex11.so    STOCK     /usr/lib/wine/...

Two Wine applications, two different Wine library sets, one machine, neither
affecting the other.

## What this buys the user

- **No root at all.** `install-system-wine-patches.sh` and
  `install-wineusb-hcd.sh` are retired and no longer shipped. The package's own
  files (udev rule, modprobe, modules-load) are installed by the package
  manager; nothing else needs privilege.
- **Wine upgrades stop being destructive.** The tree records the Wine version it
  was built against; the launcher notices a mismatch and rebuilds. Previously an
  upgrade silently reverted every fix.
- **Uninstall is complete.** There is nothing to revert, because nothing outside
  the package's own files was ever changed.

## Residual system-level changes, and why each is defensible

The package still installs three things outside its own tree. All are additive,
none patch another package's files:

| what | why it is not a co-existence problem |
|---|---|
| `60-pioneer-ddj.rules` | matches only USB `2b73:0026`, a Pioneer DDJ-400 |
| `modprobe.d` blacklisting `snd_seq_dummy` | disables an ALSA loopback that shadows real MIDI hardware. **The one with real reach** — anything relying on "Midi Through" loses it. Documented in the package description, and a one-line file the user can delete |
| `modules-load.d` loading `ntsync` | loads an in-kernel sync driver Wine uses. Additive; other Wine apps benefit identically |

`rtkit` is a **recommendation**, not a dependency, and is a stock distro package.

## The harness was left behind — caught by the new tool

Switching to a private tree broke the **measurement harness**, silently.
`bin/arm.sh` launches through `bin/rekordbox`, which called bare `wine` — so
every arm ran on the **system** Wine and therefore on stock libraries. The first
post-change regression produced **21 teardowns in 40 s and no playable track**,
which would have read as "the private tree broke the audio fix".

`bin/verifyloaded.sh` said what it actually was in one line:

    winex11.so   STOCK   /usr/lib/wine/x86_64-unix/winex11.so  (expected RBW-POPUP)
    rekordbox is running on STOCK Wine libraries — the fixes are NOT active.

`bin/rekordbox` now execs the private loader. Re-measured immediately after:

| | before the fix | after |
|---|---|---|
| teardowns in 40 s | **21** | **0** |
| engine rate, 120 s window | (no track would play) | **0.999x** |
| libraries mapped | stock | ours |

Two lessons, both already project doctrine and both re-earned here: a change of
this size has to be verified **functionally**, not just structurally — loading
the right libraries and playing audio are different claims; and the harness is
part of the system under change, not a fixed observer of it.

## Portability: the tree must mirror the system's own layout

Testing the scripts against a Debian-shaped tree — real Wine binaries, moved
into `/usr/lib/x86_64-linux-gnu/wine` — found a bug that would have made the
package **fail on Debian and every derivative**.

Wine resolves its libraries relative to the loader, but *which relative path*
differs by distribution:

| distro | layout |
|---|---|
| Arch | `lib/wine` |
| Debian / Ubuntu | `lib/x86_64-linux-gnu/wine` |
| Fedora | `lib64/wine` |
| WineHQ builds | `/opt/wine-staging/lib/wine` |

`make-private-wine.sh` hardcoded `lib/wine`, so on Debian it would have built a
tree the loader never looks in — and the failure is the silent kind, because
Wine simply falls back to the system tree and runs on stock libraries.

Fixed by deriving the relative path from the system install
(`REL_LIB="${SYS_LIB_ROOT#$SYS_PREFIX/}"`) and reproducing it inside the private
tree. The tree records what it used in `.wine-layout`, and the launcher reads
that file rather than guessing.

`bin/winepaths.sh` gained matching support: it now globs `../lib/*/wine` from
the loader, so a Debian derivative with a different multiarch triplet resolves
without relying on the hardcoded absolute path in the fallback list. Covered by
`bin/test-winepaths.sh` — six cases including Debian and an `aarch64` triplet,
which needs no container and runs anywhere.

**Still not proven:** none of this has run on an actual Debian or Fedora system.
The fixtures use real Wine binaries in the right shape, which tests the script
logic but not the distribution's own Wine build. That remains the second-machine
item.

## Open

- The private tree is per-user under `~/.local/share`. A multi-user machine
  builds one per user, at 16 MB each. Acceptable, but a shared
  `/usr/lib/rekordbox-wine/wine` built at install time would be tidier if the
  Wine version can be pinned reliably.
- `winecfg`/`wineboot` are copied only if they are real files in the loader's
  directory; on distros where they are symlinks the private tree gets symlinks
  to the system copies. Harmless — they are Windows programs launched through
  our loader — but untested off Arch.
