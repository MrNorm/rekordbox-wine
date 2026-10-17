# T18 — Investigation probes changed the user's desktop and devices

**Status:** OPEN (damage repaired; rules below are mandatory) · **Opened:** 2026-10-08

User, 2026-10-08: *"You made my keyboard stop working … the menu launches no
longer work … you seem to break 4 other things when fixing 1."*

## What the harness broke, measured

### 1. The working menu entry was deleted (proven, repaired)
`~/.local/share/applications/wine/Programs/rekordbox/rekordbox 7.2.18/` was
emptied at **18:24**. That is the T17 graft probe: a throwaway prefix booted
with a COPY of `rb7`'s system.reg/user.reg. Those carry winemenubuilder's
records of the menu files it owns. The probe's drive_c had no matching `.lnk`,
so winemenubuilder removed "its" entries: the user's real ones.
It also rewrote six `wine-extension-*.desktop` file associations (already dead,
pointing at an earlier session's /tmp prefix).
**Repaired:** entry rewritten (`Exec=env RBW_PREFIX=".../prefixes/rb7" rekordbox-wine`)
and verified by launching it with `kioclient exec`: rb7, no FAIL, wineusb RUNNING,
DDJ-400 24:0 → WINE midi driver. The six dead associations were removed
(copies in home snapshot 498). MIME packages and icons matched snapshot 498.
Probe prefixes deleted.

### 2. The package's menu item launched an empty prefix (proven, fixed in source)
"rekordbox (Wine)" = bare `rekordbox-wine` → default prefix → `rekordbox.exe not found`,
with no visible feedback. Launcher now remembers the last prefix it launched
from (`~/.config/rekordbox-wine/prefix`) and uses it only when the default
prefix has no rekordbox. The not-found path now notifies the desktop.

### 3. The launch log I added destroyed its own evidence (proven, fixed in source)
It rotated one `launch.log` on ANY terminal-less run, so two scripted `--check`s
unlinked a running session's log. Recovered via `/proc/<pid>/fd/2`. Now
launches only, one timestamped file each, newest 5 kept.

### 4. Keyboard stopped working (NOT diagnosed)
User had to change the KDE keyboard model (now `Model=thinkpad60` in kxkbrc,
saved 18:43) to get it working. `kxkbrc` did not exist in any home snapshot
13:00–18:08: no config was written by the harness. Runtime events in the window:
- 18:29:10 `sudo pacman -U` of the package ran `35-systemd-udev-reload.hook`.
  logind re-registered every input device, including event3 (AT keyboard).
- 18:34–18:39 suspend/resume.
Unknown: which one, whether it was system-wide or only in rekordbox (Xwayland),
and which keyboard. **Do not reinstall the package or trigger udev on this
machine without the user's go-ahead** until this is understood.

## Rules from here
- A probe prefix must run with `WINEDLLOVERRIDES=winemenubuilder.exe=d`, and
  never with another prefix's registry unless that is set.
- Never `pkill -f` / `pgrep -f` a pattern that appears in the same command line
  (self-match killed or hung 5 commands this session). Use `pgrep -x <name>`.
- Verify a user-facing path the way the user uses it (menu = `kioclient exec`
  on the .desktop file), not by calling the launcher directly.

## 2026-10-17 — menu builder disabled
From 0.3.0 the launcher, bin/rekordbox and every probe run export
`WINEDLLOVERRIDES=winemenubuilder.exe=d`. Measured in 20261017T1443:
`wineboot: Error running cmd winemenubuilder.exe -a -r (126)`, which means it
was refused. A probe run can no longer delete or rewrite the user's menu
entries. The keyboard failure is still undiagnosed; the user has not yet
answered the three questions.
