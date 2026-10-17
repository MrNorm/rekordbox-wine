#!/usr/bin/env bash
# verifyloaded — check what a RUNNING process actually mapped, not what is on disk.
#
# WHY THIS EXISTS, and it is the sharpest lesson in the project. The private
# Wine tree was built, every patched file was in it, and every marker check
# passed -- while rekordbox was loading the STOCK libraries the whole time. The
# checks looked at files on disk; the process had resolved a symlinked ntdll.so
# back to /usr/lib/wine and taken its whole tree from there.
#
# A check that inspects the artifact instead of the running system is exactly
# the "measurement that cannot fail" T00 warns about. This one reads
# /proc/<pid>/maps, which cannot be fooled by a correct file in the wrong place.
#
# Usage: bin/verifyloaded.sh [pid]     default: the running rekordbox.exe
set -uo pipefail
PID="${1:-$(pgrep -x rekordbox.exe | head -1)}"
[ -n "$PID" ] || { echo "verifyloaded: no rekordbox.exe running and no pid given"; exit 2; }
[ -r "/proc/$PID/maps" ] || { echo "verifyloaded: cannot read /proc/$PID/maps"; exit 2; }

# The PE fixes too: since the runtime ships them as builtins (2026-10-17) they
# map from its lib/wine/x86_64-windows, and a prefix that still forces an old
# native copy maps that from system32 instead -- which this would show.
declare -A WANT=(
  [winealsa.so]=RBW-EVENT [winex11.so]=RBW-POPUP
  [mountmgr.so]=RBW-REMOVABLE [wineusb.so]=RBW-USBHCD
  [dxgi.dll]=RBW-PATCH [mmdevapi.dll]=RBW-MMDEV
  [setupapi.dll]=PhysicalDeviceObjectName
)
echo "process $PID  ($(tr '\0' ' ' < /proc/$PID/cmdline | cut -c1-60))"
echo "loader: $(readlink -f /proc/$PID/exe)"
fail=0 seen=0
for lib in "${!WANT[@]}"; do
  path=$(grep -oE "/[^ ]*/${lib//./\\.}" "/proc/$PID/maps" 2>/dev/null | sort -u | head -1)
  if [ -z "$path" ]; then
    printf "  %-14s not mapped (this process may simply not use it)\n" "$lib"; continue
  fi
  seen=$((seen+1))
  n=$(strings -a "$path" 2>/dev/null | grep -c -- "${WANT[$lib]}" || true)
  if [ "${n:-0}" -gt 0 ]; then
    printf "  %-14s \033[32mPATCHED\033[0m  %s\n" "$lib" "$path"
  else
    printf "  %-14s \033[31mSTOCK\033[0m    %s  (expected %s)\n" "$lib" "$path" "${WANT[$lib]}"
    fail=1
  fi
done
echo
# Stock libraries are the CORRECT answer for anything that is not rekordbox --
# that is the whole point of a separate runtime, and reporting it as a failure
# would train the reader to ignore this tool.
is_rb=0; grep -qa 'rekordbox' "/proc/$PID/cmdline" 2>/dev/null && is_rb=1

if [ "$seen" -eq 0 ]; then
  echo "nothing to check — this process mapped none of the patched libraries"
  exit 0
fi
if [ "$fail" -eq 0 ]; then
  echo -e "\033[32mEvery patched library this process mapped is ours.\033[0m"
  exit 0
fi
if [ "$is_rb" -eq 1 ]; then
  echo -e "\033[31mrekordbox is running on STOCK Wine libraries — the fixes are NOT active.\033[0m"
  echo "Check the runtime with:  rekordbox-wine --check   (reinstall the package if it fails)"
  exit 1
fi
echo "This process uses the system Wine, which is expected: only rekordbox runs"
echo "on the package's own Wine runtime. Nothing here needs fixing."
exit 0
