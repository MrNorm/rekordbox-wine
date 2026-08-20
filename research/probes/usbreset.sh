#!/usr/bin/env bash
# usbreset — force a clean re-enumeration of the DJ controller between runs.
#
# WHY: the controller accumulates state across a long test session. Its MIDI
# byte counters only zero on re-enumeration, its LEDs latch whatever the last
# host left them in, and a half-configured audio interface persists until
# something tears it down. Measuring against that is how a run gets quietly
# invalidated, and this project has already lost a day to results that were
# skewed rather than wrong.
#
# WHAT THIS CANNOT DO: cut power. Measured on this laptop --
#
#     $ lsusb -v -d 1d6b:0002 | grep -A6 "Hub Descriptor"
#       wHubCharacteristic 0x000a
#         No power switching (usb 1.0)
#
# -- the xHCI root hub has no per-port power switching, so uhubctl cannot help
# and VBUS stays up no matter what we do from the host. The controller's own
# MCU therefore keeps running across this reset. If the device itself needs a
# cold boot, that is a physical unplug and nothing else.
#
# WHAT IT DOES DO, via /sys/bus/usb/devices/<dev>/authorized:
#   deauthorize -> the kernel unbinds snd-usb-audio and hid-generic, destroys
#                  the ALSA card and /dev/hidraw*, and the device vanishes
#   reauthorize -> full re-enumeration: descriptors re-read, drivers re-bound,
#                  udev rules re-run (so the uaccess ACL is reapplied), rawmidi
#                  Tx/Rx counters back to zero
#
# That is a clean HOST-side state, which is what a test needs.
#
# Usage: research/probes/usbreset.sh [--check]     (--check reports state, changes nothing)
set -uo pipefail

VID="${RBW_VID:-2b73}"
CHECK=0
[[ "${1:-}" == --check ]] && CHECK=1

find_dev() {
  local d
  for d in /sys/bus/usb/devices/*/; do
    [[ -f "$d/idVendor" ]] || continue
    if [[ "$(cat "$d/idVendor" 2>/dev/null)" == "$VID" ]]; then echo "${d%/}"; return 0; fi
  done
  return 1
}

card_of() {   # ALSA card index for this VID, or empty
  local c
  for c in /proc/asound/card*/usbid; do
    [[ -r "$c" ]] || continue
    if [[ "$(cat "$c")" == "$VID:"* ]]; then
      echo "$c" | sed 's|/proc/asound/card\([0-9]*\)/usbid|\1|'
      return 0
    fi
  done
  return 1
}

report() {
  local card; card=$(card_of || true)
  printf '  device : %s\n' "${DEV:-(absent)}"
  if [[ -n "$card" ]]; then printf '  alsa   : card%s\n' "$card"; else printf '  alsa   : (absent)\n'; fi
  if [[ -n "$card" && -r "/proc/asound/card$card/midi0" ]]; then
    printf '  midi   : %s\n' "$(awk '/Tx bytes|Rx bytes/{printf "%s=%s ", $1, $NF}' "/proc/asound/card$card/midi0")"
  fi
  local hr; hr=$(ls /dev/hidraw* 2>/dev/null | head -1)
  if [[ -n "$hr" ]]; then
    if getfacl "$hr" 2>/dev/null | grep -q "^user:$USER:rw-"; then acl="ACL ok"; else acl="ACL MISSING (udev rule did not fire)"; fi
    printf '  hidraw : %s  %s\n' "$hr" "$acl"
  else
    printf '  hidraw : (absent)\n'
  fi
}

DEV=$(find_dev) || { echo "no USB device with idVendor=$VID"; exit 1; }

if [[ $CHECK -eq 1 ]]; then
  echo "current state:"; report; exit 0
fi

# Resetting the bus out from under a process that has the device open leaves
# Wine's HID stack holding a dead handle, which looks exactly like the binding
# bug we are hunting. Refuse rather than produce a misleading run.
if pgrep -x 'rekordbox.exe' >/dev/null; then
  echo "REFUSING: rekordbox is running and holds this device." >&2
  echo "Close it first, or the reset will produce a run that cannot be trusted." >&2
  exit 1
fi

echo "before:"; report

echo "deauthorizing $DEV ..."
echo 0 | sudo tee "$DEV/authorized" >/dev/null || { echo "failed to deauthorize" >&2; exit 1; }
sleep 2

echo "reauthorizing ..."
echo 1 | sudo tee "$DEV/authorized" >/dev/null || { echo "failed to reauthorize" >&2; exit 1; }

# Re-enumeration is not instant: the ALSA card and the udev ACL both appear
# a moment after the device does. Wait for the slowest of them rather than
# guessing a sleep.
for i in $(seq 1 30); do
  sleep 1
  card=$(card_of || true)
  [[ -n "$card" ]] && [[ -e /dev/hidraw0 ]] && break
done

echo "after:"; report
echo
echo "note: VBUS was never cut (this hub has no power switching), so the"
echo "      controller's own MCU did not reboot. Host-side state is clean."
