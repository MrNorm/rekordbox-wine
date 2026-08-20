#!/usr/bin/env bash
# uisoak — does the UI get worse the longer it runs?
#
# WHY THIS EXISTS
#
# The user's report is not "it is slow", it is "OVER TIME the UI has become
# extremely laggy and is no longer usable". A single 12-second frame-rate sample
# cannot answer that no matter how good the instrument is: a session that starts
# at 58 fps and decays to 12 over an hour reads as perfect if you only ever
# measure the first minute. So this samples the same window repeatedly and
# reports the TREND, and it samples the resources that would explain a trend.
#
# WHAT IT SAMPLES, each period
#   fps + jitter   bin/damagefps on the real window (X DAMAGE, no capture:
#                  calibrated against glxgears at 60.17 vs its own 60.505, and
#                  cross-checked in-process against Wine's wglSwapBuffers count)
#   cpu            rekordbox and wineserver, from /proc, as percentages
#   threads        a thread count that climbs is a leak
#   rss            resident memory
#   handles        open fds -- Wine object leaks show up here first
#   wine procs     processes in the prefix; a count that climbs means the
#                  session is spawning helpers it never reaps
#   MHz + degC     THE LAPTOP CONFOUND. This is an i7-1255U in a thin chassis and
#                  rekordbox holds ~170% CPU with a track loaded. A frame rate
#                  that decays while the package sits at 86-94 degC and the
#                  clocks come down is a THERMAL result, not a software leak,
#                  and the two are indistinguishable from fps alone. Sampling
#                  them in the same row is what makes the verdict decidable.
#
# HOW TO READ IT
#   Steady fps with steady resources          -> no degradation; look elsewhere.
#   fps falling while threads/fds/rss climb   -> a leak; the climbing column names it.
#   fps falling, resources flat, MHz falling  -> thermal/power limit, not a leak.
#                                                Confirm with the cooldown test:
#                                                idle the app a few minutes and
#                                                re-measure WITHOUT restarting.
#                                                Recovery = thermal. No recovery
#                                                until restart = software.
#
# A DECK MUST HAVE A TRACK LOADED. Measured 2026-08-14: with both decks empty
# rekordbox runs its own 33 ms frame limiter and idles at 30 fps by design; with
# a track loaded it renders at 58 fps. Soaking an empty session measures the
# limiter, not the lag.
#
# Usage: research/probes/uisoak.sh [total_minutes] [sample_seconds]     default 20 min, 20 s
# Exit: 0 no degradation · 1 degraded · 2 harness fault
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
MINS="${1:-20}"
SAMPLE="${2:-20}"
export DISPLAY="${DISPLAY:-:0}"
PREFIX="${RBW_PREFIX:-$REPO/prefixes/rb7}"
OUT="$REPO/runs/SOAK"; mkdir -p "$OUT"
STAMP="$(date +%Y%m%dT%H%M%S)"
TSV="$OUT/$STAMP-soak.tsv"

fault() { printf 'HARNESS FAULT: %s\n' "$*" >&2; exit 2; }
[ -x "$REPO/bin/damagefps" ] || fault "bin/damagefps not built"

W=$("$REPO/bin/damagefps" --list 2>/dev/null | awk '/rekordbox/{print $1; exit}')
[ -n "$W" ] || fault "rekordbox has no window — start it first"
# Resolve the pid from the WINDOW. `pgrep -f 'rekordbox\.exe'` also matches any
# shell whose command line mentions the exe, and head -1 then returns bash --
# measured: GPU memory sampled as 0 MB because it was reading the wrong process.
RB=$(xprop -id "$W" _NET_WM_PID 2>/dev/null | awk '{print $3}')
[ -n "$RB" ] || RB=$(pgrep -x 'rekordbox.exe' | head -1)
[ -n "$RB" ] || fault "rekordbox.exe not running"
HZ=$(getconf CLK_TCK)

prefix_procs() {
  local p pfx exe n=0
  for p in /proc/[0-9]*; do
    p=${p#/proc/}
    exe=$(readlink "/proc/$p/exe" 2>/dev/null)
    case "$exe" in */wine*|*/wineserver) ;; *) continue ;; esac
    pfx=$(tr '\0' '\n' 2>/dev/null < "/proc/$p/environ" | sed -n 's/^WINEPREFIX=//p' | head -1)
    [ "${pfx%/}" = "${PREFIX%/}" ] && n=$((n+1))
  done
  echo "$n"
}

# GPU memory charged to this process, in MB. i915 exposes it per DRM fd; the app
# holds several fds onto the same device and they all report the same total, so
# take the maximum rather than the sum. A frame rate that decays while this
# climbs is a graphics-resource leak, which nothing else here would show: RSS
# does not account for GPU allocations.
drm_mb() {
  local f m=0 v
  for f in /proc/$1/fdinfo/*; do
    v=$(awk '/^drm-total-system0:/{print $2; exit}' "$f" 2>/dev/null) || continue
    [ -n "$v" ] && [ "$v" -gt "$m" ] && m=$v
  done
  echo $((m/1024))
}

cpu_mhz()  { awk '/MHz/{s+=$4; n++} END{if(n) printf "%.0f", s/n}' /proc/cpuinfo; }
cpu_degc() { # hottest zone, which is what the firmware actually throttles on
  local m=0 v
  for f in /sys/class/thermal/thermal_zone*/temp; do
    v=$(cat "$f" 2>/dev/null) || continue
    [ "${v:-0}" -gt "$m" ] && m=$v
  done
  echo $((m/1000))
}

printf 'elapsed_s\tfps\tp50_ms\tp99_ms\tmax_ms\tstutter_pct\trb_cpu\tws_cpu\tthreads\trss_mb\tfds\twine_procs\tmhz\tdegc\tgpu_mb\n' > "$TSV"

echo "uisoak $STAMP — window $W, pid $RB, ${MINS}min in ${SAMPLE}s samples"
echo "output: $TSV"
echo
printf '%8s %7s %7s %7s %8s %7s %7s %8s %7s %6s %6s %7s %5s %6s\n' \
  elapsed fps p50ms p99ms stutter% rb_cpu ws_cpu threads rss_MB fds procs MHz degC gpuMB

T0=$(date +%s)
END=$((T0 + MINS*60))
FIRST=""
LAST=""
RC=0

while [ "$(date +%s)" -lt "$END" ]; do
  WS=$(pgrep -x wineserver | head -1)
  r0=$(awk '{print $14+$15}' "/proc/$RB/stat" 2>/dev/null)
  w0=$([ -n "$WS" ] && awk '{print $14+$15}' "/proc/$WS/stat" 2>/dev/null)

  res=$("$REPO/bin/damagefps" "$W" "$SAMPLE" 2>/dev/null) || { echo "window gone — app exited"; RC=1; break; }

  r1=$(awk '{print $14+$15}' "/proc/$RB/stat" 2>/dev/null)
  w1=$([ -n "$WS" ] && awk '{print $14+$15}' "/proc/$WS/stat" 2>/dev/null)

  fps=$(sed -n 's/.*fps=\([0-9.]*\).*/\1/p' <<<"$res" | head -1)
  p50=$(sed -n 's/.*gap_ms_p50=\([0-9.-]*\).*/\1/p' <<<"$res" | head -1)
  p99=$(sed -n 's/.*gap_ms_p99=\([0-9.-]*\).*/\1/p' <<<"$res" | head -1)
  gmx=$(sed -n 's/.*gap_ms_max=\([0-9.-]*\).*/\1/p' <<<"$res" | head -1)
  stu=$(sed -n 's/.*stutter_pct=\([0-9.]*\).*/\1/p' <<<"$res" | head -1)

  rcpu=$(python3 -c "print(f'{($r1-$r0)/$HZ/$SAMPLE*100:.0f}')" 2>/dev/null || echo '?')
  if [ -n "${w0:-}" ] && [ -n "${w1:-}" ]; then
    wcpu=$(python3 -c "print(f'{($w1-$w0)/$HZ/$SAMPLE*100:.0f}')" 2>/dev/null)
  else
    wcpu="ABSENT"      # never silently substitute another pid's CPU here
  fi

  th=$(ls "/proc/$RB/task" 2>/dev/null | wc -l)
  rss=$(awk '/VmRSS/{printf "%.0f", $2/1024}' "/proc/$RB/status" 2>/dev/null)
  fds=$(ls "/proc/$RB/fd" 2>/dev/null | wc -l)
  np=$(prefix_procs)
  el=$(( $(date +%s) - T0 ))

  mhz=$(cpu_mhz); deg=$(cpu_degc); gpu=$(drm_mb "$RB")
  printf '%8s %7s %7s %7s %8s %7s %7s %8s %7s %6s %6s %7s %5s %6s\n' \
    "$el" "$fps" "$p50" "$p99" "$stu" "$rcpu" "$wcpu" "$th" "$rss" "$fds" "$np" "$mhz" "$deg" "$gpu"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$el" "$fps" "$p50" "$p99" "$gmx" "$stu" "$rcpu" "$wcpu" "$th" "$rss" "$fds" "$np" "$mhz" "$deg" "$gpu" >> "$TSV"

  [ -z "$FIRST" ] && FIRST="$fps"
  LAST="$fps"
done

echo
if [ -n "$FIRST" ] && [ -n "$LAST" ]; then
  python3 - "$FIRST" "$LAST" "$TSV" <<'EOF'
import sys
first, last, tsv = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
rows = [l.split('\t') for l in open(tsv).read().splitlines()[1:]]
def col(i):
    out = []
    for r in rows:
        if len(r) > i and r[i] not in ('', '-', 'ABSENT', '?'):
            try: out.append(float(r[i]))
            except ValueError: pass
    return out
fps, th, rss, fds, mhz, deg, gpu = col(1), col(8), col(9), col(10), col(12), col(13), col(14)
drop = (first - last) / first * 100 if first else 0
print(f"  fps        first {first:.1f}  last {last:.1f}  min {min(fps):.1f}  "
      f"change {-drop:+.1f}%")
if th:  print(f"  threads    {th[0]:.0f} -> {th[-1]:.0f}")
if fds: print(f"  open fds   {fds[0]:.0f} -> {fds[-1]:.0f}")
if rss: print(f"  rss MB     {rss[0]:.0f} -> {rss[-1]:.0f}")
if mhz: print(f"  cpu MHz    {mhz[0]:.0f} -> {mhz[-1]:.0f}")
if deg: print(f"  hottest C  {deg[0]:.0f} -> {deg[-1]:.0f}")
if gpu: print(f"  gpu mem MB {gpu[0]:.0f} -> {gpu[-1]:.0f}")
print()
# Name the likely explanation rather than leaving it to the reader: a laptop at its
# thermal limit and a software leak both look like "fps went down".
#
# The temperature alone must NOT trigger the thermal verdict. This machine sits at
# 93-97 degC whenever rekordbox runs at all, so `deg >= 85` is true in every single
# run: the first version of this test announced "suspect THERMAL" on a run whose
# clocks had gone UP (2276 -> 3004 MHz) and whose GPU memory had doubled, i.e. it
# contradicted its own data. Thermal now requires the CLOCKS to have actually
# fallen, and the graphics-memory check is asked first because it is the specific
# explanation while thermal is the ambient one.
if drop > 10:
    gpu_growth = (gpu[-1] / gpu[0] - 1) * 100 if gpu and gpu[0] else 0
    leak = (th and th[-1] > th[0] * 1.1) or (fds and fds[-1] > fds[0] * 1.1)
    thermal = mhz and mhz[-1] < mhz[0] * 0.9
    if gpu_growth > 25:
        print(f"  GPU memory grew {gpu_growth:.0f}% ({gpu[0]:.0f} -> {gpu[-1]:.0f} MB) while the "
              "frame rate fell.\n"
              "  That is a graphics-resource leak and it is the leading explanation: it makes\n"
              "  each frame more expensive without costing the app any more CPU. Nothing else\n"
              "  sampled here would show it — RSS does not account for GPU allocations.")
    elif leak:
        print("  the thread/fd count grew with it — look for a leak.")
    elif thermal:
        print(f"  clocks fell {mhz[0]:.0f} -> {mhz[-1]:.0f} MHz — suspect THERMAL, not software.\n"
              "  Confirm: idle the app a few minutes and re-measure WITHOUT restarting, and\n"
              "  measure a second GL client (glxgears) at the same moment. If glxgears still\n"
              "  hits 60 while this does not, the machine is fine and thermal is refuted.")
    else:
        print("  resources and clocks are flat — the per-frame cost itself grew.")
# 10% is well outside this instrument's run-to-run spread (measured: 29.67-29.92
# across five back-to-back variants, i.e. under 1%).
if drop > 10:
    print(f"  VERDICT: DEGRADED — frame rate fell {drop:.0f}% over the run.")
    raise SystemExit(1)
print(f"  VERDICT: STABLE — no degradation over the run "
      f"(fps stayed within {max(fps)-min(fps):.1f} of itself).")
EOF
  RC=$?
fi
echo "  full series: $TSV"
exit $RC
