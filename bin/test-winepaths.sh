#!/usr/bin/env bash
# test-winepaths — does Wine-directory detection work on layouts other than Arch?
#
# bin/winepaths.sh is the only thing standing between this package and a silent
# failure on Debian or Fedora, and it has never run on either. This builds
# synthetic trees in the shape each distribution actually uses and asserts that
# detection finds them. It needs no container and no network, so it can run
# anywhere, including in CI.
#
# The layouts are taken from the real packages:
#   Arch          /usr/lib/wine/{x86_64-windows,x86_64-unix}
#   Debian/Ubuntu /usr/lib/x86_64-linux-gnu/wine/...
#   Fedora        /usr/lib64/wine/...
#   WineHQ        /opt/wine-staging/lib/wine/...
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
ROOT="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

mklayout() {  # $1 = fake root, $2 = lib subpath
  local r="$1" lib="$2"
  mkdir -p "$r/$lib/x86_64-windows" "$r/$lib/x86_64-unix" "$r/usr/bin"
  : > "$r/$lib/x86_64-windows/ntdll.dll"
  : > "$r/$lib/x86_64-unix/ntdll.so"
}

check() {  # $1 = label, $2 = expected PE dir, then env overrides
  local label="$1" want="$2"; shift 2
  local got
  got=$(env "$@" bash -c '. '"$ROOT"'/bin/winepaths.sh >/dev/null 2>&1 && echo "$WINE_PE_DIR"' 2>/dev/null)
  if [[ "$got" == "$want" ]]; then
    printf "  \033[32mPASS\033[0m  %-28s -> %s\n" "$label" "$got"; pass=$((pass+1))
  else
    printf "  \033[31mFAIL\033[0m  %-28s got '%s' want '%s'\n" "$label" "$got" "$want"; fail=$((fail+1))
  fi
}

echo "=== explicit override always wins ==="
mklayout "$TMP/dbn" usr/lib/x86_64-linux-gnu/wine
check "RBW_WINE_PE_DIR override" "$TMP/dbn/usr/lib/x86_64-linux-gnu/wine/x86_64-windows" \
  RBW_WINE_PE_DIR="$TMP/dbn/usr/lib/x86_64-linux-gnu/wine/x86_64-windows" \
  RBW_WINE_UNIX_DIR="$TMP/dbn/usr/lib/x86_64-linux-gnu/wine/x86_64-unix"

echo "=== the loader on PATH decides, not a hardcoded prefix ==="
# A wine binary at <root>/usr/bin/wine must resolve to <root>/usr/lib*/wine,
# which is what makes a WineHQ /opt install work.
for spec in "opt:opt/wine-staging/lib/wine" "fedora:usr/lib64/wine" "debian:usr/lib/x86_64-linux-gnu/wine" "derivative:usr/lib/aarch64-linux-gnu/wine"; do
  name="${spec%%:*}"; lib="${spec##*:}"
  r="$TMP/$name"; mklayout "$r" "$lib"
  # for a multiarch layout the binary still lives at <root>/usr/bin
  case "$lib" in
    */lib/*/wine|*/lib64/*/wine) binroot="$r/usr" ;;
    *) binroot="$r/$(dirname "$(dirname "$lib")")" ;;
  esac
  mkdir -p "$binroot/bin"
  printf '#!/bin/sh\necho wine-11.15\n' > "$binroot/bin/wine"; chmod +x "$binroot/bin/wine"
  check "$name layout via PATH" "$r/$lib/x86_64-windows" PATH="$binroot/bin:$PATH"
done

echo "=== a directory that exists but is empty must not win ==="
mkdir -p "$TMP/empty/usr/lib/wine/x86_64-windows"
check "empty dir rejected, falls back" "$(. "$ROOT/bin/winepaths.sh" >/dev/null 2>&1; echo "$WINE_PE_DIR")" \
  RBW_EMPTY=1

echo
if [[ $fail -eq 0 ]]; then
  echo -e "\033[32m$pass passed, 0 failed\033[0m"; exit 0
else
  echo -e "\033[31m$pass passed, $fail FAILED\033[0m"; exit 1
fi
