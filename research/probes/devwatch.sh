#!/usr/bin/env bash
# devwatch — passive observer for the DDJ-400 binding path.
#
# The controller failure is intermittent and involves things that only exist
# while rekordbox is running: the Wine ALSA sequencer client, its subscription
# to the controller, and the rawmidi byte counters. Killing rekordbox to inspect
# it destroys exactly the state we want to look at, and asking the user to
# narrate what they see is not evidence.
#
# So: sample once a second, emit a line ONLY when something changes, and never
# touch the application. The output is a timeline that can be diffed against
# what the user was doing.
#
# Columns are deliberately narrow so a long capture stays readable:
#   pid      rekordbox.exe pid, or "-" when not running
#   seq      Wine's ALSA sequencer client number, or "-"
#   sub      "yes" if the Wine input port is subscribed to the DDJ-400
#   tx/rx    rawmidi byte counters for the controller (cumulative)
#   hidraw   how many processes hold /dev/hidraw0 open
#
# Usage: research/probes/devwatch.sh [seconds] > runs/devwatch-<label>.tsv
set -uo pipefail
DURATION="${1:-1800}"
CARD_MIDI=""

# The controller's rawmidi node moves with the card number, so find it rather
# than hardcoding card1 — a replug can renumber it, and a stale path would
# silently report Tx 0 forever and look like the bug we are hunting.
find_midi() {
  local f
  for f in /proc/asound/card*/midi*; do
    [[ -r "$f" ]] || continue
    if head -1 "$f" 2>/dev/null | grep -qi 'DDJ'; then echo "$f"; return; fi
  done
}

sample() {
  local pid seq sub tx rx hidraw line
  pid=$(pgrep -f 'rekordbox\.exe' 2>/dev/null | head -1); pid=${pid:--}

  # `aconnect -l` is the only view that shows subscriptions; /proc/asound/seq
  # shows ports but not who is connected to whom.
  local acon; acon=$(aconnect -l 2>/dev/null)
  seq=$(awk '/^client [0-9]+: .WINE/{gsub(":","",$2); print $2; exit}' <<<"$acon")
  seq=${seq:--}

  # A subscription shows up as "Connected From:" under the Wine input port.
  if [[ "$seq" != "-" ]] &&
     awk -v c="client $seq:" '$0~c{f=1;next} /^client /{f=0} f&&/Connect(ed From|ing To)/{found=1} END{exit !found}' <<<"$acon"
  then sub=yes; else sub=no; fi

  [[ -n "$CARD_MIDI" && -r "$CARD_MIDI" ]] || CARD_MIDI=$(find_midi)
  if [[ -n "$CARD_MIDI" && -r "$CARD_MIDI" ]]; then
    tx=$(awk '/Tx bytes/{print $NF; exit}' "$CARD_MIDI")
    rx=$(awk '/Rx bytes/{print $NF; exit}' "$CARD_MIDI")
  else tx=-; rx=-; fi

  # fuser is quiet and cheap; lsof would pull in the whole process table.
  hidraw=$(fuser /dev/hidraw0 2>/dev/null | wc -w)

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$seq" "$sub" "${tx:--}" "${rx:--}" "$hidraw"
}

printf '# time\tpid\tseq\tsub\ttx\trx\thidraw\n'
prev=""
end=$((SECONDS + DURATION))
while (( SECONDS < end )); do
  line=$(sample)
  if [[ "$line" != "$prev" ]]; then
    printf '%s\t%s\n' "$(date +%H:%M:%S)" "$line"
    prev="$line"
  fi
  sleep 1
done
