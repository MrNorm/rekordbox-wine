#!/usr/bin/env bash
# rbclean — take a Wine prefix back to a known-clean state before launching.
#
# WHY THIS EXISTS
#
# Measured 2026-08-14 (runs/CLEANDOWN/20260814T210239-before.txt): 37 orphaned
# Wine processes belonging to prefixes/rb7, holding 3.19 GB of RSS and having
# burned 650 CPU-seconds, with NO wineserver process alive at all. Three
# complete leaked sessions -- services.exe, plugplay.exe, explorer.exe,
# rpcss.exe, two winedevice.exe, powershell/conhost, and a full rekordboxAgent
# Electron tree (utility + renderer + gpu-process, ~220 MB each) -- one per
# launch. rekordboxAgent is what draws the system-tray icon, which is why the
# user sees several rekordbox icons in the tray after a few sessions.
#
# Two distinct problems come out of that, and this script exists for both:
#
#   1. DEAD WEIGHT. Leaked Electron trees and winedevice.exe keep waking up.
#      They cost RAM and CPU that the running app then has to compete for.
#
#   2. NTSYNC IS SILENTLY LOST. wineserver opens /dev/ntsync exactly once at
#      startup and caches the fd forever (wine server/inproc_sync.c:
#      `static int fd = -2`). A wineserver that was started before the module
#      was loaded NEVER retries. Without ntsync every Windows sync primitive
#      becomes a wineserver round-trip and the UI is visibly laggy -- that was
#      measured at wineserver 43-65% CPU vs 1.5-1.9% with it. So a long-lived
#      wineserver is not merely untidy, it is the single biggest known cause of
#      the lag this project is chasing. A clean start is a performance step.
#
# WHAT "CLEAN" MEANS HERE, in order:
#   ask the app's own server to shut the prefix down  (wineserver -k)
#   -> SIGTERM anything left, so it can flush its files
#   -> SIGKILL anything still there
#   -> VERIFY zero survivors, and fail loudly if not
#
# Scoping is by WINEPREFIX read from /proc/<pid>/environ, not by process name.
# Name matching cannot tell this prefix's explorer.exe from another prefix's,
# and this machine may well have other Wine applications running.
#
# Usage:
#   rbclean.sh              clean this prefix; refuses if rekordbox is alive
#   rbclean.sh --check      report only, change nothing (exit 1 if unclean)
#   rbclean.sh --force      clean even if rekordbox.exe is running (kills it)
#   rbclean.sh --quiet      only print if something needed doing
#
# Exit: 0 clean (or made clean) · 1 not clean / would not clean · 2 bad usage
set -uo pipefail

SELF="$(basename "$0")"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${WINEPREFIX:-${RBW_PREFIX:-$REPO/prefixes/rb7}}"
PREFIX="${PREFIX%/}"

MODE=clean
QUIET=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --check) MODE=check ;;
    --force) FORCE=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '1,60p' "$0"; exit 0 ;;
    *) echo "usage: $SELF [--check|--force|--quiet]" >&2; exit 2 ;;
  esac
done

say()  { [[ $QUIET -eq 1 ]] || printf '%s\n' "$*"; }
ok()   { [[ $QUIET -eq 1 ]] || printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }

# ---------------------------------------------------------------- enumeration
# Every WINE process of ours whose environment names this prefix. environ is
# readable only for our own uid, which is exactly the scope we want; the 2>/dev/null
# swallows the permission errors from every other user's processes.
#
# The exe check is not decoration. Any harness script that exports WINEPREFIX --
# which every launcher here does -- puts its own shell, and this script, inside
# the environ match. Without it rbclean SIGTERMs the thing that called it:
# measured, bin/fpsmatrix.sh died with "Terminated" on its first cleandown and
# every later variant then failed to launch. Only a process whose exe resolves
# into a wine path is a Wine process; bash, python and xdotool are not.
prefix_pids() {
  local p pfx exe
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue
    exe=$(readlink "/proc/$p/exe" 2>/dev/null)
    case "$exe" in
      */wine*|*/wineserver) ;;
      *) continue ;;
    esac
    # 2>/dev/null MUST precede the input redirect: redirections are applied left
    # to right, so with `< file 2>/dev/null` the shell's own "Permission denied"
    # for every other user's process is emitted before stderr is silenced. That
    # buried the actual report under 250 lines of noise.
    pfx=$(tr '\0' '\n' 2>/dev/null < "/proc/$p/environ" | sed -n 's/^WINEPREFIX=//p' | head -1)
    [[ "${pfx%/}" == "$PREFIX" ]] && echo "$p"
  done
  return 0
}

describe() {
  local p
  for p in "$@"; do
    [[ -r "/proc/$p/comm" ]] || continue
    printf '    %-8s %-16s %6s MB\n' "$p" "$(cat "/proc/$p/comm" 2>/dev/null)" \
      "$(awk '/VmRSS/{printf "%.0f", $2/1024}' "/proc/$p/status" 2>/dev/null)"
  done
}

alive() { local p; for p in "$@"; do [[ -d "/proc/$p" ]] && return 0; done; return 1; }

# ------------------------------------------------------------------- report
say
say "$(printf '\033[1mPrefix cleandown\033[0m  %s' "$PREFIX")"

mapfile -t PIDS < <(prefix_pids)
WS=$(pgrep -x wineserver 2>/dev/null | head -1)
RB=$(pgrep -f 'rekordbox\.exe' 2>/dev/null | head -1)

if [[ ${#PIDS[@]} -eq 0 ]]; then
  ok "no Wine processes in this prefix — already clean"
  # A stale server socket dir with nothing behind it is harmless, but say so.
  exit 0
fi

TOTMB=$(for p in "${PIDS[@]}"; do awk '/VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null; done \
        | awk '{s+=$1} END{printf "%.0f", s/1024}')
say "  found ${#PIDS[@]} process(es), ${TOTMB:-0} MB resident"
[[ $QUIET -eq 1 ]] || describe "${PIDS[@]}"

# The tray-icon culprits, called out by name because this is what the user sees.
AGENTS=$(pgrep -c -f 'rekordboxAgent' 2>/dev/null || true)
[[ "${AGENTS:-0}" -gt 0 ]] && say "  ${AGENTS} rekordboxAgent process(es) — these draw the system-tray icons"

if [[ -z "$WS" ]]; then
  warn "no wineserver is running, yet ${#PIDS[@]} Wine processes are"
  say  "        These are orphans: their server is gone, so they can neither"
  say  "        do useful work nor exit on their own. Only a signal clears them."
fi

if [[ $MODE == check ]]; then
  # "Clean" and "empty" are not the same question. A prefix running rekordbox
  # under its own wineserver is HEALTHY and a launcher must not report it as
  # leftover rubbish; a prefix with processes and no server, or with session
  # services but no application, is the orphan state this tool exists for.
  if [[ -n "$WS" && -n "$RB" ]]; then
    ok "rekordbox is running normally under its own wineserver — nothing to clean"
    exit 0
  fi
  bad "prefix is NOT clean"
  [[ -z "$WS" ]] && say "        (no wineserver: these are orphans and cannot exit on their own)"
  [[ -n "$WS" && -z "$RB" ]] && say "        (a session is up but rekordbox is not in it — leftover services)"
  say
  say "  fix: $SELF          (add --force if rekordbox is running and you mean it)"
  exit 1
fi

if [[ -n "$RB" && $FORCE -eq 0 ]]; then
  bad "rekordbox.exe is running (pid $RB) — refusing to kill a live session"
  say  "        Quit rekordbox from its own File menu, then re-run this."
  say  "        Or force it: $SELF --force   (unsaved library edits may be lost)"
  exit 1
fi

# --------------------------------------------------------------------- clean
# Stage 1: the polite route. wineserver -k signals every process in ITS prefix,
# which is why WINEPREFIX is exported for this call and nothing else.
if [[ -n "$WS" ]]; then
  say "  asking wineserver to shut the prefix down"
  WINEPREFIX="$PREFIX" WINEDEBUG=-all wineserver -k >/dev/null 2>&1
  for _ in $(seq 1 20); do
    mapfile -t PIDS < <(prefix_pids)
    [[ ${#PIDS[@]} -eq 0 ]] && break
    sleep 0.25
  done
fi

# Stage 2: SIGTERM. Order matters -- take the app and its agent down before the
# session services, so a process that wants to write a settings file on the way
# out still has an rpcss/services to talk to. This project has already truncated
# rekordbox3.settings once by killing everything at once with -9.
term_group() {
  local pat="$1" p found=0
  for p in "${PIDS[@]}"; do
    [[ -r "/proc/$p/comm" ]] || continue
    if [[ "$(cat "/proc/$p/comm" 2>/dev/null)" =~ $pat ]]; then kill -TERM "$p" 2>/dev/null && found=1; fi
  done
  [[ $found -eq 1 ]] && sleep 1
  return 0
}

mapfile -t PIDS < <(prefix_pids)
if [[ ${#PIDS[@]} -gt 0 ]]; then
  say "  SIGTERM (app first, then session services)"
  term_group 'rekordbox|Cr(Browser|Renderer|Gpu|Utility)Main'
  term_group 'explorer|powershell|conhost'
  term_group '.'
  for _ in $(seq 1 24); do
    mapfile -t PIDS < <(prefix_pids)
    [[ ${#PIDS[@]} -eq 0 ]] && break
    sleep 0.25
  done
fi

# Stage 3: SIGKILL. By here the process has had a server shutdown and a TERM and
# ignored both, so it is not going to flush anything.
mapfile -t PIDS < <(prefix_pids)
if [[ ${#PIDS[@]} -gt 0 ]]; then
  warn "${#PIDS[@]} process(es) ignored SIGTERM — SIGKILL"
  [[ $QUIET -eq 1 ]] || describe "${PIDS[@]}"
  for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done
  sleep 1
fi

# ------------------------------------------------------------------- verify
# "It should be gone by now" is how this project has fooled itself before, so
# the exit code rests on a re-read of /proc, not on the kills having returned 0.
mapfile -t PIDS < <(prefix_pids)
if [[ ${#PIDS[@]} -gt 0 ]]; then
  bad "${#PIDS[@]} process(es) SURVIVED SIGKILL — likely stuck in uninterruptible I/O"
  describe "${PIDS[@]}"
  exit 1
fi
ok "prefix is clean — 0 processes, tray icons cleared"

# ------------------------------------------------------------------- ntsync
# The whole point of a restart: the NEXT wineserver must be able to open
# /dev/ntsync. Report it here rather than leaving the user to discover the lag.
if [[ -e /dev/ntsync ]]; then
  ok "/dev/ntsync present — the next wineserver will pick it up (it caches the fd for life)"
else
  bad "/dev/ntsync ABSENT — the next session will be laggy (every wait becomes a server round-trip)"
  say  "        sudo modprobe ntsync"
  say  "        permanent: echo ntsync | sudo tee /etc/modules-load.d/rekordbox-wine.conf"
  exit 1
fi
exit 0
