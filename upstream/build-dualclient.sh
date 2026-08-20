#!/usr/bin/env bash
# Cross-compile upstream/dualclient.c with clang against Wine's own headers and
# import libraries. No mingw-w64 and no root needed.
#
# mmdeviceapi.h / audioclient.h are widl-generated, so a source tree that has
# only been partially built may not have them yet — generate on demand.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINE_SRC="${WINE_SRC:-$HOME/.cache/rbw-wine-build/wine-11.15}"
WINE_LIB="${WINE_LIB:-/usr/lib/wine/x86_64-windows}"
OUT="${1:-$HERE/dualclient.exe}"

for h in mmdeviceapi audioclient; do
  if [[ ! -f "$WINE_SRC/include/$h.h" ]]; then
    [[ -f "$WINE_SRC/include/$h.idl" ]] || { echo "no $h.idl in $WINE_SRC/include"; exit 1; }
    ( cd "$WINE_SRC/include" && widl -h -I. -o "$h.h" "$h.idl" )
    echo "generated $h.h"
  fi
done

clang --target=x86_64-windows -fuse-ld=lld -nostdlib -Wall -O1 \
  -I"$WINE_SRC/include" -I"$WINE_SRC/include/msvcrt" \
  -o "$OUT" "$HERE/dualclient.c" \
  "$WINE_LIB/libole32.a" "$WINE_LIB/libuuid.a" "$WINE_LIB/libpropsys.a" \
  "$WINE_LIB/libkernel32.a" "$WINE_LIB/libuser32.a" \
  -Wl,-entry:entry -Wl,-subsystem:console

echo "built: $OUT"
