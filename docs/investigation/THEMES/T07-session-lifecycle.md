# T07 — session lifecycle: why the prefix fills up with orphans, and why that is a performance bug

**Opened:** 2026-08-14 · **Status:** ROOT CAUSE FOUND, FIXED IN THE HARNESS AND THE LAUNCHER
**Owner symptom:** *"the UI has become extremely laggy over time"* and *"I see several
rekordbox tray instances in my system tray"* — reported by the user, both explained here.

## The symptom, measured

`runs/CLEANDOWN/20260814T210239-before.txt`, taken with rekordbox NOT running:

| | |
|---|---|
| Wine processes belonging to `prefixes/rb7` | **36** |
| `wineserver` processes | **0** |
| Resident memory held | **3,112 MB** |
| CPU already burned by them | **650 CPU-seconds** |
| `rekordboxAgent` (Electron) processes | **9** |

Three complete leaked sessions, each one a full set:
`services.exe`, `plugplay.exe`, `explorer.exe`, `rpcss.exe`, `svchost.exe`,
two `winedevice.exe`, `powershell.exe`, `conhost.exe`, and a whole
`rekordboxAgent` Electron tree (`CrUtilityMain` + `CrRendererMain` + `CrGpuMain`,
~220 MB each).

The three `winedevice.exe` orphans alone had burned 260 s, 198 s and 180 s of CPU.

`rekordboxAgent` is the process that draws rekordbox's **system-tray icon**, which
is exactly what the user reported seeing three of.

## Root cause: `wineserver -k` kills the server, not the clients

From `man wineserver`:

> `-k` Kill the currently running wineserver … sends a SIGINT first and then a SIGKILL.
> The instance of wineserver that is killed is selected based on the WINEPREFIX
> environment variable.

It says nothing about clients, because it does nothing to them. A Wine client dies
only when it next makes a server call and finds the socket gone. Electron helper
threads and `winedevice.exe` sit in `poll()`/`epoll` on file descriptors that are
*not* the wineserver socket, so they never make that call and never notice. They
survive indefinitely, holding their X windows and their tray icons.

Every teardown path in this repo did the same two things and neither of them is
a cleandown:

| path | kills | leaves alive |
|---|---|---|
| `bin/rbw` cmd_run (`:437-454`) | `$wpid` then `wineserver -k` | the whole Agent tree, and `$wpid` is the *subshell*, not rekordbox (T00 fault I2) |
| `research/probes/uimatrix.sh:43,94,112` | `pkill -f rekordbox.exe` + `wineserver -k` | the whole Agent tree |
| `research/probes/rbtrace.sh:22`, `research/probes/hidhide-test.sh:57` | `wineserver -k` | the whole Agent tree |
| `bin/rekordbox-wine`, `bin/rekordbox` | **nothing at all** — they `exec wine` and exit | everything, on every normal quit |

No path anywhere matched `rekordboxAgent`: they all pattern-match `rekordbox.exe`,
which cannot match `...\rekordboxAgent-win32-x64\rekordboxAgent.exe --type=renderer`.

**A `ps | grep` audit under-counts this.** Each leaked Agent's browser process shows
as `[CrBrowserMain] <defunct>` — a zombie leader — while 30 of its threads keep
running and it keeps its windows: `/proc/599198/status` reads `State: Z (zombie)`
with `Threads: 30`.

## Why it is a PERFORMANCE bug and not just untidiness

Two independent costs, and the second is the one that matches the user's report.

**1. Dead weight.** 3.1 GB resident and several always-waking processes competing
with the running application.

**2. ntsync is silently lost — this is the big one.** `wineserver` opens
`/dev/ntsync` exactly once, at startup, and caches the result forever
(`wine/server/inproc_sync.c`: `static int fd = -2`). It never retries. A wineserver
that was started before the module was loaded therefore runs **every** Windows
synchronisation primitive as a server round-trip for its entire life:

| | without ntsync | with ntsync |
|---|---|---|
| wineserver CPU | **43-65%** | **1.5-1.9%** |
| ntsync fds held by wineserver | 0 | 2,688 |

(measured, JOURNAL 2026-08-14T16:25 and re-verified 21:05 with 2,728 fds)

`/dev/ntsync` was created on this machine at 16:10; the oldest leaked session had
started at ~13:36. **Any session inherited from before the modprobe had been running
without the single biggest performance fix in the project** — and a long-lived
session is precisely what "it gets laggy the longer I use it" describes.

So a clean restart is not hygiene, it is the fix, and it has to happen *before*
launch rather than after quit — because it must also survive a crash, a SIGKILLed
harness, and the user simply closing the window.

## The specified cleandown

Implemented once, in `bin/rbclean.sh`. Order matters at every step:

1. **Enumerate by prefix, not by name.** For every `/proc/<pid>`, read `WINEPREFIX`
   out of `/proc/<pid>/environ` and keep only pids whose value is the target prefix.
   Name matching cannot tell this prefix's `explorer.exe` from another prefix's, and
   this machine has more than one prefix.
2. **Require the process to be a Wine process** — `/proc/<pid>/exe` must resolve into
   a wine path. Without this the sweep matches the *harness itself*: every launcher
   here exports `WINEPREFIX`, so rbclean SIGTERMed its own caller. Measured:
   `research/probes/fpsmatrix.sh` died with "Terminated" on its first cleandown.
3. **Refuse if rekordbox is alive**, unless `--force`. Prefer quitting from the
   application's own File menu so `rekordbox3.settings` is flushed.
4. **`wineserver -k`** — polite, and the only step that shuts a *healthy* session
   down properly.
5. **SIGTERM in dependency order**: rekordbox and `Cr*Main` first, then
   `explorer`/`powershell`/`conhost`, then `services`/`rpcss`/`plugplay`/`winedevice`,
   so anything still writing a file still has an rpcss to talk to. This project has
   already truncated `rekordbox3.settings` once by killing everything at once with -9.
6. **SIGKILL** whatever ignored TERM (in practice: `winedevice.exe`, every time).
7. **VERIFY** by re-reading `/proc` and failing loudly if the count is not zero. This
   is the step every ad-hoc teardown skipped.
8. **Assert `/dev/ntsync` exists** and state that the *next* wineserver is the one
   that picks it up.

Human verification one-liner — must print `0`, and `pgrep -x wineserver` must be empty:

    for p in /proc/[0-9]*; do tr '\0' '\n' 2>/dev/null < $p/environ \
      | grep -q "WINEPREFIX=$PREFIX" && echo ${p#/proc/}; done | wc -l

## Result

    before:  36 processes, 3,112 MB, no wineserver
    after:    0 processes, tray icons cleared  (3 winedevice.exe needed SIGKILL)

`bin/rekordbox-wine` now runs the cleandown before every launch, and reports the
prefix's state under "Session state" in `--check`. `--check` distinguishes a
*healthy* running session (wineserver present **and** rekordbox alive) from the
orphan state, so it does not nag about an application that is simply running.

The AUR package installs `rbclean.sh`, a `modules-load.d` entry for ntsync, and a
`.desktop` that goes through the launcher.

## Also fixed here

- `bin/rekordbox-wine --check` used to **boot the prefix** as a side effect of
  reporting on it: `wine reg query` starts a wineserver, services and explorer.
  On a machine where the default prefix does not exist it created and winebooted
  a brand-new empty one and then reported rekordbox missing. It now parses
  `user.reg` directly and starts nothing.
- Reading a `.reg` section through `awk -v` silently fails: awk expands escape
  sequences in a `-v` assignment, so the doubled backslashes that section headers
  really contain arrive as single ones and match nothing. Every override read back
  as "unset" on a correctly configured prefix. Pass it through the environment.
- The winealsa marker check demanded an *exact* marker list and so reported a
  more-patched library as "partially patched". It now checks the required markers
  are present.

## Open

- `bin/rbw`, `research/probes/uimatrix.sh`, `research/probes/rbtrace.sh` and `research/probes/hidhide-test.sh` still call
  bare `wineserver -k`. They should call `bin/rbclean.sh` instead. Until they do,
  running them will manufacture a fresh orphan set.
- `bin/rbw` kills `$!`, which is the backgrounded subshell rather than rekordbox
  (T00 fault I2). Any teardown built on `$!` is unreliable by construction.
- The stale Wine-generated `.desktop` files under
  `~/.local/share/applications/wine/Programs/rekordbox/` remain. One of them
  (`*.pre-rbw-backup`) launches **without** the dxgi override and therefore
  reproduces the one-frame freeze.
