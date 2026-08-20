#!/usr/bin/env bash
# fpsmatrix — measure rekordbox's real frame rate and jitter, one variable at a time.
#
# WHY THIS EXISTS
#
# "The UI is laggy" was a user report with no number behind it for two sessions,
# and every attempt to put a number on it was invalid. ffmpeg -f x11grab returns
# a BLACK root window for XWayland clients under KWin, so the frame counts it
# produced were the mouse cursor ffmpeg draws itself -- two runs that should
# have differed came back at exactly 101 frames each, which is what exposed it
# (JOURNAL 2026-08-14T17:32). Every ffmpeg-derived number in this repo is void.
#
# THE INSTRUMENT, and why it is trustworthy
#
# bin/damagefps counts X DAMAGE events on the rekordbox window. Damage is the
# signal the compositor itself uses to know a window repainted; it carries no
# pixels, so a black capture cannot fool it. It is calibrated both ways:
#
#   positive control  glxgears        damagefps 60.17 fps  glxgears' own: 60.505
#   negative control  a static window damagefps  0.20 fps  (one map, then none)
#
# and cross-checked in-process against Wine's own present counter: with
# WINEDEBUG=+fps, Wine prints the app's wglSwapBuffers rate from inside the
# process. Measured together in one run: damage 29.70, Wine 29.68-29.78. Two
# independent instruments, one external and one in-process, agreeing to 0.1 fps.
# Neither can see the cursor and neither reads a pixel.
#
# WHY JITTER, NOT JUST THE MEAN
#
# A waveform that averages 30 fps by delivering 60,60,4,60,4 is unusable while
# its mean looks respectable, so the gap distribution (p50/p90/p99/max) and the
# count of gaps over one dropped frame are reported alongside. For a DJ the
# worst gap is the number that matters -- it is the one that lands on the beat.
#
# ONE VARIABLE PER RUN
#
# Each variant is a full cycle: cleandown -> edit config with the app CLOSED ->
# launch -> settle -> measure. rekordbox REWRITES its settings file on exit, so
# a value set while it is running is silently discarded; every variant therefore
# re-reads the file after launch and refuses to report a number if the setting
# it was supposed to be testing did not survive.
#
# Usage:
#   fpsmatrix.sh                          measure the current config only
#   fpsmatrix.sh --variants               run the built-in renderer A/B set
#   fpsmatrix.sh --set K=V[,K=V...]       one custom variant
#   fpsmatrix.sh --secs N                 measure window, default 12
#   fpsmatrix.sh --soak N                 single long run of N seconds (degradation)
#
# Exit: 0 measured ok · 1 a variant could not be measured · 2 harness fault
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"

PREFIX="${RBW_PREFIX:-$REPO/prefixes/rb7}"
SETTINGS="$PREFIX/drive_c/users/$USER/AppData/Roaming/Pioneer/rekordbox6/rekordbox3.settings"
EXE="$("$(dirname "${BASH_SOURCE[0]}")/rbexe.sh")"
OUT="$REPO/runs/FPS"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%dT%H%M%S)"
SECS=12
SOAK=0
MODE=current
CUSTOM=""

while [ $# -gt 0 ]; do
  case "$1" in
    --variants) MODE=variants ;;
    --set)      MODE=custom; CUSTOM="${2:-}"; shift ;;
    --secs)     SECS="${2:-12}"; shift ;;
    --soak)     SOAK="${2:-300}"; MODE=soak; shift ;;
    -h|--help)  sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

fault() { printf 'HARNESS FAULT: %s\n' "$*" >&2; exit 2; }

# GPU memory charged to a process, MB. Invisible to RSS: i915 buffer objects are
# mapped but not process-resident, which is why every conventional counter said
# "no leak" while 50 MB a minute accumulated.
gpu_mb() {
  local f m=0 v try
  [ -n "${1:-}" ] || { echo ""; return; }
  # Retry once. A single sweep occasionally reads every fd as 0 while the process
  # is plainly alive and holding 250 MB -- measured: a 60 s run reported
  # "124 -> 0 MB, -2.07 MB/s", i.e. it invented a NEGATIVE leak rate. An empty
  # string is the honest answer when the read fails; a zero is a lie that gets
  # arithmetic done to it.
  for try in 1 2; do
    m=0
    for f in /proc/$1/fdinfo/*; do
      v=$(awk '/^drm-total-system0:/{print $2; exit}' "$f" 2>/dev/null) || continue
      [ -n "$v" ] && [ "$v" -gt "$m" ] && m=$v
    done
    [ "$m" -gt 0 ] && break
    [ -d "/proc/$1" ] || { echo ""; return; }
    sleep 0.3
  done
  [ "$m" -gt 0 ] && echo $((m/1024)) || echo ""
}
say()   { printf '%s\n' "$*"; }

command -v xdotool >/dev/null || fault "xdotool not installed"
[ -x "$REPO/bin/damagefps" ] || {
  say "building bin/damagefps"
  cc -O2 -o "$REPO/bin/damagefps" "$REPO/research/probes/damagefps.c" -lXdamage -lXfixes -lXext -lX11 \
    || fault "cannot build damagefps"
}
[ -f "$SETTINGS" ] || fault "no settings file at $SETTINGS"

export DISPLAY="${DISPLAY:-:0}"
export WINEPREFIX="$PREFIX"

# ---------------------------------------------------------------- config edit
# Only ever touched with the app closed: rekordbox rewrites this file on exit.
get_val() { grep -oE "<VALUE name=\"$1\" val=\"[^\"]*\"" "$SETTINGS" 2>/dev/null | sed 's/.*val="//;s/"$//'; }
set_val() {
  local k="$1" v="$2"
  grep -q "<VALUE name=\"$k\"" "$SETTINGS" || { echo "  (no such setting: $k)"; return 1; }
  sed -i "s|<VALUE name=\"$k\" val=\"[^\"]*\"/>|<VALUE name=\"$k\" val=\"$v\"/>|" "$SETTINGS"
}

# ------------------------------------------------------------------ load a track
# Coordinates are absolute screen pixels, calibrated 2026-08-14 against a
# screenshot of the 1920x1006 window at +0+28 and verified by capturing the row
# highlight after the click. Fractional coordinates were tried first and missed
# the row by ~16 px, which is enough to grab the header instead.
#
# A double-click only SELECTS a row; rekordbox loads a deck by DRAG AND DROP, and
# the drag needs a threshold-crossing jiggle plus small steps or the app never
# sees it as a drag at all. Verified by screenshot: deck 1 reads the track title
# and draws its waveform.
LIB_X=684; LIB_Y=618            # the "Demo Track 1" row (02:52, long enough to soak)
DECK_X=215; DECK_Y=236          # deck 1's title bar
PLAY_X=717; PLAY_Y=418          # deck 1 play button

load_track() {
  local W="$1"
  xdotool windowactivate --sync "$W" 2>/dev/null; sleep 1
  xdotool mousemove $LIB_X $LIB_Y; sleep 0.4; xdotool click 1; sleep 1.5
  xdotool mousemove $LIB_X $LIB_Y; sleep 0.4; xdotool mousedown 1; sleep 0.4
  local d f x y
  for d in 3 8 15 25; do xdotool mousemove $LIB_X $((LIB_Y-d)); sleep 0.15; done
  for f in $(seq 1 14); do
    x=$(python3 -c "print(int($LIB_X + ($DECK_X-$LIB_X)*$f/14))")
    y=$(python3 -c "print(int($LIB_Y-25 + ($DECK_Y-($LIB_Y-25))*$f/14))")
    xdotool mousemove "$x" "$y"; sleep 0.15
  done
  sleep 0.5; xdotool mousemove $DECK_X $DECK_Y; sleep 0.5; xdotool mouseup 1
  sleep 6

  # Verify by the frame rate itself: an empty deck sits at the 30 fps limiter, a
  # loaded one renders at ~58. That is a far more reliable check than a screenshot
  # and it is the same instrument the run reports with.
  local probe
  probe=$("$REPO/bin/damagefps" "$W" 4 | sed -n 's/.*fps=\([0-9.]*\).*/\1/p' | head -1)
  say "  post-load probe: ${probe} fps"
  awk -v f="${probe:-0}" 'BEGIN{exit !(f>40)}' || return 1
  return 0
}

# ---------------------------------------------------------------- run a variant
# label, "K=V,K=V" (empty = leave config alone)
measure_variant() {
  local label="$1" spec="$2" secs="$3"
  local log="$OUT/$STAMP-$label.log"

  say ""
  say "=== $label ==="

  "$REPO/bin/rbclean.sh" --force --quiet >/dev/null 2>&1

  # Split on commas WITHOUT touching IFS. `local IFS=,` looks harmless and is
  # not: it stays in force for the rest of the function, so the later
  # `for _ in $(seq 1 40)` poll loop stopped splitting on newlines, ran exactly
  # once, and reported "no window after 120s" after waiting three seconds.
  # Four of five variants were written off on that lie.
  local kv k v
  if [ -n "$spec" ]; then
    for kv in $(printf '%s\n' "$spec" | tr ',' '\n'); do
      k="${kv%%=*}"; v="${kv#*=}"
      set_val "$k" "$v" || return 1
      say "  set $k=$v"
    done
  fi

  # setsid so the app is not in this script's process group: without it the
  # shell's job-control notices ("Killed") land in the middle of the report and
  # a signal aimed at the harness would take the measurement subject with it.
  setsid env RBW_VBLANK_STATS=1 RBW_MIDI_RENAME='Generic MIDI Controller' WINEDEBUG=+fps \
    wine "$EXE" > "$log" 2>&1 &
  disown 2>/dev/null || true

  local W=""
  for _ in $(seq 1 40); do
    W=$("$REPO/bin/damagefps" --list 2>/dev/null | awk '/rekordbox/{print $1; exit}')
    [ -n "$W" ] && break
    sleep 3
  done
  [ -n "$W" ] || { say "  FAULT: no window after 120s"; return 1; }

  # Let startup work (library load, device probe, analysis) finish, or the first
  # seconds of every run measure launch cost instead of steady state.
  sleep 20

  # LOAD A TRACK. This is not optional and its absence invalidated an entire
  # variant matrix: with both decks empty rekordbox draws no waveform and runs its
  # own 33 ms frame limiter at 29.8 fps, so every renderer setting measured
  # identical -- and was written off as a no-op -- in a state where none of them
  # can do anything. The fault under investigation only exists with a deck loaded.
  load_track "$W" || { say "  FAULT: could not load a track — refusing to report a number"; return 1; }

  # The setting must have survived the launch, or the variant tested nothing.
  if [ -n "$spec" ]; then
    local now
    for kv in $(printf '%s\n' "$spec" | tr ',' '\n'); do
      k="${kv%%=*}"; v="${kv#*=}"
      now="$(get_val "$k")"
      if [ "$now" != "$v" ]; then
        say "  FAULT: $k reverted to '$now' (wanted '$v') — not reporting a number"
        return 1
      fi
    done
    say "  verified: config survived launch"
  fi

  local RB WS HZ r0 w0 r1 w1 g0 g1
  # Resolve the pid from the WINDOW, never from `pgrep -f rekordbox.exe`: that
  # pattern also matches any shell whose command line mentions the exe -- including
  # this harness's own launcher -- and `head -1` then returns bash. Measured: a GPU
  # memory sample read 0 MB because it was reading the shell.
  RB=$(xprop -id "$W" _NET_WM_PID 2>/dev/null | awk '{print $3}')
  [ -n "$RB" ] || RB=$(pgrep -x 'rekordbox.exe' | head -1)
  WS=$(pgrep -x wineserver | head -1)
  HZ=$(getconf CLK_TCK)
  # A missing wineserver must read as ABSENT, never as a number. research/probes/uilag.sh
  # fell back to ${WSPID:-$PID} and so reported rekordbox's own CPU under the
  # label "wineserver" in exactly the orphaned-prefix state that turns out to be
  # common here -- an instrument that lies when the thing it measures is gone.
  ticks() { [ -n "${1:-}" ] && awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo ""; }
  r0=$(ticks "$RB"); w0=$(ticks "$WS"); g0=$(gpu_mb "$RB")

  local res
  res=$("$REPO/bin/damagefps" "$W" "$secs")

  r1=$(ticks "$RB"); w1=$(ticks "$WS"); g1=$(gpu_mb "$RB")

  local fps p50 p99 gmax stut tl
  fps=$(sed -n 's/.*fps=\([0-9.]*\).*/\1/p' <<<"$res" | head -1)
  p50=$(sed -n 's/.*gap_ms_p50=\([0-9.-]*\).*/\1/p' <<<"$res" | head -1)
  p99=$(sed -n 's/.*gap_ms_p99=\([0-9.-]*\).*/\1/p' <<<"$res" | head -1)
  gmax=$(sed -n 's/.*gap_ms_max=\([0-9.-]*\).*/\1/p' <<<"$res" | head -1)
  stut=$(sed -n 's/.*stutter_pct=\([0-9.]*\).*/\1/p' <<<"$res" | head -1)
  tl=$(grep '^TIMELINE' <<<"$res")

  # Wine's own in-process present counter, as an independent cross-check.
  local wfps
  wfps=$(grep -a 'fps:wglSwapBuffers' "$log" | tail -3 \
         | sed -n 's/.*approx \([0-9.]*\)fps.*/\1/p' | tail -1)
  # And the frame CLOCK, which is a different question from the frame RATE.
  local vbl
  vbl=$(grep -a 'RBW-VBLANK2 rate' "$log" | tail -1 | sed -n 's/.*rate: \([0-9.]*\) frames.*/\1/p')

  local rcpu wcpu
  if [ -n "$r0" ] && [ -n "$r1" ]; then
    rcpu=$(python3 -c "print(f'{($r1-$r0)/$HZ/$secs*100:.0f}')" 2>/dev/null)
  else rcpu="?"; fi
  if [ -n "$w0" ] && [ -n "$w1" ]; then
    wcpu=$(python3 -c "print(f'{($w1-$w0)/$HZ/$secs*100:.0f}')" 2>/dev/null)%
  else wcpu="ABSENT"; fi

  printf '  damage fps      : %s   (gaps ms p50 %s  p99 %s  max %s, %s%% dropped)\n' \
    "$fps" "$p50" "$p99" "$gmax" "$stut"
  printf '  wine wglSwap fps: %s   (in-process cross-check)\n' "${wfps:-n/a}"
  printf '  vblank clock    : %s   (the tick JUCE waits on, not the paint)\n' "${vbl:-n/a}"
  printf '  CPU             : rekordbox %s%%  wineserver %s\n' "$rcpu" "$wcpu"
  if [ -n "$g0" ] && [ -n "$g1" ]; then
    printf '  GPU memory      : %s -> %s MB over %ss  (%s MB/s — the leak rate)\n' \
      "$g0" "$g1" "$secs" "$(python3 -c "print(f'{($g1-$g0)/$secs:.2f}')" 2>/dev/null)"
  else
    printf '  GPU memory      : UNREADABLE (not reporting a rate)\n'
  fi
  say  "  $tl"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$fps" "${wfps:-}" "${vbl:-}" "$p50" "$p99" "$gmax" "$stut" "$rcpu" \
    >> "$OUT/$STAMP-summary.tsv"
  return 0
}

say "fpsmatrix $STAMP   prefix=$PREFIX"
say "instrument: X DAMAGE (calibrated: glxgears 60.17 vs its own 60.505; static window 0.20)"
printf 'label\tdamage_fps\twine_fps\tvblank\tp50\tp99\tmax\tstutter%%\tcpu%%\n' > "$OUT/$STAMP-summary.tsv"

RC=0
case "$MODE" in
  current)
    measure_variant "as-configured" "" "$SECS" || RC=1
    ;;
  custom)
    measure_variant "custom" "$CUSTOM" "$SECS" || RC=1
    ;;
  soak)
    measure_variant "soak-${SOAK}s" "" "$SOAK" || RC=1
    ;;
  variants)
    # Baseline first, and restore it last, so the prefix is left as we found it.
    B_GL=$(get_val DisableOpenGL); B_BASIC=$(get_val BasicOpenGL)
    B_VSYNC=$(get_val DisableAdaptiveVsync); B_VERT=$(get_val UseVertexWave)
    say "baseline: DisableOpenGL=$B_GL BasicOpenGL=$B_BASIC DisableAdaptiveVsync=$B_VSYNC UseVertexWave=$B_VERT"

    measure_variant "baseline"            "" "$SECS" || RC=1
    measure_variant "adaptive-vsync-off"  "DisableAdaptiveVsync=1" "$SECS" || RC=1
    measure_variant "opengl-off"          "DisableAdaptiveVsync=$B_VSYNC,DisableOpenGL=1" "$SECS" || RC=1
    measure_variant "basic-opengl"        "DisableOpenGL=$B_GL,BasicOpenGL=1" "$SECS" || RC=1
    measure_variant "no-vertex-wave"      "BasicOpenGL=$B_BASIC,UseVertexWave=0" "$SECS" || RC=1

    "$REPO/bin/rbclean.sh" --force --quiet >/dev/null 2>&1
    set_val DisableOpenGL "$B_GL"; set_val BasicOpenGL "$B_BASIC"
    set_val DisableAdaptiveVsync "$B_VSYNC"; set_val UseVertexWave "$B_VERT"
    say ""
    say "restored the original settings"
    ;;
esac

say ""
say "summary: $OUT/$STAMP-summary.tsv"
column -t -s $'\t' "$OUT/$STAMP-summary.tsv"
exit $RC
