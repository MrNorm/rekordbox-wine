#!/usr/bin/env bash
# audiotest.sh -- is rekordbox's Sample Rate dropdown populated?
#
# WHY THIS EXISTS
# ---------------
# Preferences -> Audio has two dropdowns. The Audio Device one lists devices.
# The Sample Rate one is supposed to list 44100/48000/... and it went EMPTY
# during a previous session without anyone noticing, because nothing re-checked
# it. This turns that into an exit code.
#
# WHY IT DRIVES THE UI INSTEAD OF PROBING THE API
# -----------------------------------------------
# upstream/wasapitest.exe reports 48/48 exclusive formats accepted RIGHT NOW,
# while the dropdown is blank. rekordbox builds its rate list at
# device-selection time, on a path wasapitest does not exercise, so a headless
# probe is a false negative generator. The only honest oracle is the widget.
#
# WHAT IT MEASURES
# ----------------
# One 196x16 px box: the value-text area of the Sample Rate combo, 6px inside
# its left edge. Peak brightness and standard deviation of that box, read as
# real pixels (see uiassert.py measure() for why `-format %[fx:maxima]` cannot
# be used). The combo interior is pure black, so glyphs are unmissable:
#     empty      peak=0.000  sd=0.000
#     populated  peak>=0.47  sd>=0.12
# Classification is uiassert.py's existing active/greyed/absent rule, calibrated
# per screenshot against two boxes inside the same dialog. Only `absent` --
# no glyphs at all -- is the regression; `greyed` still means the list has
# content, just dimly drawn.
#
# WHAT STOPS IT SILENTLY PASSING
# ------------------------------
# A test that always passes is worse than no test, so before it will grade
# anything it must clear four gates, and failing any of them is exit 2 (harness
# fault), never exit 0:
#   1. the captured PNG's size matches the live Preferences window's geometry
#      -- proves we photographed the dialog and not something that stole focus
#   2. the 'Audio' sidebar row is the selected one, by a clear margin over the
#      other five -- proves we are on the Audio pane. This one is not
#      theoretical: on the View pane the Sample Rate coordinates land on flat
#      panel that scores as 'greyed', which would have READ AS A PASS.
#   3. both section headings are present
#   4. the Audio Device combo -- same widget, same skin, same font, known
#      populated -- reads `active`. If the detector cannot see text that is
#      definitely there, its claim that other text is absent is worthless.
#
# EXIT CODES
#   0  Sample Rate has content
#   1  Sample Rate is EMPTY  (the regression)
#   2  harness fault -- the test could not run. Deliberately distinct from 1.
#
# USAGE
#   bin/audiotest.sh                 launch-or-attach, navigate, capture, grade
#   bin/audiotest.sh --no-launch     fail with 2 rather than starting rekordbox
#   bin/audiotest.sh --keep-open     leave the Preferences dialog open
#   bin/audiotest.sh --shot F.png    grade an existing capture, drive nothing
#   bin/audiotest.sh --self-test     prove the detector answers both ways

set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$HERE/runs/AUDIOTEST"
REGIONS="$HERE/scenarios/regions.json"
UIASSERT="$HERE/bin/uiassert.py"
STAMP="$(date +%Y%m%dT%H%M%S)"

WINEPREFIX_DEFAULT="$HERE/prefixes/rb7"
RB_EXE="$("$(dirname "${BASH_SOURCE[0]}")/rbexe.sh")"

LAUNCH=1
KEEP_OPEN=0
SHOT=""
SELFTEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-launch) LAUNCH=0 ;;
    --keep-open) KEEP_OPEN=1 ;;
    --shot)      SHOT="${2:-}"; shift ;;
    --self-test) SELFTEST=1 ;;
    -h|--help)   sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say()   { printf '%s\n' "$*"; }
fault() { printf 'HARNESS FAULT: %s\n' "$*" >&2; exit 2; }

need() { command -v "$1" >/dev/null 2>&1 || fault "missing required tool: $1"; }
for t in xdotool spectacle magick python3; do need "$t"; done
[ -x "$UIASSERT" ] || fault "not executable: $UIASSERT"
mkdir -p "$OUTDIR" || fault "cannot create $OUTDIR"

# ---------------------------------------------------------------- grading ----
# Applies the four gates then the verdict. Prints every number it used.
# $1 = png to grade, $2 = expected WxH or "" to skip gate 1.
grade() {
  local png="$1" want_geom="${2:-}"
  local got_geom
  got_geom="$(magick identify -format '%wx%h' "$png" 2>/dev/null)" \
    || fault "cannot read $png"

  if [ -n "$want_geom" ] && [ "$got_geom" != "$want_geom" ]; then
    fault "gate 1: captured $got_geom but the Preferences window is $want_geom.
       spectacle -a photographs the ACTIVE window; something else had focus."
  fi

  local json
  json="$("$UIASSERT" --shot "$png" --block audio_prefs --json 2>&1)"
  local rc=$?
  if [ $rc -ne 0 ]; then
    printf '%s\n' "$json" >&2
    [ $rc -eq 2 ] && fault "uiassert could not grade $png (see above)"
    fault "uiassert exited $rc on $png"
  fi

  # Script on stdin via a QUOTED heredoc, JSON via the environment: the grader
  # text contains both quote characters, and `python3 -c '...'` mangled it.
  AUDIOTEST_JSON="$json" python3 - <<'PYGRADE'
import json, os, sys
d = json.loads(os.environ["AUDIOTEST_JSON"])
r = d["regions"]
def s(n): return r[n]["state"]
def m(n): return r[n]

print("  measured %s  %dx%d" % (d["shot"], d["size"][0], d["size"][1]))
print("  calibration: bright(Audio Device text) peak=%.3f  dark(combo interior) peak=%.3f  -> active if peak>=%.3f"
      % (d["reference"]["bright"]["peak"], d["reference"]["dark"]["peak"], d["threshold"]))
for n in ("audio_device_value", "sample_rate_value"):
    x = m(n)
    print("  %-20s %-7s peak=%.3f mean=%.3f sd=%.3f  box=%s"
          % (n, x["state"], x["peak"], x["mean"], x["sd"], x["box"]))

# ---- gate 2: are we actually on the Audio pane? -------------------------
# PEAK, not mean. Measured 2026-08-14: an unselected row is dead flat
# (peak=mean=0.118, sd=0.000) while the selected row is 0.518 when the dialog
# has focus and 0.404 when it does not -- so the worst-case peak margin is
# 0.286 against the 0.10 required here. The same rows by MEAN give only
# 0.232-0.118 = 0.114 in the unfocused case, which is too near the line.
rows = {k: m(k)["peak"] for k in r if k.startswith("sidebar_sel_")}
order = sorted(rows.items(), key=lambda kv: -kv[1])
print("  sidebar selection (peak): "
      + ", ".join("%s=%.3f" % (k.replace("sidebar_sel_", ""), v) for k, v in order))
top, second = order[0], order[1]
if top[0] != "sidebar_sel_audio":
    print("HARNESS FAULT: gate 2: the selected sidebar row is %s, not audio. "
          "Not on the Audio pane; refusing to grade." % top[0].replace("sidebar_sel_",""),
          file=sys.stderr)
    sys.exit(2)
if top[1] - second[1] < 0.10:
    print("HARNESS FAULT: gate 2: no sidebar row is clearly selected "
          "(top %.3f vs next %.3f). Refusing to grade." % (top[1], second[1]), file=sys.stderr)
    sys.exit(2)

# ---- gate 3: the pane headings -----------------------------------------
for n in ("audio_heading", "sample_rate_heading"):
    if s(n) == "absent":
        print("HARNESS FAULT: gate 3: %s has no glyphs. The pane did not draw." % n,
              file=sys.stderr)
        sys.exit(2)

# ---- gate 4: the in-shot positive control ------------------------------
if s("audio_device_value") == "absent":
    print("HARNESS FAULT: gate 4: the Audio Device combo -- same widget, known "
          "populated -- reads absent too (peak=%.3f sd=%.3f). The detector is "
          "blind, so 'Sample Rate is empty' would be unfounded. Either no device "
          "is selected, or this is a measurement failure. Refusing to grade."
          % (m("audio_device_value")["peak"], m("audio_device_value")["sd"]),
          file=sys.stderr)
    sys.exit(2)

# ---- verdict ------------------------------------------------------------
v = m("sample_rate_value")
if v["state"] == "absent":
    print("")
    print("FAIL: Sample Rate dropdown is EMPTY.")
    print("      no glyphs in %s: peak=%.3f sd=%.3f (an empty combo is pure black)."
          % (v["box"], v["peak"], v["sd"]))
    print("      Positive control in the same shot: Audio Device text peak=%.3f sd=%.3f,"
          % (m("audio_device_value")["peak"], m("audio_device_value")["sd"]))
    print("      so the measurement is live and this absence is real.")
    sys.exit(1)
print("")
print("PASS: Sample Rate dropdown has content (state=%s peak=%.3f sd=%.3f)."
      % (v["state"], v["peak"], v["sd"]))
sys.exit(0)
PYGRADE
  return $?
}

# OCR is COMMENTARY ONLY and never touches the verdict: T00 recorded tesseract
# silently returning nothing, which here is indistinguishable from an empty
# dropdown -- i.e. it would fake the exact bug being hunted. Pixels decide.
ocr_note() {
  local png="$1"
  command -v tesseract >/dev/null 2>&1 || return 0
  local W H x y w h txt
  read -r W H <<<"$(magick identify -format '%w %h' "$png")"
  x=$(python3 -c "print(int(0.277916*$W))"); w=$(python3 -c "print(int(0.243176*$W))")
  y=$(python3 -c "print(int(0.305825*$H))"); h=$(python3 -c "print(int(0.019417*$H))")
  txt="$(magick "$png" -crop "${w}x${h}+${x}+${y}" +repage -resize 500% \
         -colorspace Gray -negate png:- 2>/dev/null \
         | tesseract - - --psm 7 2>/dev/null | tr -d '\f' | tr '\n' ' ' | sed 's/  */ /g')"
  say "  OCR of that box (commentary, not the verdict): '${txt## }'"
}

# --------------------------------------------------------------- selftest ----
# A test that can only ever return one answer is worthless, so this proves the
# detector returns BOTH. It takes any real capture of the Audio pane as a base
# and derives all three cases from it, so text is the ONLY variable:
#   negative  base with the combo's value area painted out in the combo's own
#             interior colour, sampled from the dark reference box
#   positives that same blanked image with '44100 Hz' drawn in, white and dim
#
# BOTH poles are synthesised rather than one of them being "whatever the app is
# doing today". If the negative were just a live broken capture, this self-test
# would start failing the day the bug is FIXED -- which is precisely when it is
# most important that it still works.
#
# Nothing is stored, because runs/** and *.png are both gitignored: checked-in
# fixtures would not survive a clone, and stale ones would misdescribe the skin.
if [ "$SELFTEST" -eq 1 ]; then
  base="$SHOT"
  if [ -z "$base" ]; then
    base="$(ls -1t "$OUTDIR"/*-audio.png 2>/dev/null | head -1)"
  fi
  [ -n "$base" ] && [ -f "$base" ] || fault "self-test needs a capture of the Audio pane.
       Run bin/audiotest.sh once to produce one, or pass --shot FILE."

  tmp="$(mktemp -d)" || fault "mktemp failed"
  trap 'rm -rf "$tmp"' EXIT
  neg="$tmp/empty.png"
  pos="$tmp/populated-white.png"
  dim="$tmp/populated-dim.png"

  read -r sw sh <<<"$(magick identify -format '%w %h' "$base")"
  # Geometry straight out of regions.json so the fixtures cannot drift from
  # what the grader actually measures.
  eval "$(python3 - "$REGIONS" "$sw" "$sh" <<'PYGEO'
import json, sys
cfg = json.load(open(sys.argv[1]))["audio_prefs"]
W, H = int(sys.argv[2]), int(sys.argv[3])
v = cfg["regions"]["sample_rate_value"]; d = cfg["reference"]["dark_background"]
x, y = int(v["x"]*W), int(v["y"]*H)
w, h = int(v["w"]*W), int(v["h"]*H)
print("VX=%d VY=%d VW=%d VH=%d" % (x, y, w, h))
print("DCX=%d DCY=%d" % (int(d["x"]*W) + int(d["w"]*W)//2, int(d["y"]*H) + int(d["h"]*H)//2))
print("TX=%d TY=%d" % (x + 2, y + h - 3))
PYGEO
)"
  # The combo's own interior colour, read from the dark reference box.
  fillcol="$(magick "$base" -format '%[pixel:p{'"$DCX"','"$DCY"'}]' info: 2>/dev/null)"
  [ -n "$fillcol" ] || fault "could not sample the combo interior colour"
  magick "$base" -fill "$fillcol" -stroke none \
    -draw "rectangle $((VX-1)),$((VY-1)) $((VX+VW+1)),$((VY+VH+1))" "$neg" 2>/dev/null \
    || fault "could not synthesise the empty control"
  for spec in "white:$pos" "#787878:$dim"; do
    col="${spec%%:*}"; out="${spec#*:}"
    magick "$neg" -fill "$col" -pointsize 13 -font DejaVu-Sans-Bold \
      -annotate "+${TX}+${TY}" '44100 Hz' "$out" 2>/dev/null \
      || fault "could not synthesise the positive control (font missing?)"
    [ -s "$out" ] || fault "empty synthetic fixture $out"
  done

  ok=1
  say "== self-test: the detector must answer BOTH ways on the same layout =="
  say "   base image = $base"
  say "   combo interior sampled as $fillcol; value box ${VW}x${VH}+${VX}+${VY}"
  say ""
  say "-- value area painted out: expect exit 1"
  grade "$neg" ""; r=$?; say "   exit $r"; [ $r -eq 1 ] || { ok=0; say "   WRONG"; }
  say ""
  say "-- + white text: expect exit 0"
  grade "$pos" ""; r=$?; say "   exit $r"; [ $r -eq 0 ] || { ok=0; say "   WRONG"; }
  say ""
  say "-- + dim grey text (low contrast): expect exit 0"
  grade "$dim" ""; r=$?; say "   exit $r"; [ $r -eq 0 ] || { ok=0; say "   WRONG"; }
  say ""
  if [ $ok -eq 1 ]; then
    say "self-test OK: the detector is not a constant."
    exit 0
  fi
  fault "self-test failed: the detector does not discriminate. Do not trust its verdicts."
fi

# ------------------------------------------------------------ offline mode ---
if [ -n "$SHOT" ]; then
  [ -f "$SHOT" ] || fault "no such screenshot: $SHOT"
  say "== grading $SHOT (offline, nothing driven) =="
  grade "$SHOT" ""
  exit $?
fi

# --------------------------------------------------------------- driving -----
main_window() { xdotool search --name '^rekordbox$' 2>/dev/null | head -1; }
prefs_window() {
  local id
  for id in $(xdotool search --name '^Preferences$' 2>/dev/null); do
    printf '%s\n' "$id"; return 0
  done
  return 1
}

say "== rekordbox Sample Rate dropdown check  ($STAMP) =="

WID="$(main_window)"
if [ -z "$WID" ]; then
  # NB: `pgrep -c` prints 0 *and* exits 1 on no match, so `|| echo 0` yields
  # "0\n0" and breaks `[ -gt ]`. Count lines from pgrep -f instead.
  procs="$(pgrep -f 'rekordbox\.exe' 2>/dev/null | wc -l)"
  if [ "$procs" -gt 0 ]; then
    say "rekordbox.exe is running ($procs process(es)) but has no window yet; waiting up to 120s"
  else
    [ "$LAUNCH" -eq 1 ] || fault "rekordbox is not running and --no-launch was given"
    say "rekordbox is not running; launching (needs ~90s to become usable)"
    ( export WINEPREFIX="${WINEPREFIX:-$WINEPREFIX_DEFAULT}"
      WINEDEBUG=-all nohup wine "$RB_EXE" >"$OUTDIR/$STAMP-launch.log" 2>&1 & ) || \
      fault "could not launch wine"
  fi
  for _ in $(seq 1 120); do
    sleep 1
    WID="$(main_window)"; [ -n "$WID" ] && break
  done
  [ -n "$WID" ] || fault "no window named 'rekordbox' after waiting; launch failed
       (see $OUTDIR/$STAMP-launch.log)"
  # A freshly mapped window is not a usable one.
  say "window $WID mapped; settling 20s"
  sleep 20
fi

n_inst="$(pgrep -f 'rekordbox\.exe' 2>/dev/null | wc -l)"
say "main window $WID   rekordbox.exe processes: $n_inst"

# --- open Preferences, or reuse one that is already open ---------------------
OPENED_BY_US=0
PID="$(prefs_window || true)"
if [ -n "$PID" ]; then
  say "Preferences already open (window $PID); reusing it"
else
  read -r MX MY MW MH <<<"$(xdotool getwindowgeometry --shell "$WID" \
      | sed -n 's/^X=\(.*\)/\1/p;s/^Y=\(.*\)/\1/p;s/^WIDTH=\(.*\)/\1/p;s/^HEIGHT=\(.*\)/\1/p' \
      | paste -sd' ')"
  [ -n "${MW:-}" ] || fault "cannot read main window geometry"
  # See regions.json audio_prefs.main_window_anchors for why this is measured
  # from the RIGHT edge rather than as a fraction.
  DXR=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['main_window_anchors']['preferences_gear']['dx_from_right'])")
  DYT=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['main_window_anchors']['preferences_gear']['dy_from_top'])")
  GX=$(( MX + MW - DXR ))
  GY=$(( MY + DYT ))
  say "clicking the preferences gear at screen ($GX,$GY)  [main window ${MW}x${MH} at +$MX+$MY]"
  # Retried, because a single click is NOT reliable here: measured 1 miss in 3
  # consecutive runs. The cause is click-to-focus -- if the main window is not
  # already active (e.g. the previous run just closed the dialog on top of it),
  # the first button press is consumed activating the window and never reaches
  # the gear. So: activate --sync, settle, click, and if no dialog appears,
  # do it again. A miss is harmless (the gear is a toggle only in the sense
  # that it opens the dialog; clicking it with the dialog already open does
  # nothing) and the loop exits the moment a Preferences window exists.
  for attempt in 1 2 3; do
    xdotool windowactivate --sync "$WID" >/dev/null 2>&1
    sleep 1.5
    xdotool mousemove "$GX" "$GY" >/dev/null 2>&1
    sleep 0.4
    xdotool click 1 >/dev/null 2>&1
    for _ in $(seq 1 10); do
      sleep 1
      PID="$(prefs_window || true)"; [ -n "$PID" ] && break
    done
    [ -n "$PID" ] && break
    if ! pgrep -f 'rekordbox\.exe' >/dev/null 2>&1; then
      fault "rekordbox exited while we were trying to open Preferences.
       The click did not miss -- there is nothing left to click. Historically
       this meant an earlier run closed the app with alt+F4; see the close
       block at the end of this script."
    fi
    say "  attempt $attempt: no dialog yet, retrying"
  done
  if [ -z "$PID" ]; then
    rm -f "$OUTDIR/$STAMP-gearmiss.png"
    xdotool windowactivate "$WID" >/dev/null 2>&1; sleep 1
    timeout 25 spectacle -a -b -n -o "$OUTDIR/$STAMP-gearmiss.png" >/dev/null 2>&1
    fault "3 clicks at ($GX,$GY) did not open a Preferences window.
       The gear anchor is wrong for this window size, or the click missed.
       Screenshot of what was on screen: $OUTDIR/$STAMP-gearmiss.png
       Re-calibrate audio_prefs.main_window_anchors in $REGIONS."
  fi
  OPENED_BY_US=1
  say "Preferences opened (window $PID)"
fi

# --- navigate to the Audio pane ---------------------------------------------
read -r PX PY PW PH <<<"$(xdotool getwindowgeometry --shell "$PID" \
    | sed -n 's/^X=\(.*\)/\1/p;s/^Y=\(.*\)/\1/p;s/^WIDTH=\(.*\)/\1/p;s/^HEIGHT=\(.*\)/\1/p' \
    | paste -sd' ')"
[ -n "${PW:-}" ] || fault "cannot read Preferences window geometry"

REFW=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['reference_geometry']['w'])")
REFH=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['reference_geometry']['h'])")
if [ "$PW" != "$REFW" ] || [ "$PH" != "$REFH" ]; then
  say "WARNING: Preferences is ${PW}x${PH}, calibrated at ${REFW}x${REFH}."
  say "         Regions are top-anchored layout, not true proportions, so this"
  say "         may mis-measure. The gates below will fault rather than guess."
fi

click_frac() { # $1 anchor name
  local ax ay sx sy
  ax=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['anchors']['$1']['x'])")
  ay=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['anchors']['$1']['y'])")
  sx=$(python3 -c "print(int($PX + $ax*$PW))")
  sy=$(python3 -c "print(int($PY + $ay*$PH))")
  say "clicking anchor '$1' at screen ($sx,$sy)  [prefs ${PW}x${PH} at +$PX+$PY]"
  xdotool windowactivate "$PID" >/dev/null 2>&1
  sleep 0.5
  xdotool mousemove "$sx" "$sy" >/dev/null 2>&1
  sleep 0.3
  xdotool click 1 >/dev/null 2>&1
  sleep 1.5
}

# Always click Audio explicitly. The dialog does reopen on whatever pane it was
# last left on, so a run that skipped this would pass or fail on the wrong pane.
# Order matters: pick the pane first, THEN its Configuration sub-tab. The
# Configuration/Input-Output tab pair belongs to the Audio pane, so clicking it
# while some other pane is showing would land on unrelated chrome.
click_frac sidebar_audio
click_frac tab_configuration

# rekordbox rebuilds the rate list when the pane is shown; give it a moment.
sleep 2

# --- capture ----------------------------------------------------------------
PNG="$OUTDIR/$STAMP-audio.png"
rm -f "$PNG"
xdotool windowactivate "$PID" >/dev/null 2>&1
sleep 1.5
# spectacle, NOT ImageMagick `import`: measured 2026-08-12, `import` returns
# pure black under this compositor, which for THIS test would fake a FAIL.
timeout 25 spectacle -a -b -n -o "$PNG" >/dev/null 2>&1
[ -s "$PNG" ] || fault "spectacle produced nothing at $PNG"
say "captured $PNG"
say ""

grade "$PNG" "${PW}x${PH}"
VERDICT=$?
ocr_note "$PNG"

if [ "$OPENED_BY_US" -eq 1 ] && [ "$KEEP_OPEN" -eq 0 ]; then
  # Close by CLICKING THE DIALOG'S OWN TITLEBAR X. Wine draws it 12px in from
  # the right edge, 11px down. Nothing else.
  #
  # DO NOT REINTRODUCE alt+F4 HERE, targeted or otherwise. Measured
  # 2026-08-14, one variable, 5 cycles each:
  #     xdotool key --window <prefs> alt+F4 -> cycle 1 did nothing at all;
  #                                            cycle 2 closed the dialog and
  #                                            then REKORDBOX EXITED a few
  #                                            seconds later.
  #     click the titlebar X                -> 5/5 dialog closed, rekordbox
  #                                            alive after every one.
  # Every "the gear click did not open Preferences" fault seen while building
  # this test turned out to be a later run finding rekordbox already gone,
  # killed by an earlier alt+F4. The exit is graceful (WM_CLOSE, not a signal,
  # so settings are not at risk) but it makes the test destroy its own subject.
  #
  # An untargeted `xdotool key alt+F4` is worse still: it goes to whatever holds
  # focus, which during development was the operator's terminal.
  closed=0
  CDXR=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['close']['dx_from_right'])")
  CDYT=$(python3 -c "import json;print(json.load(open('$REGIONS'))['audio_prefs']['close']['dy_from_top'])")
  xdotool windowactivate "$PID" >/dev/null 2>&1; sleep 0.6
  xdotool mousemove $(( PX + PW - CDXR )) $(( PY + CDYT )) >/dev/null 2>&1
  sleep 0.3
  xdotool click 1 >/dev/null 2>&1; sleep 1.5
  prefs_window >/dev/null 2>&1 || closed=1
  if [ $closed -eq 1 ]; then
    say "Preferences closed."
  else
    say "note: Preferences would not close on the titlebar X. Left open;"
    say "      harmless -- the next run reuses it."
  fi
fi

if ! pgrep -f 'rekordbox\.exe' >/dev/null 2>&1; then
  say "WARNING: rekordbox is no longer running at the end of this run."
  say "         The verdict above still stands (it was measured before), but"
  say "         something closed the app. Do not add keyboard-based window"
  say "         closing to this script -- see the comment above."
fi

exit $VERDICT
