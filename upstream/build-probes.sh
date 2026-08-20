#!/usr/bin/env bash
# Cross-compile the freestanding Windows probes with clang, against Wine's own
# headers and import libraries. No mingw-w64 and no root needed.
#
#   vblanktest   IDXGIOutput::WaitForVBlank                             (T01)
#   wasapitest   IAudioClient exclusive-mode format probing + streams   (T03)
#   miditest     winmm MIDI enumeration, output and input               (T05)
#   hidtest      HID device enumeration, the way rekordbox identifies a
#                controller                                               (T05)
#
# Some headers are widl-generated, so a source tree that has only been partially
# built may not have them yet — generate on demand.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINE_SRC="${WINE_SRC:-$HOME/.cache/rbw-wine-build/wine-11.15}"
WINE_LIB="${WINE_LIB:-/usr/lib/wine/x86_64-windows}"
PROBES=(vblanktest wasapitest miditest hidtest devtreetest hcdtest)
[[ $# -gt 0 ]] && PROBES=("$@")

for h in mmdeviceapi audioclient; do
  if [[ ! -f "$WINE_SRC/include/$h.h" ]]; then
    [[ -f "$WINE_SRC/include/$h.idl" ]] || { echo "no $h.idl in $WINE_SRC/include"; exit 1; }
    ( cd "$WINE_SRC/include" && widl -h -I. -o "$h.h" "$h.idl" )
    echo "generated $h.h"
  fi
done

# probe -> the import libraries it needs beyond kernel32/user32
libs_for() {
  case "$1" in
    vblanktest) echo "libdxgi.a libdxguid.a" ;;
    wasapitest) echo "libole32.a libuuid.a libpropsys.a" ;;
    miditest)   echo "libwinmm.a" ;;
    hidtest)    echo "libhid.a libsetupapi.a" ;;
    devtreetest) echo "libcfgmgr32.a" ;;
    hcdtest)    echo "" ;;   # kernel32 only — it just opens devices and sends ioctls
    *) echo "unknown probe: $1" >&2; exit 1 ;;
  esac
}

for p in "${PROBES[@]}"; do
  extra=()
  for l in $(libs_for "$p"); do extra+=("$WINE_LIB/$l"); done
  clang --target=x86_64-windows -fuse-ld=lld -nostdlib -Wall -O1 \
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/msvcrt" \
    -o "$HERE/$p.exe" "$HERE/$p.c" \
    "${extra[@]}" "$WINE_LIB/libkernel32.a" "$WINE_LIB/libuser32.a" \
    -Wl,-entry:entry -Wl,-subsystem:console
  echo "built: $HERE/$p.exe"
done
