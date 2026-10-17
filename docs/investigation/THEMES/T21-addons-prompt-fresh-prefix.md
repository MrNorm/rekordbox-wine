# T21 — Without system Wine, every new prefix stops on a Wine Mono download prompt

**Status:** FIXED, measured (2026-10-17) · **Opened:** 2026-10-17

## Symptom
The user removed the old package and the system Wine (`wine-staging`,
`wine-mono`, `wine-gecko`, `winetricks`) before installing 0.3.0, so that the
vendored runtime (T19) was tested on its own. A brand-new prefix, created by the
runtime with an empty `XDG_CACHE_HOME`, stopped on a **"Wine Mono Installer:
Wine could not find a wine-mono package ... Install / Cancel"** dialog. A new
user would meet this on their very first `rekordbox-wine --install`.

## Why it never showed before
- The distro's `wine-mono`/`wine-gecko` put the MSIs in `/usr/share/wine/`,
  which Wine searches as a fallback (`dlls/appwiz.cpl/addons.c:318`). They
  cannot stay installed without the distro's Wine: they depend on it.
- With system Wine gone, a fresh prefix with the user's normal cache did NOT
  prompt: `~/.cache/wine/wine-mono-11.3.0-x86.msi` had been downloaded on
  2026-10-07. That masks the defect on this machine.

## Fix
Ship the exact addon versions this Wine asks for inside the runtime, at
`$RUNTIME/share/wine/{mono,gecko}` (Wine's first search location,
INSTALL_DATADIR). Pinned in `upstream/wine-runtime.conf`; the sha256s are the
ones Wine itself checks a download against (`addons.c` GECKO_SHA/MONO_SHA), and
the build refuses to continue if the Wine source asks for a different version.
`packaging/verify-tree.sh` requires all three files. Cost: +~190 MB of MSIs
(already compressed).

## Evidence log
| Date | Run | Change | Verdict | Moves |
|---|---|---|---|---|
| 2026-10-17 | fresh prefix, runtime, user's cache | system Wine removed | no prompt; mono from ~/.cache/wine | masked |
| 2026-10-17 | fresh prefix, runtime, empty XDG_CACHE_HOME | system Wine removed | "Wine Mono Installer" dialog (T21-mono-prompt.png) | **defect found** |
| 2026-10-17 | fresh prefix, empty XDG_CACHE_HOME, installed 0.3.0.r295 (MSIs in the runtime) | addons shipped | wineboot -i completes, **no dialog**, mono-2.0 installed, nothing downloaded to the cache | **fixed** |
| 2026-10-17 | same prefix, `wine iexplore about:blank` | none | Gecko 2.47.4 installed on demand into system32/gecko, no dialog | Gecko path works too |

Package size with the addons: 325 MB compressed (was 133 MB).
