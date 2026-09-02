#!/usr/bin/env bash
# build-patched-dlls — produce every patched Wine component rekordbox needs,
# from a PRISTINE Wine source tree and the patch series in upstream/.
#
# This is the script the AUR package runs, so it must be able to start from
# nothing: it fetches the matching Wine source, applies upstream/patches/0*.patch in
# order, configures, builds, and then VERIFIES that every component carries its
# marker string. A component that silently built without its patch is the
# failure mode this project has paid for repeatedly -- a stock build loads fine
# and simply behaves as though unpatched.
#
#   PE builtins            what they fix                                theme
#     dxgi.dll             IDXGIOutput::WaitForVBlank — without it any    T01
#                          JUCE 8 app paints one frame and freezes
#     mmdevapi.dll         event-driven exclusive-mode audio              T03
#     setupapi.dll         SPDRP_PHYSICAL_DEVICE_OBJECT_NAME readable     T02
#     mountmgr.sys         honest storage descriptor, and volume device   T02
#                          nodes so removable drives can be found
#   unix libraries
#     winealsa.so          exclusive event gating, and the SysEx fix      T03/T05
#                          that lets the DDJ-400 authenticate
#     winex11.so           menus and their drop shadows are not handed    T04
#                          to the window manager
#     mountmgr.so          a removable UDisks drive is removable          T02
#     wineusb.so/.sys      \\.\HCDn, without which rekordbox rejects the    T05
#                          controller and never opens its MIDI port
#
# Usage: bin/build-patched-dlls.sh [component ...]      (default: all)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
CACHE="${RBW_WINE_BUILD:-$HOME/.cache/rbw-wine-build}"
WINE_VER="${WINE_VER:-$(wine --version 2>/dev/null | sed 's/^wine-//;s/ .*//')}"
SRC="$CACHE/wine-$WINE_VER"
. "$ROOT/bin/winepaths.sh"
WINE_LIB="${WINE_LIB:-$WINE_PE_DIR}"

# component : make target : marker string
PE_COMPONENTS=(
  "dxgi:dlls/dxgi/x86_64-windows/dxgi.dll:RBW-PATCH"
  "mmdevapi:dlls/mmdevapi/x86_64-windows/mmdevapi.dll:RBW-MMDEV"
  "setupapi:dlls/setupapi/x86_64-windows/setupapi.dll:PhysicalDeviceObjectName"
  "mountmgr.sys:dlls/mountmgr.sys/x86_64-windows/mountmgr.sys:RBW-VOLNODE"
)
UNIX_COMPONENTS=(
  "winealsa:dlls/winealsa.drv/winealsa.so:RBW-EVENT3"
  "winex11:dlls/winex11.drv/winex11.so:RBW-POPUP"
  "mountmgr:dlls/mountmgr.sys/mountmgr.so:RBW-REMOVABLE"
)

# $# inside a function is the FUNCTION's argument count, not the script's, so
# the "no arguments means all components" test has to read a captured copy.
WANT=("$@"); NWANT=$#
want() { [[ $NWANT -eq 0 || " ${WANT[*]} " == *" $1 "* ]]; }

# Check the version BEFORE downloading 46 MB and configuring for five minutes,
# only to fail on patch three with a diff error the user cannot act on.
SUPPORTED="$ROOT/upstream/patches/supported-wine.txt"
if [[ -f "$SUPPORTED" ]] && ! grep -qE "^[[:space:]]*${WINE_VER//./\.}([[:space:]]|$)" "$SUPPORTED"; then
  if [[ "${RBW_ALLOW_UNTESTED_WINE:-0}" != 1 ]]; then
    echo "wine $WINE_VER is not a version this patch series has been tested against."
    echo
    echo "Known good:"; grep -vE '^[[:space:]]*(#|$)' "$SUPPORTED" | sed 's/^/  /'
    echo
    echo "The series patches Wine internals, so a newer or older Wine may fail to"
    echo "apply -- or, worse, apply with fuzz into code whose logic has changed."
    echo
    echo "To try anyway:  RBW_ALLOW_UNTESTED_WINE=1 $0 $*"
    echo "If it works, add $WINE_VER to $SUPPORTED with what you measured."
    exit 1
  fi
  echo "WARNING: wine $WINE_VER is untested with this patch series (RBW_ALLOW_UNTESTED_WINE=1)"
fi

echo "wine version : $WINE_VER"
echo "source tree  : $SRC"

# ---------------------------------------------------------------- source
if [[ ! -d "$SRC" ]]; then
  mkdir -p "$CACHE"
  TARBALL="$CACHE/wine-$WINE_VER.tar.xz"
  [[ -f "$TARBALL" ]] || curl -fL -o "$TARBALL" \
    "https://dl.winehq.org/wine/source/${WINE_VER%%.*}.x/wine-$WINE_VER.tar.xz"
  tar -C "$CACHE" -xf "$TARBALL"
  echo "extracted a pristine tree"
fi

# ---------------------------------------------------------------- patches
# Applied in numeric order and idempotently: 0009 stacks on 0007 in the same
# file, so order is not decorative. `--dry-run` first so a half-applied tree is
# never produced.
echo
echo "=== patch series ==="
for p in "$ROOT"/upstream/patches/0*.patch; do
  name="$(basename "$p")"
  if (cd "$SRC" && patch -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1); then
    echo "  already applied  $name"
  elif (cd "$SRC" && patch -p1 --dry-run -s -f < "$p" >/dev/null 2>&1); then
    (cd "$SRC" && patch -p1 -s < "$p")
    echo "  applied          $name"
  else
    echo "  FAILED           $name — the tree is not in a state this series expects"
    exit 1
  fi
done

# ---------------------------------------------------------------- configure
cd "$SRC"
if [[ ! -f config.status ]]; then
  echo
  echo "configuring (once; several minutes)..."
  ./configure --enable-win64 --disable-tests >"$CACHE/configure.log" 2>&1 \
    || { echo "configure failed — see $CACHE/configure.log"; exit 1; }

  # Wine's configure does not fail when a development package is missing: it
  # prints a note and quietly drops the driver from the build. A missing
  # libx11/libasound then yields a package with no winex11 and no winealsa and
  # no error anywhere, which reads later as "the patch stopped working".
  for need in winex11.drv winealsa.drv; do
    if grep -q "$need" "$CACHE/configure.log"; then
      echo "configure will not build $need — install its development package:"
      grep -A2 "$need" "$CACHE/configure.log" | sed 's/^/    /'
      exit 1
    fi
  done
fi

# winebuild needs import libraries to link a PE dll and a tree that has not been
# fully built has none. Seed them from the installed Wine rather than building
# all 250-odd.
# tools/winebuild is a prerequisite of EVERY import library, so it has to exist
# before the seeded ones are stamped -- otherwise building it immediately makes
# all 258 of them look stale.
make tools/winebuild/winebuild >"$CACHE/build-winebuild.log" 2>&1 \
  || { echo "could not build winebuild — see $CACHE/build-winebuild.log"; exit 1; }

# Take the destinations from the Makefile rather than guessing them from the
# library names. A dll's directory is not always its import library's name --
# libntoskrnl.a lives in dlls/ntoskrnl.exe/ -- and a guess that is wrong for one
# library is invisible until the one component that links against it fails.
echo "seeding import libraries from $WINE_LIB"
seeded=0 unseeded=0
while read -r target; do
  lib="$WINE_LIB/$(basename "$target")"
  if [[ -f "$lib" ]]; then
    mkdir -p "$(dirname "$target")"
    cp -n "$lib" "$target" 2>/dev/null || true
    seeded=$((seeded+1))
  else
    unseeded=$((unseeded+1))
  fi
done < <(grep -oE '^dlls/[^ :]+/x86_64-windows/lib[^ :]+\.a:' Makefile | tr -d ':' | sort -u)
echo "  seeded $seeded import libraries ($unseeded had no installed counterpart)"

# Stamp them ahead of anything the build can produce. A plain `touch` is not
# enough: some import libraries (ucrtbase's, for one) also depend on object
# files that do not exist yet, so make compiles those DURING the build and the
# freshly-stamped .a is stale again by the time it is needed.
#
# Regenerating them is not merely slow, it fails: winebuild reaches for
# `dlltool` from mingw-w64-binutils, and its --without-dlltool fallback emits
# `.rva` directives that clang's integrated assembler rejects outright for
# ntoskrnl. Wine at runtime needs neither tool, and neither should this build.
touch -d '+1 day' dlls/*/x86_64-windows/lib*.a

blank_marker() {   # Wine refuses a `native` override on a file carrying this.
  python3 -c '
import sys
p = sys.argv[1]; b = open(p, "rb").read(); m = b"Wine builtin DLL"
open(p, "wb").write(b.replace(m, b"rbw patched dll ")) if m in b else None
' "$1"
}

mkdir -p "$ROOT/artifacts" "$ROOT/artifacts/winedll"
built=()

for spec in "${PE_COMPONENTS[@]}" "${UNIX_COMPONENTS[@]}"; do
  IFS=: read -r name target marker <<<"$spec"
  want "$name" || continue
  echo
  echo "=== $name ==="
  make "$target" >"$CACHE/build-$name.log" 2>&1 \
    || { echo "  build failed — see $CACHE/build-$name.log"; exit 1; }
  [[ -f "$target" ]] || { echo "  no $target after build"; exit 1; }

  # A patch is not a fix until it is loaded and greppable. Count rather than
  # pipe to grep -q: grep exits at the first match, strings dies of SIGPIPE, and
  # under `set -o pipefail` the check fails on success.
  if [[ "$(strings -a "$target" | grep -c -- "$marker" || true)" -eq 0 ]]; then
    echo "  VERIFY FAILED: $target has no '$marker' — stock build?"; exit 1
  fi

  case "$name" in
    dxgi|mmdevapi|setupapi)
      out="$ROOT/artifacts/$name-patched-native-$WINE_VER.dll"
      cp -f "$target" "$out"; blank_marker "$out" ;;
    mountmgr.sys) cp -f "$target" "$ROOT/artifacts/winedll/mountmgr.sys" ;;
    *)            cp -f "$target" "$ROOT/artifacts/winedll/$(basename "$target")" ;;
  esac
  echo "  ok — marker '$marker' present"
  built+=("$name")
done


# ---------------------------------------------------------------- wineusb
# Not part of the 0001..0009 series: it is a source splice from
# upstream/patches/rbw-usbhcd.c rather than a patch, so it has its own build script.
# It is built here anyway, because it is MANDATORY for the controller -- without
# \\.\HCDn, rekordbox's USB validation fails, it destroys the Pioneer device
# object it just built, and never opens the controller's MIDI port. A package
# without it has no DDJ-400 support at all, which is the acceptance test.
if want wineusb; then
  echo
  echo "=== wineusb ==="
  if RBW_WINE_BUILD="$CACHE" "$ROOT/bin/build-wineusb-hcd.sh" >"$CACHE/build-wineusb.log" 2>&1; then
    for f in wineusb.sys wineusb.so; do
      if [[ "$(strings -a "$ROOT/artifacts/winedll/$f" 2>/dev/null | grep -c -- RBW-USBHCD || true)" -eq 0 ]]; then
        echo "  VERIFY FAILED: $f has no RBW-USBHCD marker"; exit 1
      fi
    done
    echo "  ok — marker 'RBW-USBHCD' present in wineusb.sys and wineusb.so"
    built+=(wineusb)
  else
    echo "  build failed — see $CACHE/build-wineusb.log"; exit 1
  fi
fi

# A build that selected nothing must not report success. This exact shape --
# every component silently skipped, exit status 0, an empty artifacts list --
# is how a package ships with no patches in it at all.
if [[ ${#built[@]} -eq 0 ]]; then
  echo; echo "NOTHING WAS BUILT — no component matched ${WANT[*]:-(all)}"; exit 1
fi

# STAMP THE UNIX LIBRARIES WITH THE WINE THEY WERE BUILT AGAINST.
#
# The PE artifacts carry their version in the filename; artifacts/winedll/ never
# carried one, and that asymmetry cost a working install on 2026-09-02. When
# wine-staging went 11.15 -> 11.16, make-private-wine.sh copied these 11.15
# binaries into an 11.16 tree and stamped the tree "11.16" -- the version of the
# SYSTEM wine, not of the files it had just installed. The result was
# `opengl32 wants 39 but driver has 38`, no GL, and an application that does not
# open, while every check in the launcher reported healthy. See T14.
#
# These are unix .so files linked against Wine internals. They are valid for
# exactly one Wine version, so say which one, in the directory, next to them.
echo "$WINE_VER" > "$ROOT/artifacts/winedll/.built-for-wine"

echo
echo "built and verified: ${built[*]}"
echo "  prefix DLLs      -> artifacts/*-patched-native-$WINE_VER.dll"
echo "  system libraries -> artifacts/winedll/   (built for wine $WINE_VER)"
