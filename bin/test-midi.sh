#!/usr/bin/env bash
# test-midi — ONE test, one question:
#
#     With laptop audio only, how much of the DDJ-400 actually works?
#
# WHERE THIS TEST CAME FROM
#
# Run 20260815T140305 settled the first question and it is not the one we thought.
# Launched exactly as your Plasma menu does — no MIDI rename — rekordbox NEVER
# BOUND the controller: Tx 0 -> 0 bytes, Rx 0 -> 0 bytes, zero ALSA subscriptions,
# for the whole run, with the DDJ's own audio stream confirmed closed so the
# result is pure MIDI. It is not "works then locks up". In that configuration it
# never starts. That reproduces T05 phase 9: rekordbox skips a MIDI port named
# "DDJ-400" outright, deciding on the STRING before it does any I/O.
#
# The only known way to make MIDI flow is to present the port under a different
# name, which routes rekordbox down its generic-controller path. This test does
# that and then asks the question that actually matters for you: with the factory
# DDJ-400 mapping loaded under that name, WHICH CONTROLS WORK?
#
# THE COST OF THE WORKAROUND, stated plainly: bound this way rekordbox does not
# recognise the device as Pioneer hardware. The toolbar MIDI and pad indicators
# stay greyed and there is no MIDI tab. That is expected here and is not a fault
# to report. What we are measuring is how much real function you get anyway.
#
# SCOPE. The DDJ-400 is not used for audio at all; the test declares itself
# INVALID if its audio stream ever opens. That removes the exclusive-mode WASAPI
# path, patches 0008/0010, PC MASTER OUT and the audio-teardown-re-sends-the-LED-
# init loop of T03 phase 12 — every one of which has previously produced
# something that looked like a MIDI fault and was not.
#
# NOT tested here, on purpose: frame rate, the T08 GPU-memory leak, hardware 3D.
# That is the next focus. The leak is real and will still cost you frames.
#
# HOW TO RUN
#   1. Plug the controller in FIRST and wait for its lights. rekordbox binds MIDI
#      once at startup and never re-binds (T05 phase 11).
#   2. ./bin/test-midi.sh              (add --real-name to re-run the control)
#   3. Work through the checklist it prints, typing one word per control group.
#   4. End by closing rekordbox from its File menu.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
PREFIX="${RBW_PREFIX:-$REPO/prefixes/rb7}"
EXE="$("$(dirname "${BASH_SOURCE[0]}")/rbexe.sh")"
APPDATA="$PREFIX/drive_c/users/$USER/AppData/Roaming/Pioneer/rekordbox6"
MAPDIR="$APPDATA/MidiMappings"
PORTNAME="Generic MIDI Controller"
export DISPLAY="${DISPLAY:-:0}"
STAMP="$(date +%Y%m%dT%H%M%S)"
DIR="$REPO/runs/MIDI/$STAMP"
mkdir -p "$DIR"

# DEFAULT IS NOW THE REAL DEVICE NAME. With the RBW-USBHCD driver patch
# installed, rekordbox's USB validation passes and it binds the DDJ-400 under its
# own name through the native djplay::MidiMapDDJ400 path -- measured: ALSA
# subscriptions both ways, Tx 202 / Rx 63 bytes, where the same configuration
# before the patch produced zero of everything. --rename re-runs the old generic
# workaround for comparison.
USE_RENAME=0
MODE=parity
case "${1:-}" in
  --rename)    USE_RENAME=1 ;;
  --real-name) USE_RENAME=0 ;;
  --jog-probe) MODE=jogprobe; USE_RENAME=1 ;;
  --trace)     MODE=trace ;;
esac

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s%s%s\n' "$BLD" "$*" "$OFF"; }
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '  %swarn%s  %s\n' "$YEL" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*"; }
ev()   { echo "$(date -Is) $*" >> "$DIR/events.log"; }

ddj_card() {
  local c
  for c in /proc/asound/card*/usbid; do
    [ "$(cat "$c" 2>/dev/null)" = "2b73:0026" ] && { dirname "$c"; return 0; }
  done
  return 1
}
rb_pid() {
  local w p=""
  w=$("$REPO/bin/damagefps" --list 2>/dev/null | awk '/rekordbox/{print $1; exit}')
  [ -n "$w" ] && p=$(xprop -id "$w" _NET_WM_PID 2>/dev/null | awk '{print $3}')
  [ -n "$p" ] || p=$(pgrep -x 'rekordbox.exe' 2>/dev/null | head -1)
  [ -n "$p" ] && { echo "$p"; return 0; } || return 1
}
# Count only rows that actually bind something. Comment lines, blank lines and
# the @file header are not function, and counting raw lines led me to report a
# "loss of 51 rows including the whole Browser section" that did not happen --
# the 18 rows that really differed were empty separators.
map_funcs() { tr -d '\r' < "$1" 2>/dev/null | grep -vE '^\s*#|^\s*$|^@file' | grep -c ','; }
map_names() { tr -d '\r' < "$1" 2>/dev/null | grep -vE '^\s*#|^\s*$|^@file' | cut -d, -f1 | sort -u; }

# ------------------------------------------------------------------ pre-flight
hdr "Pre-flight"
if pgrep -x 'rekordbox.exe' >/dev/null 2>&1; then
  bad "rekordbox is already running — close it from its File menu, then re-run."
  exit 1
fi
ok "no rekordbox running"

CARD=$(ddj_card) || {
  # "No ALSA card" has two very different causes and they need different action.
  # A wedged DDJ-400 still answers USB descriptor requests, so it appears in
  # lsusb while having failed SET_CONFIGURATION and having no sound card at all.
  # Telling the user to "plug it in" when it is already plugged in wastes their
  # time and hides a hardware fault.
  if lsusb 2>/dev/null | grep -qi '2b73:0026'; then
    bad "the DDJ-400 is on the USB bus but has NOT initialised — it is wedged."
    say ""
    say "        It answers descriptor requests, so lsusb lists it, but it has no"
    say "        ALSA card and will accept no MIDI. Check the kernel's view:"
    say "            dmesg | grep -i 'can.t set config'"
    say "        \"can't set config #1, error -110\" means the device timed out"
    say "        on SET_CONFIGURATION. That is device state, not software."
    say ""
    say "        UNPLUG it, wait 10 seconds so it loses power (it is bus"
    say "        powered), plug it straight into the laptop rather than a hub,"
    say "        wait for the startup light animation, then re-run this."
  else
    bad "the DDJ-400 is NOT attached."
    say  "        Plug it in now, wait for its lights, then re-run this script."
    say  "        rekordbox binds MIDI once at startup and never re-binds, so a"
    say  "        controller plugged in later cannot work (T05 phase 11)."
  fi
  exit 1
}
ok "DDJ-400 present at $CARD"

# HARDWARE PRECHECK — does the controller actually ACCEPT BYTES right now?
#
# This exists because I spent a session measuring software against a wedged
# device. The DDJ-400 can sit in a state where it still answers USB descriptor
# requests -- so lsusb lists it, HID reads its product string, and our own
# host-controller walk reports it correctly -- while refusing SET_CONFIGURATION
# ("usb 3-9: can't set config #1, error -110"). In that state it has no ALSA
# card, every MIDI write blocks forever, the rawmidi output buffer fills and
# never drains, and NOTHING lights up no matter what the software does.
#
# Presence is not health. The only honest test is to put a byte on the wire and
# watch the kernel's Tx counter move. 0xFE is Active Sensing: a single status
# byte that every MIDI device ignores, so it is safe to send to hardware in any
# state.
rbw_hw_ok=1
if [ ! -r "$CARD/midi0" ]; then
  bad "the controller has no rawmidi node — it enumerated but did not initialise"
  rbw_hw_ok=0
else
  cardnum="${CARD##*card}"
  tx0=$(awk '/Tx bytes/{print $NF}' "$CARD/midi0" 2>/dev/null)
  timeout 3 amidi -p "hw:${cardnum},0,0" -S 'FE' >/dev/null 2>&1
  sleep 0.5
  tx1=$(awk '/Tx bytes/{print $NF}' "$CARD/midi0" 2>/dev/null)
  if [ "${tx0:-0}" = "${tx1:-0}" ]; then
    bad "the controller accepted NO bytes — Tx stayed at ${tx0:-?}"
    rbw_hw_ok=0
  else
    ok "wire check passed — the controller accepted bytes (Tx ${tx0} -> ${tx1})"
  fi
fi

if [ "$rbw_hw_ok" = 0 ]; then
  say ""
  say "  ${BLD}The controller is wedged. This is hardware state, not software.${OFF}"
  say "  It still answers USB descriptor requests, which is why it appears in"
  say "  lsusb and in the audio device list, but it will not accept MIDI and"
  say "  nothing will light up. No software change can be tested in this state."
  say ""
  say "  ${BLD}Fix it physically:${OFF}"
  say "    1. UNPLUG the DDJ-400 from USB completely."
  say "    2. Wait 10 seconds. It is bus powered, so this removes its power."
  say "    3. Plug it back in, ideally straight into the laptop, not via a hub."
  say "    4. Wait for its startup light animation, then re-run this script."
  say ""
  say "  Check the kernel agrees it came back healthy:"
  say "    dmesg | tail -5      # must NOT say \"can't set config\""
  say "    cat /proc/asound/cards   # the DDJ-400 must be listed"
  exit 1
fi
[ -e /dev/ntsync ] && ok "/dev/ntsync loaded" || warn "/dev/ntsync ABSENT — the UI will be laggy"
"$REPO/bin/rbclean.sh" --quiet >/dev/null 2>&1 && ok "prefix clean" || warn "cleandown reported a problem"
[ -x "$REPO/bin/damagefps" ] || cc -O2 -o "$REPO/bin/damagefps" "$REPO/bin/damagefps.c" \
  -lXdamage -lXfixes -lXext -lX11 2>/dev/null
dmesg 2>/dev/null | tail -40 > "$DIR/dmesg-before.log"

# ---------------------------------------------------- the mapping under test
FACTORY="$MAPDIR/DDJ-400.midi.csv"
TARGET="$MAPDIR/$PORTNAME.midi.csv"
if [ "$USE_RENAME" = 1 ]; then
  if [ ! -f "$FACTORY" ]; then
    bad "the factory mapping $FACTORY is missing — cannot test parity without it"
    exit 1
  fi
  # rekordbox loads the mapping whose FILENAME matches the port name it sees, and
  # the @file header line must name it too. Build it from the factory profile so
  # every run starts from the same 209-row baseline rather than from whatever the
  # previous run left behind.
  before_funcs=$(map_funcs "$TARGET")
  sed "1s/.*/@file,1,$PORTNAME\r/" "$FACTORY" > "$TARGET.new" && mv -f "$TARGET.new" "$TARGET"
  ok "mapping rebuilt from the factory profile: $(map_funcs "$TARGET") bindings"
  [ -n "$before_funcs" ] && [ "$before_funcs" != "0" ] && \
    say "        (previous file had $before_funcs; it is replaced so runs are comparable)"
  # THE JOG PROBE. Run 20260815T152846 showed the jog wheels sending 7,119 bytes
  # while you turned them and rekordbox doing nothing with any of it -- so the
  # data arrives and is ignored. The jog rows differ from the working Browse row
  # in exactly one field, the TYPE: Browse is `Rotary`, jog is `JogRotate`.
  #
  #   Browse,Browse,Rotary,B640,...          <- works
  #   JogPitchBend,JogPitchBend,JogRotate,B023,...  <- ignored
  #
  # So point the Browse function at the jog's CC. If turning the jog then scrolls
  # the library, the jog's MIDI is fine and it is the JogRotate/JogTouch TYPES
  # that rekordbox's generic path does not implement. If nothing happens, that CC
  # is not reaching the engine at all, which is a different and more tractable
  # problem. One variable, and it cannot be argued with either way.
  if [ "$MODE" = jogprobe ]; then
    sed -i 's/^Browse,Browse,Rotary,B640,/Browse,Browse,Rotary,B023,/' "$TARGET"
    if grep -q '^Browse,Browse,Rotary,B023,' "$TARGET"; then
      ok "JOG PROBE: the Browse function is now driven by the jog wheel's CC (B023)"
      warn "the browse knob will NOT scroll in this run — that is the swap, not a fault"
    else
      bad "could not repoint the Browse row — probe not applied"; exit 1
    fi
  fi
  cp "$TARGET" "$DIR/mapping-before.csv"
fi

MIDI_NAME=$(aconnect -l 2>/dev/null | sed -n "s/^client [0-9]*: '\(.*DDJ.*\)'.*/\1/p" | head -1)
ok "ALSA offers the controller as: ${MIDI_NAME:-<none>}"
if [ "$USE_RENAME" = 1 ]; then
  ok "Wine will present it to rekordbox as: $PORTNAME"
else
  ok "presenting it under its REAL name — the native Pioneer path"
  say "        This needs the RBW-USBHCD driver patch installed, or rekordbox's"
  say "        USB validation fails and it binds nothing at all."
fi
{
  echo "started:   $(date -Is)"
  echo "card:      $CARD"
  echo "alsa seq:  ${MIDI_NAME:-none}"
  echo "presented: $([ "$USE_RENAME" = 1 ] && echo "$PORTNAME (renamed)" || echo "real name")"
  echo "wine:      $(wine --version 2>/dev/null)"
} > "$DIR/meta.txt"

# ---------------------------------------------------------------------- launch
hdr "Launching rekordbox"
# rekordbox imports OutputDebugStringW and narrates its own device state machine
# through it -- "### HID:Other:[%s] open wait for start midi.",
# "### MIDI:%s.midi.csv is not found.", "### MIDI:open error [%s]" and so on.
# WINEDEBUG=+debugstr captures exactly those calls and nothing else, so it is
# cheap. This is the application stating its own reason for stopping, which beats
# any amount of inference from the outside.
WDEBUG="-all"
[ "$MODE" = trace ] && WDEBUG="+debugstr"
if [ "$USE_RENAME" = 1 ]; then
  ( cd "$REPO" && setsid env WINEPREFIX="$PREFIX" WINEDLLOVERRIDES=dxgi=n WINEDEBUG="$WDEBUG" \
      RBW_MIDI_RENAME="$PORTNAME" wine "$EXE" > "$DIR/wine.log" 2>&1 & )
else
  ( cd "$REPO" && setsid env WINEPREFIX="$PREFIX" WINEDLLOVERRIDES=dxgi=n WINEDEBUG="$WDEBUG" \
      wine "$EXE" > "$DIR/wine.log" 2>&1 & )
fi

WIN=""
for _ in $(seq 1 40); do
  WIN=$("$REPO/bin/damagefps" --list 2>/dev/null | awk '/rekordbox/{print $1; exit}')
  [ -n "$WIN" ] && break
  sleep 3
done
[ -n "$WIN" ] || { bad "no window after 120s — see $DIR/wine.log"; exit 1; }
RB=$(rb_pid) || { bad "cannot find the rekordbox pid"; exit 1; }
ok "window $WIN, pid $RB"
ev "EVENT launched pid=$RB window=$WIN rename=$USE_RENAME"

# ------------------------------------------------------------------- sampler
(
  printf 'iso\telapsed\ttx\trx\tsub_to\tsub_from\tddj_pcm\tthreads\trb_cpu\n' > "$DIR/sample.tsv"
  t0=$(date +%s); hz=$(getconf CLK_TCK)
  ltx=""; lrx=""; lsub=""; lpcm=""; lcard="$CARD"; bound=0
  txc=0; rxc=0; txf=0; rxf=0; pt=0; pw=0
  while kill -0 "$RB" 2>/dev/null; do
    now=$(date +%s); el=$((now - t0))
    d=$(ddj_card) || d=""
    if [ -n "$d" ]; then
      tx=$(awk '/Tx bytes/{print $NF}' "$d/midi0" 2>/dev/null)
      rx=$(awk '/Rx bytes/{print $NF}' "$d/midi0" 2>/dev/null)
      pcm=$(head -1 "$d/pcm0p/sub0/status" 2>/dev/null | awk '{print $2}'); [ -z "$pcm" ] && pcm=closed
    else tx=""; rx=""; pcm="-"; fi
    read -r sto sfrom <<<"$(aconnect -l 2>/dev/null | awk '
      /^client/ { inblk = ($0 ~ /DDJ/) }
      inblk && /Connecting To:/ { t++ }
      inblk && /Connected From:/ { f++ }
      END { print t+0, f+0 }')"
    thr=$(ls "/proc/$RB/task" 2>/dev/null | wc -l)
    tk=$(awk '{print $14+$15}' "/proc/$RB/stat" 2>/dev/null)
    if [ -n "$tk" ] && [ "$pw" -gt 0 ] && [ "$now" -gt "$pw" ]; then
      cpu=$(( (tk - pt) * 100 / hz / (now - pw) )); else cpu=""; fi
    pt=${tk:-0}; pw=$now

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -Is)" "$el" \
      "${tx:-}" "${rx:-}" "$sto" "$sfrom" "$pcm" "$thr" "${cpu:-}" >> "$DIR/sample.tsv"

    [ -z "$d" ] && [ -n "$lcard" ] && { ev "EVENT device-DISAPPEARED"; lcard=""; }
    [ -n "$d" ] && [ -z "$lcard" ] && { ev "EVENT device-REAPPEARED at $d"; lcard="$d"; }

    sub="$sto/$sfrom"
    if [ "$sub" != "$lsub" ]; then
      [ -n "$lsub" ] && ev "EVENT midi-subscriptions $lsub -> $sub (to/from)"
      [ "$bound" -eq 0 ] && [ "$sub" != "0/0" ] && { ev "EVENT MIDI-BOUND — rekordbox opened the port ($sub)"; bound=1; }
      lsub="$sub"
    fi
    if [ "$pcm" != "$lpcm" ]; then
      [ -n "$lpcm" ] && ev "EVENT ddj-pcm $lpcm -> $pcm"
      [ "$pcm" != closed ] && [ "$pcm" != "-" ] && \
        ev "EVENT ddj-audio-OPEN (pcm=$pcm) — expected at startup because the DDJ is your saved device; switch to laptop audio in Preferences"
      lpcm="$pcm"
    fi
    # Only meaningful once something has flowed; a counter that was always zero
    # is "never bound", not "stalled", and the report distinguishes them.
    if [ -n "$tx" ] && [ "$tx" != 0 ]; then
      if [ "$tx" != "$ltx" ]; then
        [ "$txf" -eq 1 ] && ev "EVENT midi-TX-RESUMED at $tx bytes"; txc=$now; txf=0
      elif [ "$txf" -eq 0 ] && [ "$txc" -gt 0 ] && [ $((now - txc)) -ge 5 ]; then
        ev "EVENT midi-TX-STALLED at $tx bytes — rekordbox has stopped SENDING"; txf=1
      fi
    fi
    if [ -n "$rx" ] && [ "$rx" != 0 ]; then
      if [ "$rx" != "$lrx" ]; then
        [ "$rxf" -eq 1 ] && ev "EVENT midi-RX-RESUMED at $rx bytes"; rxc=$now; rxf=0
      elif [ "$rxf" -eq 0 ] && [ "$rxc" -gt 0 ] && [ $((now - rxc)) -ge 5 ]; then
        ev "EVENT midi-RX-STALLED at $rx bytes — nothing being READ from the controller"; rxf=1
      fi
    fi
    ltx="$tx"; lrx="$rx"
    sleep 0.5
  done
  ev "EVENT app-exited"
) &
SAMPLER=$!
ok "sampling -> $DIR/events.log"

NARRATOR=""
if [ "$MODE" = trace ]; then
  ( tail -F "$DIR/wine.log" 2>/dev/null | grep --line-buffered -oE '###[^"]*' \
      | while IFS= read -r line; do
          [ "$line" = "$lastline" ] && continue
          lastline="$line"
          echo "$(date -Is) SAYS $line" >> "$DIR/events.log"
        done ) &
  NARRATOR=$!
  ok "rekordbox's own state messages -> events.log (lines beginning SAYS)"
fi

# Snoop the raw MIDI in parallel. The ALSA sequencer fans a source port out to
# every subscriber, so this sees exactly what rekordbox sees and steals nothing.
SEQPORT=$(aconnect -l 2>/dev/null | awk '/^client [0-9]+: .DDJ/{gsub(":","",$2); c=$2} c && /^ +[0-9]+ /{print c":"$1; exit}')
SNOOP=""
if [ -n "$SEQPORT" ]; then
  ( aseqdump -p "$SEQPORT" > "$DIR/midi-raw.log" 2>&1 & )
  SNOOP=1
  ok "raw MIDI snoop on $SEQPORT -> $DIR/midi-raw.log"
else
  warn "could not find the DDJ sequencer port — no raw MIDI capture this run"
fi

# ------------------------------------------------------------------ the script
cat <<EOF

${BLD}YOUR SCRIPT${OFF}

  1. ${BLD}Preferences > Audio${OFF}: audio device = your LAPTOP audio, NOT the DDJ-400.
     The test invalidates itself if the DDJ's audio stream opens.   type: ${BLD}audio-set${OFF}

  2. Load a track and play it through the laptop speakers.          type: ${BLD}playing${OFF}

  3. ${BLD}Now work through the controller, group by group.${OFF} After each, type the
     word if it WORKS, or the word with -bad if it does not. Skip anything
     you do not care about.

       ${BLD}jog${OFF}        jog wheels — scratch and pitch bend
       ${BLD}tempo${OFF}      tempo / pitch faders
       ${BLD}faders${OFF}     channel faders and crossfader
       ${BLD}eq${OFF}         EQ and trim knobs
       ${BLD}transport${OFF}  play / pause / cue
       ${BLD}pads${OFF}       performance pads (hot cue, beat loop, sampler)
       ${BLD}browse${OFF}     browse rotary, load buttons
       ${BLD}shift${OFF}      shift modifier changes what a control does
       ${BLD}fx${OFF}         beat FX
       ${BLD}leds${OFF}       LEDs light in response to the app (output direction)

     e.g.   ${BLD}jog${OFF}      (works)        ${BLD}pads-bad${OFF}   (does not)

  4. If everything dies at once mid-session:                        type: ${BLD}locked${OFF}
     then leave it alone ~60s so the stall picture is clean.

  ${BLD}End by closing rekordbox from its File menu.${OFF}

'help' lists the words. 'stacks' dumps thread stacks (freezes the app ~5s).

EOF

# ------------------------------------------------------------- report + prompt
finish() {
  hdr "Writing report"
  local lost=""
  if [ "$USE_RENAME" = 1 ] && [ -f "$TARGET" ]; then
    cp "$TARGET" "$DIR/mapping-after.csv"
    lost=$(comm -23 <(map_names "$DIR/mapping-before.csv") <(map_names "$DIR/mapping-after.csv") | tr '\n' ' ')
  fi
  {
    echo "=== test-midi $STAMP ==="
    cat "$DIR/meta.txt"
    echo
    echo "-- what you reported --"
    grep MARK "$DIR/events.log" 2>/dev/null | sed 's/.*MARK /  /' || echo "  (none)"
    echo
    echo "-- what the harness saw --"
    grep EVENT "$DIR/events.log" 2>/dev/null | sed 's/.*EVENT /  /' || echo "  (none)"
    echo
    echo "-- did the controller bind? --"
    awk -F'\t' 'NR>1 && ($5>0 || $6>0){n++} END{
      if(n) printf "  YES — subscribed in %d samples\n", n
      else  print  "  NO — rekordbox never opened the port" }' "$DIR/sample.tsv"
    echo
    echo "-- MIDI traffic --"
    awk -F'\t' 'NR>1 && $3!="" { if(ft==""){ft=$3; fr=$4} lt=$3; lr=$4 }
      END { if(ft=="") print "  counters never readable"
            else { printf "  Tx %s -> %s  (%+d bytes out to the controller)\n", ft,lt,lt-ft
                   printf "  Rx %s -> %s  (%+d bytes in from the controller)\n", fr,lr,lr-fr
                   if (lt-ft==0 && lr-fr==0) print "  => NOTHING FLOWED IN EITHER DIRECTION"
                   else if (lr-fr==0) print "  => rekordbox sent, the controller never replied (device/USB side)"
                   else if (lt-ft==0) print "  => the controller reported, rekordbox never sent (app/Wine side)" } }' \
      "$DIR/sample.tsv"
    echo
    echo "-- was the DDJ used for audio (it must not be) --"
    # Your saved audio device is the DDJ-400, so rekordbox grabs it at startup
    # before you can possibly have changed it. Counting that as INVALID would
    # fail every run on principle. What matters is whether it is still open
    # AFTER you switch to laptop audio and mark it, so the check starts there.
    aset=$(grep 'MARK audio-set' "$DIR/events.log" 2>/dev/null | head -1 | cut -d' ' -f1)
    if [ -z "$aset" ]; then
      echo "  UNKNOWN — you never marked 'audio-set', so I cannot tell when the"
      echo "  switch happened. Mark it next time or this run cannot be scored."
    else
      awk -F'\t' -v t="$aset" 'NR>1 && $1>t { tot++; if($7!="closed" && $7!="-") n++ }
        END{ if(tot==0) print "  no samples after audio-set"
             else if(n) printf "  INVALID: DDJ audio still open in %d of %d samples after audio-set\n", n, tot
             else printf "  good — DDJ audio closed for all %d samples after audio-set\n", tot }' "$DIR/sample.tsv"
      awk -F'\t' -v t="$aset" 'NR>1 && $1<=t && $7!="closed" && $7!="-" {n++}
        END{ if(n) printf "  (it was open in %d samples BEFORE the switch — expected, that is your saved device)\n", n }' "$DIR/sample.tsv"
    fi
    if [ "$USE_RENAME" = 1 ]; then
      echo
      echo "-- did rekordbox rewrite the mapping? --"
      echo "  bindings before: $(map_funcs "$DIR/mapping-before.csv")   after: $(map_funcs "$DIR/mapping-after.csv" 2>/dev/null)"
      [ -n "${lost// /}" ] && echo "  FUNCTIONS LOST: $lost" || echo "  no function lost"
    fi
    if grep -q ' SAYS ' "$DIR/events.log" 2>/dev/null; then
      echo
      echo "-- what REKORDBOX said about itself (its own state machine) --"
      grep ' SAYS ' "$DIR/events.log" | sed 's/.* SAYS /  /' | uniq -c | sed 's/^ *\([0-9]*\) /  [x\1] /'
    fi
    if [ -s "$DIR/midi-raw.log" ]; then
      echo
      echo "-- what the controller actually SENT (raw MIDI, by message) --"
      awk 'NR>1 && NF>2 {
             typ=""; for(i=3;i<=NF;i++){ if($i ~ /^[A-Za-z]/){ typ=typ (typ?" ":"") $i } else break }
             key=typ; if ($0 ~ /controller/) { for(i=1;i<=NF;i++) if($i=="controller"){ key=typ" #"$(i+1); break } }
             c[key]++ }
           END { for (k in c) printf "  %-34s %d messages\n", k, c[k] }' "$DIR/midi-raw.log" \
        | sort -k2 -rn | head -20
      echo "  (full capture: $DIR/midi-raw.log)"
    fi
    echo
    echo "-- new kernel USB messages --"
    dmesg 2>/dev/null | tail -60 > "$DIR/dmesg-after.log"
    diff "$DIR/dmesg-before.log" "$DIR/dmesg-after.log" 2>/dev/null | grep '^>' | sed 's/^> /  /' \
      | grep -iE 'usb|snd|midi' || echo "  (none)"
    echo
    echo "full series: $DIR/sample.tsv"
  } > "$DIR/report.txt" 2>&1
  cat "$DIR/report.txt"
  say ""; ok "report: $DIR/report.txt"
}

need_prompt=1
while :; do
  if ! kill -0 "$RB" 2>/dev/null; then
    say ""; ok "rekordbox closed — test complete"; break
  fi
  [ "$need_prompt" -eq 1 ] && { printf 'marker> '; need_prompt=0; }
  if read -r -t 2 word; then
    need_prompt=1
    case "${word:-}" in
      "") ;;
      help)
        say "  audio-set playing locked recovered"
        say "  jog tempo faders eq transport pads browse shift fx leds   (add -bad if broken)"
        say "  stacks   thread stacks (freezes ~5s)      quit   end without closing rekordbox" ;;
      stacks)
        warn "freezing rekordbox for a few seconds"; ev "MARK stacks-start"
        { echo "=== $(date -Is) ==="; sudo eu-stack -p "$RB" 2>&1 | head -300
          echo "=== threads by wchan ==="
          for t in /proc/$RB/task/*; do cat "$t/wchan" 2>/dev/null; echo; done \
            | sort | uniq -c | sort -rn | head -15
        } >> "$DIR/stacks.txt" 2>&1
        ev "MARK stacks-done"; ok "appended to $DIR/stacks.txt" ;;
      quit) break ;;
      *) ev "MARK $word"; ok "noted: $word" ;;
    esac
  fi
done

kill "$SAMPLER" 2>/dev/null
[ -n "$NARRATOR" ] && kill "$NARRATOR" 2>/dev/null
pkill -f "aseqdump -p $SEQPORT" 2>/dev/null
finish
