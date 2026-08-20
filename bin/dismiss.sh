#!/usr/bin/env bash
# dismiss — clear rekordbox's startup dialogs before any automation touches the UI.
#
# WHY THIS EXISTS. rekordbox opens two windows over the main UI on startup:
#
#   "rekordbox update manager"   offering 7.2.17 -> 7.2.18, with Start / Close
#   "INFO"                       the information/notification panel
#
# They sit on top of the library and the decks, so every scripted drag lands on
# a dialog instead of a track. That is exactly what happened: bin/loadplay.sh
# reported "the drag did not load anything" on essentially every fresh launch
# for a whole session, and the failure looked like a coordinate problem rather
# than a modal window. The user spotted it on screen in seconds.
#
# WHAT IT DOES. Closes every VIEWABLE window of the prefix that is not the main
# `rekordbox` window, and verifies they are gone. The update manager gets its
# Close button clicked (declining the update deliberately — this project is
# pinned to 7.2.17 and every patch and measurement is verified against it);
# everything else gets Escape.
#
# It never touches the main window: Alt+F4 on it quits rekordbox, which is how
# an earlier script lost a session.
#
# Usage: bin/dismiss.sh [--quiet]      exit 0 = the UI is clear
set -uo pipefail
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" = 1 ] || echo "$*"; }

MAIN=$(xdotool search --name '^rekordbox$' | head -1)

viewable() {
  local id
  for id in $(xdotool search --name '.' 2>/dev/null); do
    [ "$id" = "$MAIN" ] && continue
    xwininfo -id "$id" 2>/dev/null | grep -q 'IsViewable' || continue
    # tooltips and IME helpers come and go on their own and are not modal
    case "$(xdotool getwindowname "$id" 2>/dev/null)" in
      tooltip|''|'Default IME'|'Qt Selection Owner'*) continue ;;
    esac
    echo "$id"
  done
}

for pass in 1 2 3; do
  left=$(viewable)
  [ -z "$left" ] && { say "dismiss: UI is clear"; exit 0; }
  for id in $left; do
    name=$(xdotool getwindowname "$id" 2>/dev/null)
    say "dismiss: closing '$name' (pass $pass)"
    case "$name" in
      *'update manager'*)
        # Click Close, not Escape: this dialog's buttons are Start and Close and
        # we must be sure which one is pressed. Offset calibrated 2026-08-18
        # against a 502x278 dialog; verified by the window disappearing.
        eval "$(xdotool getwindowgeometry --shell "$id" | tr -d '\r')"
        xdotool windowactivate --sync "$id" 2>/dev/null; sleep 0.5
        xdotool mousemove $((X + WIDTH*420/502)) $((Y + HEIGHT*246/278)); sleep 0.4
        xdotool click 1
        ;;
      *)
        xdotool windowactivate --sync "$id" 2>/dev/null; sleep 0.4
        xdotool key --window "$id" Escape 2>/dev/null
        ;;
    esac
    sleep 2
  done
done

left=$(viewable)
if [ -n "$left" ]; then
  for id in $left; do say "dismiss: STILL OPEN: $(xdotool getwindowname "$id" 2>/dev/null) ($id)"; done
  say "dismiss: a dialog is still covering the UI — do not trust any scripted"
  say "         click until it is gone, and do not read a failed drag as a bug."
  exit 1
fi
say "dismiss: UI is clear"
