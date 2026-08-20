#!/usr/bin/env bash
#
# install-wineusb-hcd — install the wineusb build that exposes \\.\HCDn.
#
# Like winealsa.so, this cannot live in a Wine prefix. wineusb is a driver: the
# PE half (wineusb.sys) is loaded from Wine's own directory and the unix half
# (wineusb.so) is a native library, so DllOverrides does not apply to either and
# both have to replace the system files. That means root, which is why this is a
# separate script that asks before it does anything.
#
# BOTH HALVES MUST MATCH. wineusb.so gains a new unixlib entry point
# (unix_usb_enum_hcd) and wineusb.sys is the only caller of it. Installing one
# without the other gives a driver that calls past the end of the function table.
# This script refuses to install unless both carry the RBW-USBHCD marker.
#
# Reversal is a single mv per file — see --revert.
set -euo pipefail

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/winepaths.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER="RBW-USBHCD"

SYS_TARGET="$WINE_PE_DIR/wineusb.sys"
SO_TARGET="$WINE_UNIX_DIR/wineusb.so"
SYS_SRC="$HERE/artifacts/winedll/wineusb.sys"
SO_SRC="$HERE/artifacts/winedll/wineusb.so"

if [[ "${1:-}" == --revert ]]; then
  n=0
  for t in "$SYS_TARGET" "$SO_TARGET"; do
    if [[ -f "$t.rbw-backup" ]]; then
      mv -f "$t.rbw-backup" "$t"; echo "reverted $t"; n=$((n+1))
    fi
  done
  [[ $n -gt 0 ]] || { echo "no backups found — nothing to revert"; exit 1; }
  echo
  echo "Restart wineserver for this to take effect:  bin/rbclean.sh"
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "needs root: sudo $0" >&2; exit 1; }
for f in "$SYS_SRC" "$SO_SRC"; do
  [[ -f "$f" ]] || { echo "no build at $f — run bin/build-wineusb-hcd.sh first" >&2; exit 1; }
  grep -q "$MARKER" <(strings -a "$f") \
    || { echo "$f has no $MARKER marker — it is not the patched build" >&2; exit 1; }
done
for f in "$SYS_TARGET" "$SO_TARGET"; do
  [[ -f "$f" ]] || { echo "no system file at $f" >&2; exit 1; }
done

echo "This replaces two files owned by the 'wine' package:"
echo "    $SYS_TARGET"
echo "    $SO_TARGET"
echo "Backups are written beside them as *.rbw-backup."
echo
echo "What it adds: \\\\.\\HCD0.. host controller device objects and the USB hub"
echo "IOCTLs, so an application can enumerate USB from user mode the way it can"
echo "on Windows. Descriptors are read from /sys/bus/usb/devices, so what is"
echo "reported is what the kernel already knows about your hardware."
echo

for pair in "$SYS_SRC:$SYS_TARGET" "$SO_SRC:$SO_TARGET"; do
  src="${pair%%:*}"; dst="${pair##*:}"
  [[ -f "$dst.rbw-backup" ]] || cp -a "$dst" "$dst.rbw-backup"
  install -m644 "$src" "$dst"
  echo "installed $dst"
done

echo
echo "verifying the installed files carry the marker:"
for f in "$SYS_TARGET" "$SO_TARGET"; do
  grep -q "$MARKER" <(strings -a "$f") && echo "  ok  $f" || { echo "  FAIL $f"; exit 1; }
done

cat <<'EOF'

Now restart the Wine session so the new driver is loaded:

    bin/rbclean.sh

Then check it took effect — this must print the RBW-USBHCD line:

    WINEDEBUG=+err wine cmd /c exit 2>&1 | grep RBW-USBHCD

Revert at any time with:

    sudo research/retired/install-wineusb-hcd.sh --revert
EOF
