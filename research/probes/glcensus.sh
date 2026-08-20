#!/usr/bin/env bash
# glcensus — which OpenGL objects does rekordbox create, and does it free them?
#
# WHY
#
# Measured 2026-08-14 (runs/SOAK/20260814T220312-soak.tsv): while the frame rate
# decays from 58 to 51 fps, the GPU memory charged to the rekordbox process climbs
# steadily at ~1 MB/sec -- 246 MB on a fresh session, 704 MB twelve minutes later --
# and the climb is entirely client-side (Xwayland flat at 97 MB, kwin at 0). GEM
# objects in that process are allocated by Mesa on behalf of the GL calls Wine
# makes, so the question is whether the create/destroy calls BALANCE.
#
#   creates >> destroys   -> something never frees. Then: is the missing free the
#                            application's (it never calls glDelete*) or Wine's
#                            (the call is made but not forwarded)?
#   creates == destroys   -> the leak is not object churn; look at buffer respec
#                            (glTexImage2D/glBufferData reallocating storage).
#
# HOW, and the honest caveat
#
# WINEDEBUG=+opengl makes Wine trace every GL call from its PE thunk layer
# (dlls/opengl32/thunks.c: 3,072 TRACE points). That is enormously expensive and
# WILL slow the application down -- so the absolute rates here are NOT a frame-rate
# measurement and must never be quoted as one. What survives the slowdown is the
# RATIO of creates to destroys, which is the only thing this tool claims.
#
# The trace is streamed through grep and never written to disk: at 58 fps this is
# gigabytes a minute.
#
# Usage: research/probes/glcensus.sh [seconds]      default 25 (after a 60s settle)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
SECS="${1:-25}"
PREFIX="${RBW_PREFIX:-$REPO/prefixes/rb7}"
EXE="$("$(dirname "${BASH_SOURCE[0]}")/rbexe.sh")"
OUT="$REPO/runs/GLCENSUS"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%dT%H%M%S)"
export WINEPREFIX="$PREFIX" DISPLAY="${DISPLAY:-:0}"

# Everything that allocates or frees GPU-backed storage, plus the swap so frames
# can be counted and the others expressed per frame.
PAT='glGenTextures|glDeleteTextures|glGenBuffers|glDeleteBuffers|glGenFramebuffers|glDeleteFramebuffers|glGenRenderbuffers|glDeleteRenderbuffers|glGenVertexArrays|glDeleteVertexArrays|glTexImage2D|glTexSubImage2D|glBufferData|glBufferSubData|glMapBuffer|glUnmapBuffer|wglSwapBuffers|glGenLists|glDeleteLists'

echo "glcensus $STAMP — this makes the app very slow; ratios only, never rates"
"$REPO/bin/rbclean.sh" --force --quiet >/dev/null 2>&1

FIFO=$(mktemp -u); mkfifo "$FIFO"
setsid env RBW_MIDI_RENAME='Generic MIDI Controller' WINEDEBUG=+opengl \
  wine "$EXE" > "$FIFO" 2>&1 &
# Count names as they stream past. Nothing is stored.
grep --line-buffered -oE "\b($PAT)\b" < "$FIFO" > "$OUT/$STAMP-names.txt" &
GREPPID=$!

echo "waiting for the window (tracing makes startup slow)"
W=""
for _ in $(seq 1 80); do
  W=$("$REPO/bin/damagefps" --list 2>/dev/null | awk '/rekordbox/{print $1; exit}')
  [ -n "$W" ] && break
  sleep 5
done
[ -n "$W" ] || { echo "FAULT: no window"; kill $GREPPID 2>/dev/null; rm -f "$FIFO"; exit 2; }

echo "settling 60s so startup allocation is not counted"
sleep 60
A=$(wc -l < "$OUT/$STAMP-names.txt")
cp "$OUT/$STAMP-names.txt" "$OUT/$STAMP-mark.txt"
sleep "$SECS"
cp "$OUT/$STAMP-names.txt" "$OUT/$STAMP-end.txt"

echo
echo "=== GL calls in a ${SECS}s steady-state window ==="
tail -n +$((A+1)) "$OUT/$STAMP-end.txt" | sort | uniq -c | sort -rn

echo
echo "=== the question this tool exists to answer ==="
w() { tail -n +$((A+1)) "$OUT/$STAMP-end.txt" | grep -c "^$1$" || true; }
for pair in Textures Buffers Framebuffers Renderbuffers VertexArrays; do
  g=$(w "glGen$pair"); d=$(w "glDelete$pair")
  printf '  %-14s created %-8s destroyed %-8s %s\n' "$pair" "$g" "$d" \
    "$( [ "$g" -gt "$((d + d/10 + 1))" ] && echo '<-- NOT BALANCED' || echo '' )"
done

kill $GREPPID 2>/dev/null; rm -f "$FIFO"
echo
echo "raw name stream: $OUT/$STAMP-end.txt"
