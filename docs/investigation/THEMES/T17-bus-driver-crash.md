# T17 — winebus/wineusb host process crashed in a menu launch; controller not found

**Status:** OPEN (not reproduced; instrumented) · **Opened:** 2026-10-08

## Symptom
After the T16 reboot (kernel 7.2.7, DDJ-400 sequencer client 24 present), the
user launched from the menu: *"I restarted and nada"*. rekordbox 7.2.18 ran
on prefixes/rb7, and verifyloaded was green for winealsa/winex11.

## Evidence (2026-10-08)
- Only ONE `winedevice.exe` (mountmgr). Neither winebus.sys nor wineusb.sys mapped anywhere.
- `wine sc query wineusb` and `sc query winebus` both returned `STOPPED, WIN32_EXIT_CODE 1067`
  (ERROR_PROCESS_ABORTED), so the process hosting both drivers **crashed**.
  mountmgr was RUNNING.
- Without wineusb there is no `\\.\HCDn`, rekordbox's USB validation fails
  and it never opens the MIDI port (T05). That matches the symptom.

## Reproduction attempts, all one variable each — none crashed
| probe | result |
|---|---|
| fresh prefix, private 11.18 tree, DDJ connected | wineusb RUNNING, `RBW-USBHCD: exposed 1 host controller(s)` |
| fresh prefix + rb7's system/user/userdef.reg + patched setupapi/dxgi/mmdevapi | RUNNING |
| same + rb7's stale native `cfgmgr32.dll` (RBW-CFGMGR) and `winmm.dll`, both built 2026-08-19 for 11.15 and forced native by rb7's DllOverrides | RUNNING. **Stale DLLs refuted as a startup crash cause** |
| rb7 itself, relaunched via the installed launcher with `WINEDEBUG=+timestamp,+wineusb,+seh,err+all,+loaddll` | two winedevice, wineusb RUNNING, rekordbox queried HCD0 root hub, and `aconnect`: DDJ-400 24:0 → `WINE midi driver` 128:1 (pid of rekordbox.exe). **Controller port opened** |

## Hypotheses
| # | Hypothesis | Status |
|---|---|---|
| 1 | Stale 11.15 native cfgmgr32/winmm crash the bus driver | refuted at startup (graft probe). Still a latent hazard: rb7 runs two 11.15 PE builds on 11.18 |
| 2 | Race between bus-driver start and controller/USB state at first launch after boot | open, matches T05's race history |
| 3 | Crash triggered by a later event (hotplug, rekordbox IOCTL) in that session | open |

## Instrumentation added
The launcher now logs every terminal-less launch to
`~/.local/state/rekordbox-wine/launch.log` (previous one kept as `launch.log.1`).
Wine's crash reports print even under `WINEDEBUG=-all`, so the next occurrence
leaves evidence. **If it recurs:** `wine sc query wineusb` to confirm exit 1067,
then read launch.log for `Unhandled` / `page fault`.

## To do
- Launcher should flag native DllOverrides it does not manage (cfgmgr32, winmm
  in rb7). Nothing removes them since they left the series.

## 2026-10-17 — T19 changes the ground under this
The launcher now removes the stale native cfgmgr32/winmm overrides (and dxgi,
mmdevapi, setupapi) and runs everything on the vendored runtime. Hypothesis 1's
"latent hazard" is gone once the 0.3.0 package has run once on rb7. If the crash
recurs on 0.3.0, it is not those DLLs. Also see T20: rb7 has lacked lsass.exe
since the 11.18 update, so every LSA call failed. That is not linked to the
crash, but it was a live defect in the same session.
