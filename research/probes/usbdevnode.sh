#!/usr/bin/env bash
# usbdevnode — make removable drives visible to rekordbox's export browser.
#
# WHY THIS EXISTS. rekordbox finds a USB device by intersecting two
# enumerations (docs/investigation/THEMES/T02): SetupAPI's GUID_DEVCLASS_VOLUME devices on one
# side, GetDriveType/QueryDosDevice on the other, joined on
#
#     SPDRP_PHYSICAL_DEVICE_OBJECT_NAME == QueryDosDeviceW(drive letter)
#
# Wine's mountmgr creates its volumes outside the PnP tree, so the SetupAPI side
# is empty, the intersection is empty, and the Devices browser stays empty no
# matter how correct the drive letter is.
#
# The saving grace is that Wine's SetupAPI device-CLASS enumeration is purely
# registry-driven -- SETUPDI_EnumerateMatchingDeviceInstances() walks
# HKLM\SYSTEM\CurrentControlSet\Enum and matches ClassGUID, and does not even
# test DIGCF_PRESENT. So the devnode can simply be written.
#
# SUPERSEDED 2026-08-19 by upstream/patches/0009-mountmgr-volume-devnodes.patch, which
# makes mountmgr.sys write and remove these entries itself as volumes come and
# go. Keep this script for two things only: as a fallback on a Wine that does
# not carry 0009, and as a diagnostic -- if rekordbox cannot see a stick, run
# `research/probes/usbdevnode.sh --remove` and check whether mountmgr recreates the entry
# under Enum\STORAGE\Volume\WineVolume<letter> by itself. If it does not, 0009
# is not installed.
#
# Needs the patched setupapi (upstream/patches/0008) or the property read fails anyway.
#
# Usage: research/probes/usbdevnode.sh [--remove]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export WINEPREFIX="${WINEPREFIX:-${RBW_PREFIX:-$PWD/prefixes/rb7}}"
PROBE="upstream/drivetest.exe"
ENUM='HKLM\SYSTEM\CurrentControlSet\Enum\STORAGE\Volume'

say() { printf '  %s\n' "$*"; }

# always clear our own entries first: a stale PhysicalDeviceObjectName is worse
# than none, because rekordbox will list a device that is not there.
mapfile -t old < <(WINEDEBUG=-all wine reg query "$ENUM" 2>/dev/null \
                   | grep -oE 'RBW_[A-Z]_VOL' | sort -u)
for k in "${old[@]:-}"; do
  [ -n "$k" ] || continue
  WINEDEBUG=-all wine reg delete "$ENUM\\$k" /f >/dev/null 2>&1 && say "removed stale devnode $k"
done
[ "${1:-}" = "--remove" ] && { say "done (removal only)"; exit 0; }

[ -x "$PROBE" ] || { echo "usbdevnode: $PROBE is missing — build it with upstream/build-probes.sh"; exit 2; }

n=0
while IFS= read -r line; do
  # "   E: REMOVABLE  label "REKORDBOX"  fs "FAT32"  nt "\Device\Harddisk1""
  case "$line" in *REMOVABLE*nt\ \"*) ;; *) continue ;; esac
  letter=$(printf '%s' "$line" | grep -oE '^ *[A-Z]:' | tr -d ' :')
  label=$(printf '%s' "$line"  | sed -n 's/.*label "\([^"]*\)".*/\1/p')
  nt=$(printf '%s' "$line"     | sed -n 's/.*nt "\([^"]*\)".*/\1/p')
  [ -n "$letter" ] && [ -n "$nt" ] || continue
  key="$ENUM\\RBW_${letter}_VOL"
  WINEDEBUG=-all wine reg add "$key" /v ClassGUID /d '{71a27cdd-812a-11d0-bec7-08002be2092f}' /f >/dev/null 2>&1
  WINEDEBUG=-all wine reg add "$key" /v Class      /d Volume            /f >/dev/null 2>&1
  WINEDEBUG=-all wine reg add "$key" /v DeviceDesc /d "Generic volume"  /f >/dev/null 2>&1
  WINEDEBUG=-all wine reg add "$key" /v FriendlyName /d "${label:-$letter}" /f >/dev/null 2>&1
  WINEDEBUG=-all wine reg add "$key" /v Mfg        /d Microsoft         /f >/dev/null 2>&1
  WINEDEBUG=-all wine reg add "$key" /v Service    /d volsnap           /f >/dev/null 2>&1
  WINEDEBUG=-all wine reg add "$key" /v Capabilities /t REG_DWORD /d 132 /f >/dev/null 2>&1
  WINEDEBUG=-all wine reg add "$key" /v ConfigFlags  /t REG_DWORD /d 0   /f >/dev/null 2>&1
  WINEDEBUG=-all wine reg add "$key" /v PhysicalDeviceObjectName /d "$nt" /f >/dev/null 2>&1
  WINEDEBUG=-all wine reg add "$key\\Control" /v Linked /t REG_DWORD /d 1 /f >/dev/null 2>&1
  say "devnode for $letter: \"${label:-$letter}\" -> $nt"
  n=$((n+1))
done < <(WINEDEBUG=-all wine "$PROBE" 2>/dev/null | grep -v '^[0-9a-f]\{4\}:')

if [ "$n" -eq 0 ]; then
  say "no removable drives found"
  say "check: a stick is mounted, its dosdevices/X: link exists, and"
  say "       HKLM\\Software\\Wine\\Drives has it as a removable type"
else
  say "$n removable drive(s) registered — restart rekordbox to pick them up"
fi
