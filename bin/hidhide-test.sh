#!/usr/bin/env bash
# hidhide-test — does rekordbox bind the controller over MIDI when it CANNOT
# see the HID interface?
#
# THE HYPOTHESIS. rekordbox finds the DDJ-400's vendor HID interface, classifies
# it as "Other" (the model is absent from its 44-entry auth-capable DeviceHid
# table), and parks in "### HID:Other:[%s] open wait for start midi." From
# there it re-enumerates the MIDI INPUT list about twice a second, forever,
# and never calls midiInOpen. Measured: 431 input enumerations against 2 output
# ones in a single startup; the output interface is queried once and accepted,
# the input one is queried every iteration and never acted on.
#
# The connect handler that would construct DeviceMidi -- and which first loads
# <name>.midi.csv -- is never reached at all. So something upstream of MIDI
# decides not to proceed, and the only upstream thing is the HID layer.
#
# If the HID interface simply is not there, rekordbox has no HID device to wait
# on, and a class-compliant MIDI controller should be bindable through the plain
# MIDI path using the 243-row factory mapping.
#
# METHOD. Wine's winebus enumerates HID devices from /dev/hidraw*. Revoke this
# user's ACL on the node and winebus cannot open it, so the device vanishes from
# Wine's HID stack without touching the kernel, the udev rule, or the hardware.
#
# This is DIAGNOSTIC ONLY. Hiding the HID interface is not a fix -- rekordbox
# uses it to identify the model, and on Windows both interfaces are present.
# The ACL is always restored, including on interrupt.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HR=/dev/hidraw0
OUT="runs/HIDHIDE"; mkdir -p "$OUT"
STAMP=$(date +%Y%m%dT%H%M%S)
LOG="$OUT/$STAMP-wine.log"
export WINEPREFIX="$PWD/prefixes/rb7"

restore() {
  echo
  echo "restoring HID access ..."
  sudo setfacl -m "u:$USER:rw" "$HR" 2>/dev/null
  getfacl "$HR" 2>/dev/null | grep -q "^user:$USER:rw-" \
    && echo "  ACL restored: $(getfacl $HR 2>/dev/null | grep ^user:$USER)" \
    || echo "  WARNING: ACL not restored -- run: sudo setfacl -m u:$USER:rw $HR"
}
trap restore EXIT INT TERM

pgrep -f 'rekordbox\.exe' >/dev/null && { echo "close rekordbox first"; exit 1; }
[ -e "$HR" ] || { echo "no $HR"; exit 2; }

echo "=== baseline: is the controller visible to Wine's HID stack now? ==="
WINEDEBUG=-all timeout 60 wine upstream/hidtest.exe 2>/dev/null | grep -E "VERDICT|Pioneer" | head -3

echo
echo "=== hiding the HID interface (revoking $USER's ACL on $HR) ==="
sudo setfacl -x "u:$USER" "$HR"
getfacl "$HR" 2>/dev/null | grep -E "^user" | sed 's/^/  /'
timeout 30 wineserver -k 2>/dev/null; sleep 2

echo
echo "=== confirm Wine can no longer see it ==="
WINEDEBUG=-all timeout 60 wine upstream/hidtest.exe 2>/dev/null | grep -E "VERDICT|total HID" | head -3

echo
echo "=== MIDI devices still enumerated? (must still be there) ==="
WINEDEBUG=-all timeout 60 wine upstream/miditest.exe 2>/dev/null | head -6

echo
echo "=== launching rekordbox with HID hidden (90s) ==="
WINEDEBUG="+winmm,+midi" nohup wine "$("$(dirname "${BASH_SOURCE[0]}")/rbexe.sh")" > "$LOG" 2>&1 &
sleep 95

echo
echo "=== RESULT ==="
echo "log: $LOG ($(wc -l < "$LOG") lines)"
printf '  midiInOpen  : %s\n' "$(grep -c 'midiInOpen' "$LOG")"
printf '  midiOutOpen : %s\n' "$(grep -c 'midiOutOpen' "$LOG")"
printf '  midiInStart : %s\n' "$(grep -c 'midiInStart' "$LOG")"
grep -E "midiInOpen|midiOutOpen" "$LOG" | sed 's/^[0-9a-f]*://' | head -6 | sed 's/^/    /'
CARD=$(for c in /proc/asound/card*/usbid; do [ -r "$c" ] && [ "$(cat $c)" = "2b73:0026" ] && echo "$c" | sed 's|.*card\([0-9]*\)/usbid|\1|'; done)
printf '  MIDI bytes  : %s\n' "$(awk '/Tx bytes|Rx bytes/{printf "%s=%s ", $1, $NF}' "/proc/asound/card$CARD/midi0" 2>/dev/null)"
printf '  ALSA subscription: %s\n' "$(aconnect -l 2>/dev/null | sed -n '/client 20/,/^client 1[0-9]/p' | grep -c 'Connecting To')"

echo
echo "INTERPRETATION:"
echo "  midiInOpen > 0 or Tx bytes > 0  -> the HID path was blocking the MIDI bind."
echo "  unchanged (still 0)             -> HID is not the blocker; look elsewhere."
