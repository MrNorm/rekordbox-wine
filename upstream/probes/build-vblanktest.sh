#!/usr/bin/env bash
# Cross-compile upstream/vblanktest.c to a Windows exe with clang, against
# Wine's own headers and import libraries. No mingw-w64 and no root needed.
#
# WINE_SRC must point at an unpacked wine tree that has been configured (widl
# generates include/dxgi.h during the build).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WINE_SRC="${WINE_SRC:-$HOME/.cache/rbw-wine-build/wine-11.15}"
WINE_LIB="${WINE_LIB:-/usr/lib/wine/x86_64-windows}"
OUT="${1:-$HERE/vblanktest.exe}"

[[ -f "$WINE_SRC/include/dxgi.h" ]] || { echo "no $WINE_SRC/include/dxgi.h — configure/build wine first"; exit 1; }

clang --target=x86_64-windows -fuse-ld=lld -nostdlib -Wall -O1 \
  -I"$WINE_SRC/include" -I"$WINE_SRC/include/msvcrt" \
  -o "$OUT" "$HERE/vblanktest.c" \
  "$WINE_LIB/libdxgi.a" "$WINE_LIB/libdxguid.a" "$WINE_LIB/libkernel32.a" "$WINE_LIB/libuser32.a" \
  -Wl,-entry:entry -Wl,-subsystem:console

echo "built: $OUT"
