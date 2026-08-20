#!/usr/bin/env bash
# authprobe.sh — watch the DDJ-400 auth handshake at TWO layers at once, and
# find out which layer loses it.
#
# THE QUESTION. rekordbox's auth reaches step 4 of 5: it sends @AuthResponseE
# (0x14, 66 bytes) and the device never answers @AuthEnd (0x15), so at 8000 ms
# DeviceMidi::timerCallback logs "@@@ MIDI Disconnect by AuthReq" and tears the
# port down. enableDevice never runs, so the LEDs never light. Three candidates:
#
#   (1) the device rejects the response and deliberately stops       device-side
#   (2) the device wedges for an unrelated USB reason at that moment USB-side
#   (3) Wine truncates or mis-packetises the 66 bytes, so the device
#       never sees a terminated SysEx and its parser is left open    OUR BUG
#
# Nothing measured before today separates these, because every instrument used
# sat ABOVE the transport: Wine's own log says what it was asked to send, and
# the kernel Tx counter says what rawmidi accepted — neither says what the
# device got, or whether the URB completed.
#
# WHAT THIS DOES. Captures both layers in one run and diffs them:
#   winealsa RBW-WIRE  what the driver was handed        (bytes in)
#   usbmon via usbwire what actually left the controller (bytes out, URB status)
#
# Every run is gated on a 0xFE wire check BEFORE and AFTER. A run whose device
# was dead at either end is VOID, not evidence — the project has already drawn
# three retracted conclusions from runs against a wedged device.
#
#   authprobe.sh [--secs N] [--runs N] [--label X] [--rename]
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${RBW_PREFIX:-$REPO/prefixes/rb7}"
EXE="$("$(dirname "${BASH_SOURCE[0]}")/rbexe.sh")"

SECS=45; RUNS=1; LABEL=auth; RENAME=0
while [ $# -gt 0 ]; do
  case "$1" in
    --secs)   SECS="$2"; shift ;;
    --runs)   RUNS="$2"; shift ;;
    --label)  LABEL="$2"; shift ;;
    --rename) RENAME=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac; shift
done

hdr() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

one_run() {
    local n="$1"
    local id; id="$(date +%Y%m%dT%H%M%S)-$LABEL-r$n"
    local dir="$REPO/runs/AUTH/$id"
    mkdir -p "$dir"

    hdr "run $n/$RUNS — $id"

    if ! "$REPO/research/probes/usbwire.sh" check | tee "$dir/wirecheck-before.txt"; then
        echo "VOID: device not healthy before the run" | tee "$dir/VERDICT"
        return 1
    fi

    "$REPO/bin/rbclean.sh" --quiet >/dev/null 2>&1

    "$REPO/research/probes/usbwire.sh" start "$LABEL-r$n" >"$dir/capture.txt" 2>&1
    local pcap; pcap=$(awk -F'-> ' '/capturing/{print $2}' "$dir/capture.txt" | awk '{print $1}')

    # RBW_MIDI_WIRE turns on the driver-side hex log (ERR level, so the default
    # WINEDEBUG shows it). +debugstr was tried and dropped: it produced zero
    # lines in four runs, and this handshake has a 200 ms cadence and an 8000 ms
    # deadline, so an unnecessary channel is a timing risk for no information.
    # Build the environment explicitly. The previous version used
    # ${RENAME:+RBW_MIDI_RENAME=...}, which expands whenever RENAME is set and
    # NON-EMPTY -- and "0" is non-empty. So every run silently renamed the MIDI
    # port to "Generic MIDI Controller", which is precisely the workaround that
    # forces rekordbox down the generic path and away from MidiMapDDJ400. Seven
    # runs were recorded as "plain launch, took the generic path" on the
    # strength of it. Never use :+ for a boolean.
    local -a ENV=(WINEPREFIX="$PREFIX" WINEDLLOVERRIDES=dxgi=n RBW_MIDI_WIRE=1)
    if [ "$RENAME" = 1 ]; then
        ENV+=(RBW_MIDI_RENAME="Generic MIDI Controller")
    fi
    # Record the environment that was actually used. A run whose conditions are
    # not written down alongside its result is not evidence.
    printf '%s\n' "${ENV[@]}" > "$dir/env.txt"
    ( cd "$REPO" && setsid env "${ENV[@]}" wine "$EXE" > "$dir/wine.log" 2>&1 & )

    echo "  running for ${SECS}s ..."
    sleep "$SECS"

    "$REPO/research/probes/usbwire.sh" stop > "$dir/wire.txt" 2>&1
    # --force is required: rbclean refuses to act while rekordbox.exe is alive,
    # so without it the run leaks a whole session, the app keeps the MIDI port
    # open, and the next run's health check reads that as a wedged device.
    "$REPO/bin/rbclean.sh" --force --quiet >/dev/null 2>&1

    "$REPO/research/probes/usbwire.sh" check > "$dir/wirecheck-after.txt" 2>&1
    cat "$dir/wirecheck-after.txt"

    analyse "$dir" | tee "$dir/VERDICT"
}

analyse() {
    local dir="$1"
    local log="$dir/wine.log" wire="$dir/wire.txt"

    echo
    echo "---- what the DRIVER was asked to send (winealsa RBW-WIRE) ----"
    # The driver log truncates: 64 bytes outbound (marked "...") and 32 inbound
    # (NOT marked). So its byte counts are a lower bound, never a transcript.
    for cmd in 50 11 12 13 14 15; do
        local n
        n=$(grep -acE "RBW-(WIRE|RAW) (IN|OUT) dev=[0-9]+ len=[0-9]+: F0 00 40 05 00 00 02 06 00 $cmd" "$log" 2>/dev/null)
        printf '  cmd 0x%s  x%-4s %s\n' "$cmd" "${n:-0}" "$(cmdname "$cmd")"
    done

    echo
    echo "---- what actually reached the WIRE (usbmon, with URB status) ----"
    for cmd in 50 11 12 13 14 15; do
        local n
        n=$(grep -ac "cmd=0x$cmd" "$wire" 2>/dev/null)
        printf '  cmd 0x%s  x%-4s %s\n' "$cmd" "${n:-0}" "$(cmdname "$cmd")"
    done

    echo
    echo "---- the application's own account ----"
    grep -aoE '@@@ MIDI Disconnect by AuthReq|### @Auth Success!! ###|### MIDI:[^"]{0,60}' "$log" 2>/dev/null | sort | uniq -c | head

    echo
    echo "---- adjudication ----"
    local sent_e wire_e got_end urberr
    # Adjudicate from the WIRE, not from the driver's debug log. The log only
    # exists in a debug build; the wire capture is always available and is the
    # stronger evidence anyway.
    sent_e=$(grep -ac 'cmd=0x14' "$wire" 2>/dev/null)
    wire_e=$(grep -ac 'cmd=0x14' "$wire" 2>/dev/null)
    got_end=$(grep -ac 'cmd=0x15' "$wire" 2>/dev/null)
    urberr=$(grep -ac 'URB ERROR' "$wire" 2>/dev/null)

    if [ "${sent_e:-0}" -eq 0 ]; then
        echo "  INCONCLUSIVE — the auth never reached @AuthResponseE this run."
        echo "  (the early-exit fault is intermittent; treat this run as no-data,"
        echo "   not as evidence against any hypothesis)"
        return
    fi
    if grep -qa 'cmd=0x14' "$wire" && ! grep -a -A2 'cmd=0x14' "$wire" | grep -qa 'f7$'; then
        echo "  *** HYPOTHESIS 3 — @AuthResponseE reached the wire WITHOUT its F7"
        echo "  terminator. The device's parser is left mid-SysEx and will swallow"
        echo "  every later byte. Wine transport bug."
        return
    fi
    if [ "${urberr:-0}" -gt 0 ]; then
        echo "  *** HYPOTHESIS 2 — the message reached the wire but a URB failed."
        grep -a 'URB ERROR' "$wire" | head -3
        return
    fi
    if [ "${got_end:-0}" -gt 0 ]; then
        echo "  @AuthEnd RECEIVED — the handshake completed. Check the LEDs."
        return
    fi
    echo "  *** HYPOTHESIS 1 — @AuthResponseE went out complete, every URB"
    echo "  completed cleanly, and the device did not answer. The stall is the"
    echo "  device's decision, which points at the CONTENT of the response, not"
    echo "  at Wine's transport."
}

cmdname() {
    case "$1" in
        50) echo "@Activate keep-alive" ;;
        11) echo "@AuthReq        (device starts the auth)" ;;
        12) echo "@AuthChallengeA (host)" ;;
        13) echo "@AuthResponseA  (device)" ;;
        14) echo "@AuthResponseE  (host, final proof)" ;;
        15) echo "@AuthEnd        (device, SUCCESS)" ;;
    esac
}

# One run proves nothing here: the early exit is intermittent and has already
# produced three retracted attributions from single-run A/Bs.
[ "$RUNS" -ge 3 ] || echo "note: $RUNS run(s). Attribution needs >= 3 per arm (see JOURNAL 2026-08-16T14:30)."

for i in $(seq 1 "$RUNS"); do one_run "$i"; done
