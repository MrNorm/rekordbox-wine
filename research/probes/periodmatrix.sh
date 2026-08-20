#!/usr/bin/env bash
# periodmatrix — does Wine's buffer inflation cause the PC MASTER OUT stall?
#
# rekordbox asks for 5.805 ms on the DDJ (its configured 256 samples) and 10 ms
# on the PC master out. Wine's adjust_timing hands back 4x and 3x that. This
# runs the app once per arm with RBW_EXCL_PERIODS / RBW_SHARED_PERIODS set, and
# scores each with bin/enginerate.sh — 1.00x means the engine keeps real time.
#
# One variable per run: the same binary, the same track, one environment value.
# The arm is written into the run log so no result is ever orphaned from its
# conditions.
#
# Usage: research/probes/periodmatrix.sh <excl_periods> <shared_periods> [seconds]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
E="${1:-4}"; S="${2:-3}"; SECS="${3:-45}"
OUT="runs/PERIODMATRIX"; mkdir -p "$OUT"
STAMP=$(date +%Y%m%dT%H%M%S)
LOG="$OUT/$STAMP-excl${E}-shared${S}-sess${RBW_SESSION_NOTIFY:-stub}.log"

./bin/rbclean.sh --force --quiet >/dev/null 2>&1; sleep 3
echo "== arm excl=$E shared=$S session=${RBW_SESSION_NOTIFY:-stub} forceshared=${RBW_FORCE_SHARED:-0} mmcss=${RBW_MMCSS:-0} gate=${RBW_EVENT_GATE:-period} padding=${RBW_PADDING:-held} ==" | tee "$LOG"
( setsid env WINEPREFIX="$PWD/prefixes/rb7" WINEDLLOVERRIDES=dxgi=n \
    RBW_EXCL_PERIODS="$E" RBW_SHARED_PERIODS="$S" \
    RBW_SESSION_NOTIFY="${RBW_SESSION_NOTIFY:-}" RBW_FORCE_SHARED="${RBW_FORCE_SHARED:-}" RBW_MMCSS="${RBW_MMCSS:-}" RBW_EVENT_GATE="${RBW_EVENT_GATE:-}" RBW_PADDING="${RBW_PADDING:-}" \
    wine "$("$(dirname "${BASH_SOURCE[0]}")/rbexe.sh")" \
    > "$OUT/$STAMP-wine.log" 2>&1 & )
sleep 55
./bin/loadplay.sh 2>&1 | tail -1 | tee -a "$LOG"
# The buffer sizes Wine actually handed out, from the app's own run:
grep -a 'RBW-SESSION' "$OUT/$STAMP-wine.log" | tail -3 | sed 's/^[0-9a-f]*:err:mmdevapi://' | tee -a "$LOG"
grep -a 'RBW-PERIODS' "$OUT/$STAMP-wine.log" | tail -2 | sed 's/^[0-9a-f]*:err:mmdevapi://' | tee -a "$LOG"
grep -a 'RBW-DESC client_GetBufferSize' "$OUT/$STAMP-wine.log" | tail -2 | sed 's/.*RBW-DESC //' | tee -a "$LOG"
./bin/enginerate.sh "$SECS" 2>&1 | grep -E 'ENGINE RATE|read |state changes|MOVED|VOID' | tee -a "$LOG"
echo "   log: $LOG"
