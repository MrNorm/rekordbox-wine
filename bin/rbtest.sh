#!/usr/bin/env bash
# rbtest — controlled, one-variable-at-a-time reproduction of the controller
#          lockup, the replug failure, and the audio-device frame-rate effect.
#
# THIS IS A TWO-PERSON INSTRUMENT. You drive rekordbox and the controller; the
# harness samples everything that can be read without touching the app, and you
# timestamp what only a human can see with `m`. Nothing here clicks, types or
# sends input into rekordbox: this is your session, not the harness's.
#
# WHAT IT SAMPLES, twice a second, without perturbing anything
#   MIDI Tx/Rx bytes   from /proc/asound/<card>/midi0 — separates "rekordbox
#                      stopped sending" from "the controller stopped replying"
#                      from "both stopped", which no amount of watching can
#   ALSA subscriptions both directions, so a lost binding is visible
#   PCM state/pointers appl_ptr, hw_ptr, xruns — an audio teardown re-sends the
#                      controller LED init, which in phase 12 looked exactly
#                      like a MIDI fault and was not one
#   threads + wchan    a thread that stops advancing while parked on a futex is
#                      what a threadlock looks like from outside the process
#   fps + jitter       so "the frame rate is better on another audio device"
#                      becomes a number instead of an impression
#   GPU memory         the T08 leak is still open; this proves whether it is
#                      confounding a given run or not
#   dmesg USB lines    for the replug run
#
# It emits an EVENT only when something CHANGES, so the log is readable and the
# watcher is not flooded by two samples a second of nothing happening.
#
# USAGE — one command to start, markers as things happen, then close rekordbox
#
#   bin/rbtest.sh run0            ground truth. Launches nothing. Do this first.
#   bin/rbtest.sh run1            YOUR configuration: DDJ-400 audio + DDJ MIDI
#   bin/rbtest.sh run2            system audio device, DDJ still connected
#   bin/rbtest.sh run3            replug DURING the session
#   bin/rbtest.sh run4            same as run1 but with the MIDI port renamed
#
#   bin/rbtest.sh m <word>        mark the moment something happened
#   bin/rbtest.sh stacks          freeze the app ~5s and dump thread stacks
#   bin/rbtest.sh status          what is running, where the log is
#
# END A RUN by closing rekordbox from its own File menu. The harness notices,
# writes the report and stops. Do not kill it — a clean exit is also a data
# point (it flushes the settings file).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO="$PWD"
PREFIX="${RBW_PREFIX:-$REPO/prefixes/rb7}"
EXE="$("$(dirname "${BASH_SOURCE[0]}")/rbexe.sh")"
ROOT="$REPO/runs/RBTEST"
CUR="$ROOT/.current"
mkdir -p "$ROOT"
export DISPLAY="${DISPLAY:-:0}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n%s%s%s\n' "$BLD" "$*" "$OFF"; }
ok()   { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$*"; }
warn() { printf '  %swarn%s  %s\n' "$YEL" "$OFF" "$*"; }
bad()  { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$*"; }

# ---------------------------------------------------------------- discovery
# The card NUMBER changes on replug, so never cache it — that is the whole point
# of run3. Always resolve by USB id.
ddj_card() {
  local c
  for c in /proc/asound/card*/usbid; do
    [ "$(cat "$c" 2>/dev/null)" = "2b73:0026" ] && { dirname "$c"; return 0; }
  done
  return 1
}
rb_pid() {
  local w p
  w=$("$REPO/bin/damagefps" --list 2>/dev/null | awk '/rekordbox/{print $1; exit}')
  if [ -n "$w" ]; then
    p=$(xprop -id "$w" _NET_WM_PID 2>/dev/null | awk '{print $3}')
    [ -n "$p" ] && { echo "$p"; return 0; }
  fi
  # `pgrep -f rekordbox.exe` also matches any shell whose command line mentions
  # the exe, which is how a GPU sample once read the harness's own bash. -x
  # matches the process name exactly.
  p=$(pgrep -x 'rekordbox.exe' 2>/dev/null | head -1)
  [ -n "$p" ] && { echo "$p"; return 0; }
  return 1
}
rb_window() { "$REPO/bin/damagefps" --list 2>/dev/null | awk '/rekordbox/{print $1; exit}'; }
# ONE grep over every fdinfo, not one awk per fd. The per-fd version spawned
# ~800 processes per call and stretched the sampling loop from 0.5 s to 2 s --
# measured in a dry run: 6 samples in 12 seconds instead of 24. A sampler whose
# period silently quadruples makes every time-based threshold in it wrong.
gpu_mb() {
  local v
  [ -n "${1:-}" ] || { echo ""; return; }
  v=$(grep -h '^drm-total-system0:' /proc/$1/fdinfo/* 2>/dev/null | awk '{print $2}' | sort -rn | head -1)
  [ -n "$v" ] && [ "$v" -gt 0 ] && echo $((v/1024)) || echo ""
}
subs() { # "in:N out:M" — how many sequencer connections the DDJ has, each way
  local d="$1" ci
  ci=$(awk '/client /{print $2}' "$d/../seq/clients" 2>/dev/null | head -1)
  aconnect -l 2>/dev/null | awk '
    /^client/ { inblk = ($0 ~ /DDJ/) }
    inblk && /Connecting To:/ { to++ }
    inblk && /Connected From:/ { from++ }
    END { printf "to:%d from:%d", to+0, from+0 }'
}

# ---------------------------------------------------------------- the sampler
# Runs in the background for the life of the run. Prints an event line ONLY when
# something changes; the full series goes to sample.tsv regardless.
_sample() {
  local dir="$1" rb="$2" win="$3"
  local tsv="$dir/sample.tsv"
  printf 'iso\telapsed\tmidi_tx\tmidi_rx\tpcm_state\tappl_ptr\thw_ptr\tsubs\tthreads\trb_cpu\tgpu_mb\tcard\n' > "$tsv"

  local t0 last_tx="" last_rx="" last_state="" last_subs="" last_card="" last_thr=""
  # Wall-clock, never cycle counts: the loop period is not a constant and a
  # threshold expressed in cycles silently changes meaning when it drifts.
  local tx_changed=0 rx_changed=0 tx_flagged=0 rx_flagged=0 hz
  local next_gpu=0 next_fps=0 gm=""
  hz=$(getconf CLK_TCK)
  t0=$(date +%s)
  local prev_ticks=0 prev_when=0

  while :; do
    # The run ends when rekordbox exits. That is the agreed end-of-test signal.
    if ! kill -0 "$rb" 2>/dev/null; then
      echo "$(date -Is) EVENT app-exited — rekordbox closed, run complete"
      break
    fi

    local d tx rx st ap hp sb thr cpu card now el
    now=$(date +%s); el=$((now - t0))
    d=$(ddj_card) && card="${d##*/}" || card="ABSENT"
    if [ "$card" != ABSENT ]; then
      tx=$(awk '/Tx bytes/{print $NF}' "$d/midi0" 2>/dev/null)
      rx=$(awk '/Rx bytes/{print $NF}' "$d/midi0" 2>/dev/null)
      st=$(head -1 "$d/pcm0p/sub0/status" 2>/dev/null | awk '{print $2}')
      ap=$(awk '/appl_ptr/{print $2}' "$d/pcm0p/sub0/status" 2>/dev/null)
      hp=$(awk '/hw_ptr/{print $2}' "$d/pcm0p/sub0/status" 2>/dev/null)
      sb=$(subs "$d")
    else
      tx=""; rx=""; st="-"; ap=""; hp=""; sb="to:0 from:0"
    fi
    thr=$(ls "/proc/$rb/task" 2>/dev/null | wc -l)
    local ticks
    ticks=$(awk '{print $14+$15}' "/proc/$rb/stat" 2>/dev/null)
    if [ -n "$ticks" ] && [ "$prev_when" -gt 0 ] && [ "$now" -gt "$prev_when" ]; then
      cpu=$(( (ticks - prev_ticks) * 100 / hz / (now - prev_when) ))
    else cpu=""; fi
    prev_ticks=${ticks:-0}; prev_when=$now
    if [ "$now" -ge "$next_gpu" ]; then gm=$(gpu_mb "$rb"); next_gpu=$((now + 10)); fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -Is)" "$el" "${tx:-}" "${rx:-}" "${st:-}" "${ap:-}" "${hp:-}" \
      "$sb" "$thr" "${cpu:-}" "${gm:-}" "$card" >> "$tsv"

    # ---- change-only events -------------------------------------------------
    [ "$card" != "$last_card" ] && [ -n "$last_card" ] && \
      echo "$(date -Is) EVENT device $last_card -> $card"
    [ "$sb" != "$last_subs" ] && [ -n "$last_subs" ] && \
      echo "$(date -Is) EVENT midi-subscriptions $last_subs -> $sb"
    [ "$st" != "$last_state" ] && [ -n "$last_state" ] && \
      echo "$(date -Is) EVENT pcm-state $last_state -> $st"
    [ -n "$last_thr" ] && [ "$thr" -ne "$last_thr" ] && \
      echo "$(date -Is) EVENT threads $last_thr -> $thr"

    # MIDI stall detection is the heart of this: 5 s of no change in a counter
    # that was moving is the objective signature of the reported lockup.
    if [ -n "$tx" ]; then
      if [ "$tx" != "$last_tx" ]; then
        [ "$tx_flagged" -eq 1 ] && echo "$(date -Is) EVENT midi-TX-RESUMED at $tx bytes"
        tx_changed=$now; tx_flagged=0
      elif [ "$tx_flagged" -eq 0 ] && [ "$tx_changed" -gt 0 ] && [ $((now - tx_changed)) -ge 5 ]; then
        echo "$(date -Is) EVENT midi-TX-STALLED at $tx bytes — rekordbox has stopped SENDING to the controller"
        tx_flagged=1
      fi
    fi
    if [ -n "$rx" ]; then
      if [ "$rx" != "$last_rx" ]; then
        [ "$rx_flagged" -eq 1 ] && echo "$(date -Is) EVENT midi-RX-RESUMED at $rx bytes"
        rx_changed=$now; rx_flagged=0
      elif [ "$rx_flagged" -eq 0 ] && [ "$rx_changed" -gt 0 ] && [ $((now - rx_changed)) -ge 5 ]; then
        echo "$(date -Is) EVENT midi-RX-STALLED at $rx bytes — nothing is being READ from the controller"
        rx_flagged=1
      fi
    fi

    last_tx="$tx"; last_rx="$rx"; last_state="$st"; last_subs="$sb"; last_card="$card"; last_thr="$thr"

    # fps on a wall-clock schedule; damagefps blocks for its 2 s window, so this
    # is deliberately infrequent enough not to distort the loop period.
    if [ -n "$win" ] && [ "$now" -ge "$next_fps" ]; then
      local f
      f=$("$REPO/bin/damagefps" "$win" 2 2>/dev/null | sed -n 's/.*fps=\([0-9.]*\).*/\1/p' | head -1)
      [ -n "$f" ] && echo "$el $f ${gm:-}" >> "$dir/fps.tsv"
      next_fps=$((now + 15))
    fi
    sleep 0.5
  done

  _report "$dir" "$rb"
}

# ---------------------------------------------------------------- the report
_report() {
  local dir="$1" rb="$2"
  {
    echo "=== rbtest report — $(basename "$dir") ==="
    echo
    echo "-- markers --"
    grep MARK "$dir/events.log" 2>/dev/null || echo "(none)"
    echo
    echo "-- events --"
    grep EVENT "$dir/events.log" 2>/dev/null || echo "(none)"
    echo
    echo "-- MIDI totals --"
    awk -F'\t' 'NR>1 && $3!=""{if(f==""){f=$3;g=$4} l=$3;m=$4} END{
      printf "  Tx %s -> %s   (%+d bytes)\n  Rx %s -> %s   (%+d bytes)\n", f,l,l-f, g,m,m-g}' \
      "$dir/sample.tsv" 2>/dev/null
    echo
    echo "-- frame rate --"
    if [ -s "$dir/fps.tsv" ]; then
      awk '{n++; s+=$2; if(min==""||$2<min)min=$2; if($2>max)max=$2}
           END{printf "  %d samples  mean %.1f  min %.1f  max %.1f\n", n, s/n, min, max}' "$dir/fps.tsv"
      echo "  first/last: $(head -1 "$dir/fps.tsv" | awk '{print $2}') -> $(tail -1 "$dir/fps.tsv" | awk '{print $2}') fps"
      echo "  gpu_mb:     $(head -1 "$dir/fps.tsv" | awk '{print $3}') -> $(tail -1 "$dir/fps.tsv" | awk '{print $3}') MB"
    else echo "  (none)"; fi
    echo
    echo "-- new USB kernel messages during the run --"
    dmesg 2>/dev/null | grep -iE 'usb|snd' | tail -25 | diff - "$dir/dmesg-before.log" 2>/dev/null \
      | grep '^<' | sed 's/^< /  /' || echo "  (none or unreadable)"
    echo
    echo "full series: $dir/sample.tsv"
  } > "$dir/report.txt" 2>&1
  echo "$(date -Is) EVENT report-written $dir/report.txt"
}

# ---------------------------------------------------------------- run control
_precheck() {
  local need_device="$1"
  hdr "Pre-flight"
  if pgrep -x 'rekordbox.exe' >/dev/null 2>&1; then
    bad "rekordbox is already running"
    say "        Close it from its own File menu first, then re-run this."
    say "        (A clean exit flushes its settings file; killing it truncates.)"
    return 1
  fi
  ok "no rekordbox running"

  if [ "$need_device" = yes ]; then
    if ! ddj_card >/dev/null; then
      bad "the DDJ-400 is NOT attached"
      say "        Plug it in NOW, wait for its lights, then re-run this command."
      say "        Rule from T05: plug in BEFORE starting rekordbox, never during —"
      say "        rekordbox binds MIDI once at startup and never re-binds."
      return 1
    fi
    ok "DDJ-400 present at $(ddj_card)"
  fi
  [ -e /dev/ntsync ] && ok "/dev/ntsync loaded" || warn "/dev/ntsync ABSENT — expect a laggy session"
  "$REPO/bin/rbclean.sh" --quiet >/dev/null 2>&1
  ok "prefix cleaned (no orphaned sessions)"
  return 0
}

_launch() {
  local dir="$1" label="$2"; shift 2
  local -a envs=("$@")

  mkdir -p "$dir"
  echo "$dir" > "$CUR"
  dmesg 2>/dev/null | grep -iE 'usb|snd' | tail -25 > "$dir/dmesg-before.log"
  {
    echo "run:        $label"
    echo "started:    $(date -Is)"
    echo "prefix:     $PREFIX"
    echo "env:        ${envs[*]}"
    echo "wine:       $(wine --version 2>/dev/null)"
    echo "device:     $(ddj_card || echo ABSENT)"
    echo "ntsync:     $([ -e /dev/ntsync ] && echo present || echo ABSENT)"
  } > "$dir/meta.txt"

  say ""
  say "launching rekordbox with: ${envs[*]}"
  ( cd "$REPO" && setsid env WINEPREFIX="$PREFIX" "${envs[@]}" \
      wine "$EXE" > "$dir/wine.log" 2>&1 & )
  local w="" rb="" i
  for i in $(seq 1 40); do
    w=$(rb_window); [ -n "$w" ] && break
    sleep 3
  done
  [ -n "$w" ] || { bad "no window after 120s — see $dir/wine.log"; return 1; }
  rb=$(rb_pid)
  ok "window $w, pid $rb"
  echo "window:     $w"  >> "$dir/meta.txt"
  echo "pid:        $rb" >> "$dir/meta.txt"

  ( _sample "$dir" "$rb" "$w" >> "$dir/events.log" 2>&1 & )
  sleep 1
  ok "sampling started -> $dir/events.log"
  return 0
}

_script() { # print the human script for a run
  hdr "YOUR SCRIPT — do these in order"
  cat
  say ""
  say "  Mark anything that happens:   ${BLD}bin/rbtest.sh m <word>${OFF}"
  say "  Suggested words: playing · locked · recovered · replugged · dead"
  say ""
  say "  ${BLD}END THE RUN by closing rekordbox from its File menu.${OFF}"
  say "  The harness notices, writes the report, and stops on its own."
}

# ---------------------------------------------------------------- commands
cmd_run0() {
  local dir="$ROOT/$(date +%Y%m%dT%H%M%S)-run0"; mkdir -p "$dir"; echo "$dir" > "$CUR"
  hdr "run0 — ground truth (nothing is launched, nothing is changed)"
  {
    echo "=== run0 $(date -Is) ==="
    echo "--- device ---"
    lsusb 2>/dev/null | grep -i 2b73 || echo "DDJ-400 NOT ATTACHED"
    ddj_card >/dev/null && echo "alsa card: $(ddj_card)" || echo "alsa card: none"
    echo "--- alsa sequencer clients ---"; aconnect -l 2>/dev/null | grep '^client'
    echo "--- ntsync ---"; [ -e /dev/ntsync ] && echo present || echo ABSENT
    echo "--- wine ---"; wine --version 2>/dev/null
    echo "--- prefix processes ---"; "$REPO/bin/rbclean.sh" --check 2>&1 | sed 's/\x1b\[[0-9;]*m//g'
    echo "--- dll overrides (read from user.reg, nothing is started) ---"
    grep -A6 'Software..Wine..DllOverrides' "$PREFIX/user.reg" 2>/dev/null | grep '^"'
    echo "--- audio driver ---"
    grep -A4 'Software..Wine..Drivers' "$PREFIX/user.reg" 2>/dev/null | grep '^"'
    echo "--- winealsa patch markers ---"
    strings -a /usr/lib/wine/x86_64-unix/winealsa.so 2>/dev/null | grep -o 'RBW-[A-Z]*' | sort -u | tr '\n' ' '; echo
    echo "--- app settings that matter ---"
    grep -oE '<VALUE name="(AudioBufferSize|MasterOutMode|DisableOpenGL|BasicOpenGL|UseVertexWave|DisableAdaptiveVsync|RenderDelay|WaveImageWidth2)" val="[^"]*"' \
      "$PREFIX/drive_c/users/$USER/AppData/Roaming/Pioneer/rekordbox6/rekordbox3.settings" 2>/dev/null
    echo "--- PC MASTER OUT target ---"
    cat "$PREFIX/drive_c/users/$USER/AppData/Roaming/Pioneer/rekordbox6/pcmasterout_device_v2.txt" 2>/dev/null
    echo "--- MIDI mapping files present ---"
    ls -la "$PREFIX/drive_c/users/$USER/AppData/Roaming/Pioneer/rekordbox6/MidiMappings/" 2>/dev/null | tail -n +2
    echo "--- settings file vs the backups left by earlier work ---"
    for b in rekordbox3.settings.rbw-backup rekordbox3.settings.preshared rekordbox3.settings.prebuffer; do
      f="$PREFIX/drive_c/users/$USER/AppData/Roaming/Pioneer/rekordbox6/$b"
      [ -f "$f" ] && echo "  $b: $(diff <(sort "$f") <(sort "${f%.*}") 2>/dev/null | grep -c '^[<>]') differing lines"
    done
  } | tee "$dir/ground-truth.txt"
  say ""
  ok "written to $dir/ground-truth.txt"
  say "Nothing was launched and nothing was changed. Send me this output."
}

cmd_run1() {
  _precheck yes || return 1
  local dir="$ROOT/$(date +%Y%m%dT%H%M%S)-run1"
  # EXACTLY the environment your Plasma menu entry uses — measured from your own
  # running instance: WINEDLLOVERRIDES=dxgi=n and no RBW_MIDI_RENAME. This run
  # must reproduce YOUR fault, not a lab configuration.
  _launch "$dir" run1 WINEDLLOVERRIDES=dxgi=n || return 1
  _script <<'EOF'
  1. Wait for the library to appear.
  2. In Preferences > Audio, confirm the audio device IS the DDJ-400. Close Preferences.
  3. Load a track and press play.       -> as soon as you hear audio:  m playing
  4. Now USE the controller: jog wheels, faders, pads, a cue point.
     Keep using it. The moment it stops responding:                    m locked
  5. If it starts working again:                                       m recovered
  6. Leave it running about 60s after the lockup so I get a clean stall picture.
  7. If I ask for stacks, run: bin/rbtest.sh stacks
EOF
}

cmd_run2() {
  _precheck yes || return 1
  local dir="$ROOT/$(date +%Y%m%dT%H%M%S)-run2"
  _launch "$dir" run2 WINEDLLOVERRIDES=dxgi=n || return 1
  _script <<'EOF'
  THE ONE VARIABLE: the audio device is NOT the DDJ-400 this time.
  1. Preferences > Audio > set the audio device to your built-in speakers
     (anything that is not the DDJ-400). Close Preferences.               m audio-switched
  2. Load a track and press play.        -> when you hear audio:          m playing
  3. Use the controller exactly as in run1: jogs, faders, pads, cues.
     If it locks up:                                                      m locked
     If it does NOT lock up, keep using it for a good 3 minutes, then:    m survived
EOF
}

cmd_run3() {
  _precheck yes || return 1
  local dir="$ROOT/$(date +%Y%m%dT%H%M%S)-run3"
  _launch "$dir" run3 WINEDLLOVERRIDES=dxgi=n || return 1
  _script <<'EOF'
  THE ONE VARIABLE: the controller is unplugged and replugged mid-session.
  1. Load a track, press play, confirm the controller works:              m playing
  2. UNPLUG the controller.                                               m unplugged
  3. Wait 10 seconds. Plug it back in.                                    m replugged
  4. Wait 20 seconds, then try the controller.
     If it does nothing (expected):                                       m dead
  5. Without restarting, open Preferences > Audio and look at the device
     list. Is the DDJ-400 in it?                                          m listed   (or)  m not-listed
EOF
}

cmd_run4() {
  _precheck yes || return 1
  local dir="$ROOT/$(date +%Y%m%dT%H%M%S)-run4"
  # THE ONE VARIABLE: the MIDI port is renamed, so rekordbox binds it as a
  # generic controller instead of recognising it as a DDJ-400. T05 records this
  # as diagnostic only and WORSE for real use — we are running it to find out
  # whether the lockup follows the Pioneer-specific path or happens either way.
  _launch "$dir" run4 WINEDLLOVERRIDES=dxgi=n "RBW_MIDI_RENAME=Generic MIDI Controller" || return 1
  _script <<'EOF'
  THE ONE VARIABLE: the MIDI port is renamed, so rekordbox treats the controller
  as a generic device rather than as a DDJ-400.
  1. Load a track and press play.        -> when you hear audio:          m playing
  2. Use the controller: jogs, faders, pads. Note the toolbar MIDI icon
     will be greyed — that is expected under a rename, not a fault.
     If it locks up:                                                      m locked
     If it survives 3 minutes of use:                                     m survived
EOF
}

cmd_m() {
  local dir; dir=$(cat "$CUR" 2>/dev/null)
  [ -n "$dir" ] && [ -d "$dir" ] || { bad "no run in progress"; return 1; }
  local word="${1:-mark}"
  echo "$(date -Is) MARK $word" >> "$dir/events.log"
  ok "marked: $word"
}

cmd_stacks() {
  local dir; dir=$(cat "$CUR" 2>/dev/null)
  local rb; rb=$(rb_pid) || { bad "rekordbox not running"; return 1; }
  warn "freezing rekordbox for a few seconds to capture stacks"
  echo "$(date -Is) MARK stacks-capture-start" >> "$dir/events.log"
  {
    echo "=== $(date -Is) unix-side stacks ==="
    sudo eu-stack -p "$rb" 2>&1 | head -400
    echo "=== per-thread wchan (what each thread is parked on) ==="
    for t in /proc/$rb/task/*; do
      printf '%s\t%s\t%s\n' "${t##*/}" "$(cat "$t/wchan" 2>/dev/null)" "$(awk '{print $14+$15}' "$t/stat" 2>/dev/null)"
    done | sort -k2 | awk '{c[$2]++} END{for(k in c) printf "  %-40s %d threads\n", k, c[k]}'
  } >> "$dir/stacks.txt" 2>&1
  echo "$(date -Is) MARK stacks-capture-done" >> "$dir/events.log"
  ok "appended to $dir/stacks.txt"
}

cmd_status() {
  local dir; dir=$(cat "$CUR" 2>/dev/null)
  hdr "rbtest status"
  rb_pid >/dev/null && ok "rekordbox running (pid $(rb_pid))" || warn "rekordbox not running"
  ddj_card >/dev/null && ok "DDJ-400 at $(ddj_card)" || warn "DDJ-400 not attached"
  [ -n "$dir" ] && say "  current run: $dir" || say "  no run recorded yet"
  [ -f "$dir/events.log" ] && { say "  last events:"; tail -5 "$dir/events.log" | sed 's/^/    /'; }
}

case "${1:-}" in
  run0)   cmd_run0 ;;
  run1)   cmd_run1 ;;
  run2)   cmd_run2 ;;
  run3)   cmd_run3 ;;
  run4)   cmd_run4 ;;
  m)      shift; cmd_m "${1:-mark}" ;;
  stacks) cmd_stacks ;;
  status) cmd_status ;;
  *) sed -n '2,46p' "$0"; exit 2 ;;
esac
