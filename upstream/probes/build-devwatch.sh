#!/usr/bin/env bash
# Cross-compile upstream/devwatch.c with clang against Wine's own headers and
# import libraries. No mingw-w64 and no root needed. Same pattern as
# build-winedetect.sh / build-dualclient.sh.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINE_SRC="${WINE_SRC:-$HOME/.cache/rbw-wine-build/wine-11.15}"
WINE_LIB="${WINE_LIB:-/usr/lib/wine/x86_64-windows}"
OUT="${1:-$HERE/devwatch.exe}"

clang --target=x86_64-windows -fuse-ld=lld -nostdlib -Wall -O1 \
  -I"$WINE_SRC/include" -I"$WINE_SRC/include/msvcrt" \
  -o "$OUT" "$HERE/devwatch.c" \
  "$WINE_LIB/libkernel32.a" "$WINE_LIB/libuser32.a" \
  -Wl,-entry:entry -Wl,-subsystem:console

echo "built: $OUT"
