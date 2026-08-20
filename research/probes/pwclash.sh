#!/usr/bin/env bash
# pwclash — does one exclusive ALSA open cost PipeWire the device permanently?
#
# WHY THIS EXISTS. On 2026-08-17 at 15:26 this machine lost every audio sink it
# had — laptop speakers, HDMI and the DDJ — and did not get them back for the
# rest of the day. The system journal names the sequence: PipeWire's own
# `snd_pcm_open` returned EBUSY, each node went `suspended -> error`, and then
# WirePlumber's error handler threw a Lua exception (alsa.lua:425 concatenates
# `node.name`, which is nil for a node that never bound). The node is never
# stored and never retried. See docs/investigation/THEMES/T09.
#
# That reading blames Wine's exclusive-mode `hw:` opens for taking the device
# and blames WirePlumber for never recovering. Both halves need proving without
# Wine in the picture, because "we saw it in a log once" is not a finding.
#
# WHAT IT DOES. One variable: a plain `aplay -D hw:1,0` holds the DDJ's PCM
# while PipeWire is asked to start its own node on the same device.
#
#   1. assert the DDJ sink exists         (liveness control — a device that was
#                                          already missing proves nothing)
#   2. hold hw:1,0 with aplay, and VERIFY the hold took effect by reading
#      /proc/asound/card1/pcm0p/sub0/status, because a hold that silently
#      failed reads exactly like a system that tolerates the clash
#   3. ask PipeWire to play to that sink -> it must open a busy device
#   4. release the hold, wait, and ask again
#   5. report whether the sink came back BY ITSELF
#
# A device that returns on its own = ordinary contention, no bug.
# A device that stays gone until wireplumber restarts = the fault we saw.
#
# Restores the machine at the end unless --no-repair is given.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="runs/PWCLASH"; mkdir -p "$OUT"
STAMP=$(date +%Y%m%dT%H%M%S)
LOG="$OUT/$STAMP.log"
REPAIR=1; [ "${1:-}" = "--no-repair" ] && REPAIR=0

say() { echo "$*" | tee -a "$LOG"; }

ddj_sink() { pactl list short sinks 2>/dev/null | grep -i 'DDJ-400' | awk '{print $2}'; }
pcm_state() { awk '/^state:/{print $2; f=1} END{if(!f) print "closed"}' /proc/asound/card1/pcm0p/sub0/status 2>/dev/null; }

say "== pwclash $STAMP =="

S=$(ddj_sink)
if [ -z "$S" ]; then
  say "VOID: no DDJ sink present before the test — nothing to lose."
  say "      (run 'systemctl --user restart wireplumber' first)"
  exit 2
fi
say "  pre : DDJ sink present   -> $S"
say "  pre : hw:1,0 pcm state   -> $(pcm_state)"

CURSOR=$(journalctl --user -n0 --show-cursor 2>/dev/null | sed -n 's/^-- cursor: //p')

# --- step 2: take the device the way an exclusive-mode client does -----------
say
say "  holding hw:1,0 with aplay (the Wine-free stand-in for exclusive mode)"
aplay -D hw:1,0 -f S24_3LE -r 44100 -c 4 -t raw /dev/zero >>"$LOG" 2>&1 &
HOLD=$!
sleep 2
ST=$(pcm_state)
say "  hold: hw:1,0 pcm state   -> $ST"
case "$ST" in
  RUNNING|PREPARED|SETUP|OPEN|DRAINING)
    say "  hold: CONFIRMED — the device is genuinely busy" ;;
  *)
    kill $HOLD 2>/dev/null
    say "  FAULT: the hold did not take (state '$ST'). Aborting rather than"
    say "         reporting 'PipeWire coped fine' about a test that never ran."
    exit 2 ;;
esac

# --- step 3: make PipeWire open the same device ------------------------------
TONE="$OUT/tone.wav"
[ -s "$TONE" ] || python3 - "$TONE" <<'EOF'
import math, struct, sys, wave
w = wave.open(sys.argv[1], 'w'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
w.writeframes(b''.join(struct.pack('<hh', *(int(8000*math.sin(2*math.pi*440*n/44100)),)*2)
                       for n in range(44100)))
w.close()
EOF
say
say "  asking PipeWire to play to the DDJ sink while it is busy"
timeout 10 pw-play --target="$S" "$TONE" >>"$LOG" 2>&1
say "  pw-play rc=$?"
sleep 2
say "  during: DDJ sink -> $(ddj_sink | sed 's/^$/GONE/')"

# --- step 4: release, and see whether PipeWire recovers on its own -----------
kill $HOLD 2>/dev/null; wait $HOLD 2>/dev/null
say
say "  hold released; hw:1,0 pcm state -> $(pcm_state)"
sleep 3
say "  +3s : DDJ sink -> $(ddj_sink | sed 's/^$/GONE/')"
timeout 10 pw-play --target="$S" "$TONE" >/dev/null 2>&1
sleep 3
AFTER=$(ddj_sink)
say "  after a second play attempt: DDJ sink -> ${AFTER:-GONE}"

# --- what the system said about it -------------------------------------------
say
say "  journal during the test:"
journalctl --user --after-cursor "$CURSOR" --no-pager 2>/dev/null \
  | grep -E 'spa.alsa|pw.node|alsa.lua' | sed 's/^/    /' | tee -a "$LOG" | head -20

EBUSY=$(journalctl --user --after-cursor "$CURSOR" --no-pager 2>/dev/null | grep -c 'Device or resource busy')
LUA=$(journalctl --user --after-cursor "$CURSOR" --no-pager 2>/dev/null | grep -c 'alsa.lua')

say
say "== RESULT =="
say "  EBUSY lines from PipeWire : $EBUSY"
say "  wireplumber Lua faults    : $LUA"
if [ -n "$AFTER" ]; then
  say "  VERDICT: the sink SURVIVED (or recovered by itself). Ordinary"
  say "           contention — this is not the permanent-loss fault."
else
  say "  VERDICT: THE SINK IS GONE and did not come back on its own."
  say "           One exclusive open cost PipeWire the device permanently."
fi

if [ "$REPAIR" = 1 ]; then
  say
  say "  repairing: systemctl --user restart wireplumber"
  systemctl --user restart wireplumber; sleep 4
  say "  post: DDJ sink -> $(ddj_sink | sed 's/^$/STILL GONE — investigate/')"
  say "  post: default sink -> $(pactl get-default-sink 2>/dev/null)"
fi
say
say "  log: $LOG"
