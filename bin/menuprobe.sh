#!/usr/bin/env bash
# menuprobe — click each top-level menu in turn and record what actually happens.
#
# Reported by hand: File and Help "do not consistently show the menu", while
# View and Playlist are fine. That is a discriminating clue and worth measuring
# rather than reasoning about, because there are two very different candidate
# explanations:
#
#   * the popup window is never created  -> an application/menu-model problem
#   * the popup is created but not drawn  -> the same one-frame repaint class of
#     bug as T01, hitting freshly created popup windows
#
# So for each menu we record BOTH: the set of X windows before and after, and a
# full-screen capture (popups are separate top-level windows and can extend past
# the parent, so window-only capture would miss them).
#
# Usage: bin/menuprobe.sh <outdir> [repeats]
set -uo pipefail
OUT="${1:?usage: menuprobe.sh <outdir> [repeats]}"
REPEATS="${2:-3}"
mkdir -p "$OUT"

WID="$(for w in $(xdotool search --onlyvisible --class rekordbox 2>/dev/null); do
        eval "$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)" || continue
        (( WIDTH * HEIGHT > 400000 )) && echo "$w"
      done | head -1)"
[[ -z "$WID" ]] && { echo "no main rekordbox window"; exit 1; }
eval "$(xdotool getwindowgeometry --shell "$WID")"
echo "main window $WID ${WIDTH}x${HEIGHT}"

# Client-relative menu-bar coordinates, read off a known-good capture
# (runs/20260813T091454-rb7-ui-patched-d2d/shots/015-settle-final.png).
declare -A MENU=( [File]=24 [View]=72 [Track]=129 [Playlist]=191 [Help]=251 )
ORDER=(File View Track Playlist Help)
MENU_Y=12

winset() { xdotool search --onlyvisible "" 2>/dev/null | sort; }

shot() { timeout 20 spectacle -f -b -n -o "$1" >/dev/null 2>&1; }

# A popup is a NEW top-level window. Report its geometry too: a 1x1 or offscreen
# popup is a completely different fault from one that never appears.
newwins() {
  comm -13 "$OUT/.before" <(winset) | while read -r w; do
    [[ -z "$w" ]] && continue
    g="$(xdotool getwindowgeometry --shell "$w" 2>/dev/null)" || continue
    eval "$g"
    n="$(xdotool getwindowname "$w" 2>/dev/null)"
    echo "      +window $w ${WIDTH}x${HEIGHT} +${X}+${Y} '$n'"
  done
}

for rep in $(seq 1 "$REPEATS"); do
  echo "--- pass $rep"
  for m in "${ORDER[@]}"; do
    # Reset menu state properly between attempts: a JUCE menu bar keeps a
    # "currently open" mode, and a click that merely dismisses a leftover popup
    # would be scored as "this menu did not open". Move the pointer well away
    # from the bar, escape twice, and let it settle.
    xdotool windowactivate --sync "$WID" 2>/dev/null; sleep 0.4
    xdotool mousemove --window "$WID" 960 800; sleep 0.3
    xdotool key --clearmodifiers Escape 2>/dev/null; sleep 0.4
    xdotool key --clearmodifiers Escape 2>/dev/null; sleep 0.8
    winset > "$OUT/.before"
    shot "$OUT/${rep}-${m}-before.png"

    xdotool mousemove --window "$WID" "${MENU[$m]}" "$MENU_Y" click 1
    sleep 1.2
    shot "$OUT/${rep}-${m}-after.png"

    # How much of the screen changed, and did any new window appear?
    d="$(magick compare -metric RMSE "$OUT/${rep}-${m}-before.png" \
           "$OUT/${rep}-${m}-after.png" null: 2>&1 | grep -o '(.*)' | tr -d '()')"
    popup="$(comm -13 "$OUT/.before" <(winset) | while read -r w; do
               n="$(xdotool getwindowname "$w" 2>/dev/null)"
               [[ "$n" == "menu" ]] && echo yes; done | head -1)"
    printf "  %-10s %-6s rmse=%s\n" "$m" "${popup:+OPENED}${popup:-closed}" "${d:-?}"
    echo "$m ${popup:+1}${popup:-0}" >> "$OUT/tally"
    newwins

    xdotool key --clearmodifiers Escape 2>/dev/null; sleep 0.5
  done
done
rm -f "$OUT/.before"
echo "captures in $OUT"
