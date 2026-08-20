#!/usr/bin/env bash
# stallscope — put every layer on ONE timeline, so a stall can be attributed.
#
# THE QUESTION. With PC MASTER OUT enabled the track plays, pauses for a long
# time, plays briefly, pauses again — and the UI freezes during the pause and is
# smooth during the playing. Three layers could each produce that and each would
# look identical from the outside:
#
#   MIDI   the controller stops being serviced        -> check the wire counters
#   AUDIO  a stream starves, or is torn down/reopened -> check both PCMs
#   UI/GPU the compositor or GL path blocks           -> check frame damage
#
# Sampling them separately is what has made this ambiguous before. This samples
# all of them at 5 Hz against one clock, plus WHERE rekordbox's threads are
# blocked in the kernel, so "audio paused and MIDI kept flowing" becomes a fact
# rather than an impression.
#
#   stallscope.sh [--secs N] [--label X]
#
# Read the TSV with:  stallscope.sh report <dir>
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECS=90; LABEL=stall
[ "${1:-}" = report ] && { REPORT="${2:?usage: stallscope.sh report <dir>}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --secs)  SECS="$2"; shift ;;
    --label) LABEL="$2"; shift ;;
    report)  shift; break ;;
    *) ;;
  esac; shift
done

# ---------------------------------------------------------------- readers
ddj_card() { for c in /proc/asound/card[0-9]*; do
    [ -r "$c/id" ] && [ "$(cat "$c/id")" = DDJ400 ] && basename "$c" && return; done; }

# A playback substream's state and pointers. "closed" is a real answer: it means
# nothing is streaming to that device at all.
pcm_state() {
    local f="$1/status"
    [ -r "$f" ] || { echo "absent"; return; }
    local st; st=$(awk '/^state:/{print $2}' "$f" 2>/dev/null)
    [ -z "$st" ] && { echo closed; return; }
    # "appl_ptr    : 418562" -- the colon is its own field, so the value is $3.
    local appl owner
    appl=$(awk '/^appl_ptr/{print $3}' "$f")
    owner=$(awk '/^owner_pid/{print $3}' "$f")
    echo "$st:${appl:-0}:${owner:-0}"
}

# This kernel's status has no xruns line; avail_max is the useful proxy for how
# close the stream came to running dry.
xruns() { awk '/^avail_max/{print $3}' "$1/status" 2>/dev/null || echo 0; }

# rekordbox's PC MASTER OUT does NOT appear as card0/pcm0p. That substream is
# owned by PipeWire (pid 1974) and advances continuously whether or not any
# application is feeding it -- an earlier version of this script sampled it and
# reported "PC audio moving" during a total silence, which was wrong. What
# matters is rekordbox's own PipeWire stream node, which appears as
# alsa_playback.wine-preloader. If rekordbox loses and reacquires the device,
# that node is destroyed and recreated and its id CHANGES, so the id is recorded
# too, not just the state.
pw_stream() {
    pw-dump 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("?"); raise SystemExit
out=[]
for o in d:
    info=o.get("info") or {}
    p=info.get("props") or {}
    if "wine-preloader" not in str(p.get("node.name","")): continue
    if p.get("media.class") != "Stream/Output/Audio": continue
    out.append(f"{o["id"]}={info.get("state")}")
print(",".join(out) if out else "none")
'
}

midi_tx() { awk '/^Output/{o=1} o&&/Tx bytes/{print $4; exit}' "$1" 2>/dev/null || echo -1; }
midi_rx() { awk '/^Input/{i=1} i&&/Rx bytes/{print $4; exit}' "$1" 2>/dev/null || echo -1; }

# Where are the app's threads stuck? Report the most common non-idle wait
# channel: a process blocked on a futex looks very different from one blocked in
# an ALSA ioctl or on the GPU.
hot_wchan() {
    local pid="$1" t w
    for t in /proc/$pid/task/*/wchan; do
        w=$(cat "$t" 2>/dev/null)
        case "$w" in ""|0|do_epoll_wait|futex_wait_queue|do_sigtimedwait|hrtimer_nanosleep|poll_schedule_timeout|do_select|pipe_read|schedule_timeout) continue ;; esac
        echo "$w"
    done | sort | uniq -c | sort -rn | head -1 | awk '{print $2"("$1")"}'
}

runnable() {  # threads actually on a CPU or waiting for one
    local pid="$1" n=0 s
    for t in /proc/$pid/task/*/stat; do
        s=$(awk '{print $3}' "$t" 2>/dev/null)
        [ "$s" = R ] || [ "$s" = D ] && n=$((n+1))
    done
    echo "$n"
}

# ---------------------------------------------------------------- report
if [ -n "${REPORT:-}" ]; then
    tsv="$REPORT/samples.tsv"
    [ -r "$tsv" ] || { echo "no samples.tsv in $REPORT" >&2; exit 1; }
    python3 - "$tsv" <<'PY'
import sys, csv
rows=list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
if not rows: sys.exit("no rows")
def num(r,k):
    try: return int(r[k])
    except: return 0
def appl(v):
    p=v.split(':')
    if len(p)>1 and p[1].isdigit(): return int(p[1])
    return -1
def owner(v):
    p=v.split(':')
    return p[2] if len(p)>2 else '-' 

print(f"{len(rows)} samples over {float(rows[-1]['t']):.1f}s\n")
prev=None; stalls=[]
for r in rows:
    if prev:
        d_ddj  = appl(r['ddj_pcm'])  - appl(prev['ddj_pcm'])
        d_pc   = appl(r['pc_pcm'])   - appl(prev['pc_pcm'])
        d_tx   = num(r,'midi_tx')    - num(prev,'midi_tx')
        d_rx   = num(r,'midi_rx')    - num(prev,'midi_rx')
        d_fr   = num(r,'frames')     - num(prev,'frames')
        r['_d']=(d_ddj,d_pc,d_tx,d_rx,d_fr)
    prev=r
body=[r for r in rows if '_d' in r]

# A stall = neither audio device advanced its application pointer.
for r in body:
    d_ddj,d_pc,d_tx,d_rx,d_fr = r['_d']
    if d_ddj<=0 and d_pc<=0: stalls.append(r)

print(f"AUDIO STALL SAMPLES: {len(stalls)} of {len(body)}")
if stalls:
    print("\nDuring the audio stalls, did the other layers keep going?")
    midi_alive = sum(1 for r in stalls if r['_d'][2]>0 or r['_d'][3]>0)
    ui_alive   = sum(1 for r in stalls if r['_d'][4]>0)
    print(f"  MIDI still moving : {midi_alive}/{len(stalls)} samples")
    print(f"  UI still painting : {ui_alive}/{len(stalls)} samples")
    print(f"  most common thread block during stalls: ", end='')
    from collections import Counter
    print(Counter(r['wchan'] for r in stalls).most_common(3))

print("\nTIMELINE  (. = both audio devices advancing, D = DDJ only, P = PC only, X = neither)")
line=''
for r in body:
    d_ddj,d_pc,_,_,_ = r['_d']
    line += '.' if (d_ddj>0 and d_pc>0) else ('D' if d_ddj>0 else ('P' if d_pc>0 else 'X'))
for i in range(0,len(line),60):
    print(f"  t={float(body[i]['t']):6.1f}s  {line[i:i+60]}")

print("\nrekordbox's OWN PipeWire stream (id=state). A CHANGED ID means the")
print("stream was destroyed and recreated, which is what the master-out icon")
print("appearing and disappearing looks like from inside:")
last=None
for r in rows:
    cur=r.get('pw_stream','?')
    if cur!=last:
        print(f"  t={float(r['t']):6.1f}s  {cur}")
        last=cur

print("\nNOTE: the pc_pcm column is card0's substream, owned by PipeWire. It")
print("advances continuously regardless of rekordbox and must NOT be read as")
print("'the PC output is working'.")

print("\nPCM state changes (a teardown/reopen shows as a state transition):")
last=None
for r in rows:
    cur=(r['ddj_pcm'].split(':')[0], r['pc_pcm'].split(':')[0])
    if cur!=last:
        print(f"  t={float(r['t']):6.1f}s  ddj={cur[0]:<10} pc={cur[1]}")
        last=cur

print("\navail_max:", rows[-1]['ddj_xrun'], "(ddj)", rows[-1]['pc_xrun'], "(pc)")
owners=set((owner(r['ddj_pcm']), owner(r['pc_pcm'])) for r in rows)
print("substream owners seen (ddj, pc):", owners)
closed=[r for r in rows if r['ddj_pcm']=='closed']
print(f"DDJ substream CLOSED in {len(closed)} of {len(rows)} samples"
      + (f", first at t={float(closed[0]['t']):.1f}s" if closed else ""))
PY
    exit 0
fi

# ---------------------------------------------------------------- sample
CARD=$(ddj_card); [ -n "$CARD" ] || { echo "stallscope: no DDJ-400 ALSA card" >&2; exit 1; }
DDJ_PCM=/proc/asound/$CARD/pcm0p/sub0
PC_PCM=/proc/asound/card0/pcm0p/sub0
MIDI=/proc/asound/$CARD/midi0

DIR="$REPO/runs/STALL/$(date +%Y%m%dT%H%M%S)-$LABEL"; mkdir -p "$DIR"
TSV="$DIR/samples.tsv"
printf 't\tddj_pcm\tpc_pcm\tpw_stream\tddj_xrun\tpc_xrun\tmidi_tx\tmidi_rx\tframes\trunnable\twchan\n' > "$TSV"

# Frame counter: reuse the DAMAGE-event instrument built for T08. It counts real
# repaints and cannot be fooled by a black capture, but it only prints a summary,
# so run it in one-second windows and keep a running total. A UI that has frozen
# stops adding to it.
FRAMES=0
if [ -x "$REPO/bin/damagefps" ]; then
    WIN=$("$REPO/bin/damagefps" --list 2>/dev/null | grep -i 'rekordbox' | head -1 | awk '{print $1}')
    if [ -n "$WIN" ]; then
        ( total=0
          while :; do
            n=$("$REPO/bin/damagefps" "$WIN" 1 2>/dev/null | awk -F'repaints=' '/repaints=/{split($2,a," ");print a[1]}')
            total=$(( total + ${n:-0} )); echo "$total" > "$DIR/frames.txt"
          done ) &
        DPID=$!
        echo "stallscope: counting repaints on window $WIN"
    else
        echo "stallscope: no rekordbox window found — frame column will stay 0"
    fi
fi

echo "stallscope: $SECS s -> $DIR"
START=$(date +%s%3N)
while :; do
    t_ms=$(( $(date +%s%3N) - START ))
    [ "$t_ms" -gt $(( SECS * 1000 )) ] && break
    t=$(printf '%d.%02d' $(( t_ms / 1000 )) $(( (t_ms % 1000) / 10 )))
    pid=$(pgrep -x rekordbox.exe | head -1)
    if [ -n "$pid" ]; then w=$(hot_wchan "$pid"); r=$(runnable "$pid"); else w=-; r=0; fi
    [ -r "$DIR/frames.txt" ] && FRAMES=$(cat "$DIR/frames.txt" 2>/dev/null || echo 0)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$t" "$(pcm_state $DDJ_PCM)" "$(pcm_state $PC_PCM)" "$(pw_stream)" \
        "$(xruns $DDJ_PCM)" "$(xruns $PC_PCM)" \
        "$(midi_tx $MIDI)" "$(midi_rx $MIDI)" "$FRAMES" "$r" "${w:--}" >> "$TSV"
    sleep 0.2
done
[ -n "${DPID:-}" ] && kill "$DPID" 2>/dev/null
echo "stallscope: done"
"$0" report "$DIR"
