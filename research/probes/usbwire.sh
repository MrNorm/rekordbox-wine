#!/usr/bin/env bash
# usbwire.sh — capture the DDJ-400's USB traffic at the wire, gated on device health.
#
# Every previous MIDI instrument in this project measured a software layer and
# was fooled by it: Wine's TRACE (silent from winealsa's raw pthread) and
# aseqdump (sees the sequencer, not the wire).
#
# The kernel's "Tx bytes" counter is the subtle one, and an earlier version of
# this comment described it wrongly. It is incremented in
# __snd_rawmidi_transmit_ack — when the USB MIDI driver PULLS bytes out of the
# buffer to pack into a URB. Not when the application writes them, and not when
# the URB completes. So it over-reports relative to the wire: bytes can be acked
# into a URB that never completes, which is precisely what happens when this
# device wedges. This tool reads URB completion codes instead, so "packed for
# sending" and "the device took it" become separable facts.
#
#   usbwire.sh start <label>     begin capture in the background
#   usbwire.sh stop              end capture, decode, print the transcript
#   usbwire.sh decode <pcap>     re-decode an existing capture
#   usbwire.sh check             wire check only (is the device alive?)
#
# Requires: wireshark-cli (tshark), usbmon (modprobe usbmon), sudo.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$REPO/runs/WIRE"
STATE="$OUTDIR/.current"
VIDPID="2b73:0026"

mkdir -p "$OUTDIR"

die() { echo "usbwire: $*" >&2; exit 1; }

# --- locate the controller -------------------------------------------------
find_dev() {
    local line
    line=$(lsusb -d "$VIDPID" | head -1) || return 1
    [ -n "$line" ] || return 1
    BUS=$(echo "$line" | awk '{print $2}' | sed 's/^0*//')
    DEVNUM=$(echo "$line" | awk '{gsub(":","",$4); print $4}' | sed 's/^0*//')
    CARD=$(grep -l 'DDJ-400' /proc/asound/card*/usbid 2>/dev/null | head -1)
    CARD=$(for c in /proc/asound/card[0-9]*; do
               [ -r "$c/id" ] && [ "$(cat "$c/id")" = "DDJ400" ] && basename "$c" && break
           done)
    return 0
}

tx_bytes() {
    [ -n "${CARD:-}" ] && [ -r "/proc/asound/$CARD/midi0" ] || { echo -1; return; }
    awk '/^Output/{o=1} o&&/Tx bytes/{print $4; exit}' "/proc/asound/$CARD/midi0"
}

# --- the health gate -------------------------------------------------------
# Presence is not health. A DDJ-400 wedged at the USB level still answers
# descriptor requests, so lsusb lists it, HID reads its product string and the
# HCD walk reports the right VID/PID — while accepting no MIDI at all. The only
# honest test is to put a byte on the wire and watch the counter move.
wire_check() {
    local before after
    if ! find_dev; then
        echo "WIRE-CHECK: FAIL — no $VIDPID on the bus (not plugged in)"
        return 2
    fi
    if [ -z "${CARD:-}" ]; then
        echo "WIRE-CHECK: FAIL — device present but has NO ALSA card (wedged at the USB level; needs a physical power cycle)"
        return 3
    fi
    # A port held open by another process is NOT a wedged device, but it looks
    # exactly like one from the Tx counter: the owner's writes move the counter
    # and ours may not. Report the owner rather than mislabelling the hardware.
    local owner
    owner=$(awk '/Owner PID/{print $4; exit}' "/proc/asound/$CARD/midi0" 2>/dev/null)
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        echo "WIRE-CHECK: SKIPPED — MIDI port is owned by PID $owner ($(ps -o comm= -p "$owner" 2>/dev/null)). Not a wedge; clean the session first."
        return 6
    fi
    before=$(tx_bytes)
    timeout 3 amidi -p "hw:${CARD#card},0,0" -S FE >/dev/null 2>&1
    local rc=$?
    after=$(tx_bytes)
    if [ "$rc" -eq 124 ]; then
        echo "WIRE-CHECK: FAIL — amidi write BLOCKED (device wedged), Tx stuck at $before"
        return 4
    fi
    if [ "$after" -le "$before" ]; then
        echo "WIRE-CHECK: FAIL — Tx did not move ($before -> $after)"
        return 5
    fi
    echo "WIRE-CHECK: ok — $CARD, bus $BUS dev $DEVNUM, Tx $before -> $after"
    return 0
}

case "${1:-}" in
start)
    label="${2:-run}"
    [ -e /sys/kernel/debug/usb/usbmon ] || sudo modprobe usbmon || die "cannot load usbmon"
    wire_check || die "refusing to capture against an unhealthy device (see rule: any run against a wedged device is VOID)"
    ts=$(date +%Y%m%dT%H%M%S)
    pcap="$OUTDIR/$ts-$label.pcap"
    # dumpcap drops privileges, so it cannot write into the repo; stage the
    # capture in /tmp and move it on stop.
    tmp="/tmp/usbwire-$ts-$$.pcap"
    sudo tshark -i "usbmon$BUS" -F pcap -w "$tmp" -q >"$pcap.log" 2>&1 &
    echo "$!|$pcap|$DEVNUM|$CARD|$tmp" > "$STATE"
    # A reader that has not yet attached captures nothing, and that silence is
    # indistinguishable from "the device sent nothing" — the exact instrument
    # fault this project keeps rediscovering. Wait for the file to exist.
    for _ in $(seq 60); do [ -s "$tmp" ] && break; sleep 0.1; done
    [ -s "$tmp" ] || echo "usbwire: WARNING — capture still empty after 6s, check $pcap.log"
    echo "usbwire: capturing bus $BUS -> $pcap  (device $DEVNUM, $CARD)"
    ;;
stop)
    [ -f "$STATE" ] || die "no capture in progress"
    IFS='|' read -r pid pcap devnum card tmp < "$STATE"
    sudo pkill -INT -f "tshark -i usbmon" 2>/dev/null
    sleep 1
    rm -f "$STATE"
    sudo chown "$(id -u):$(id -g)" "$tmp" 2>/dev/null
    mv "$tmp" "$pcap" 2>/dev/null || die "capture file $tmp missing — see $pcap.log"
    echo "usbwire: stopped. post-run health:"
    wire_check
    echo
    python3 "$REPO/research/probes/usbwire.py" "$pcap" --dev "$devnum"
    echo
    echo "capture: $pcap"
    ;;
decode)
    [ -n "${2:-}" ] || die "usage: usbwire.sh decode <pcap> [--dev N]"
    shift
    python3 "$REPO/research/probes/usbwire.py" "$@"
    ;;
check)
    wire_check
    exit $?
    ;;
*)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
