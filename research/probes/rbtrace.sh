#!/usr/bin/env bash
# rbtrace.sh <label> <winedebug> <seconds>
# Launch rekordbox under a WINEDEBUG trace, wait, close gracefully, leave the
# log at runs/<id>/wine.log. One rekordbox at a time.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WINEPREFIX="$ROOT/prefixes/rb7"
LABEL="${1:?label}"; DBG="${2:?winedebug}"; SECS="${3:-100}"
EXE="$WINEPREFIX/drive_c/Program Files/rekordbox/rekordbox 7.2.18/rekordbox.exe"

if pgrep -f 'rekordbox\.exe' >/dev/null; then
  echo "refusing: rekordbox already running" >&2; exit 1
fi

ID="$(date +%Y%m%dT%H%M%S)-$LABEL"
DIR="$ROOT/runs/$ID"
mkdir -p "$DIR"
echo "RUN $ID"
echo "$ID" > "$ROOT/runs/.last-trace"

# fresh wineserver so winedevice.exe (hidclass/winebus) inherits WINEDEBUG too
wineserver -k 2>/dev/null; sleep 2

cd "$(dirname "$EXE")" || exit 1
WINEDEBUG="$DBG" nohup wine "$EXE" > "$DIR/wine.log" 2>&1 &
echo "launched pid $! at $(date +%T); sleeping ${SECS}s"
