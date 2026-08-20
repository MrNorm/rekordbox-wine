#!/usr/bin/env bash
# make-private-wine — build a private Wine tree that carries our patches and
# leaves the system Wine completely untouched.
#
# THE PROBLEM THIS SOLVES. Four of our fixes are unix-side libraries and two are
# PE drivers; none can be overridden per-prefix, so the old design replaced the
# files in /usr/lib/wine. Those files are owned by the distro's wine package, so
# that design (a) conflicts with package ownership, (b) is silently undone by
# every wine upgrade, and (c) -- the serious one -- changes the behaviour of
# EVERY Wine application on the machine. Somebody's Photoshop, their game, their
# accounting software all got our MIDI renaming, our window-management change
# and our storage-descriptor change, none of which they asked for.
#
# THE FIX. Wine is relocatable: it resolves its libraries and share/wine
# relative to the loader binary's own path. So we build a parallel tree that is
# almost entirely SYMLINKS to the system Wine -- costing megabytes, not the
# gigabyte a full copy would -- and put real, patched files in the handful of
# places that need them. The loader binaries themselves must be real copies,
# because Wine resolves /proc/self/exe, which follows symlinks and would send it
# straight back to /usr/lib/wine.
#
# The result: `rekordbox-wine` runs against our Wine, every other application
# runs against the distro's, and neither can affect the other.
#
# Usage: bin/make-private-wine.sh [treedir]
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
ROOT="$PWD"
. "$ROOT/bin/winepaths.sh"
TREE="${1:-${RBW_PRIVATE_WINE:-$HOME/.local/share/rekordbox-wine/wine}}"
SRCDIR="${RBW_WINEDLL_DIR:-}"
if [[ -z "$SRCDIR" ]]; then
  if [[ -d "$ROOT/artifacts/winedll" ]]; then SRCDIR="$ROOT/artifacts/winedll"; else SRCDIR="$ROOT/winedll"; fi
fi

WINE_BIN="$(readlink -f "$(command -v wine)")"
WINE_VER="$(wine --version 2>/dev/null | sed 's/^wine-//;s/ .*//')"
[[ -n "$WINE_VER" ]] || { echo "cannot run 'wine --version' — is Wine installed and working?" >&2; exit 1; }
SYS_LIB_ROOT="$(dirname "$WINE_PE_DIR")"          # e.g. /usr/lib/wine, or Debian's /usr/lib/<triplet>/wine
SYS_PREFIX="$(dirname "$(dirname "$WINE_BIN")")"  # e.g. /usr, or /opt/wine-staging

# MIRROR THE SYSTEM'S OWN RELATIVE LAYOUT. Wine resolves its libraries relative
# to the loader, but WHICH relative path differs by distribution: Arch uses
# lib/wine, Debian lib/x86_64-linux-gnu/wine, Fedora lib64/wine. Hardcoding
# lib/wine builds a tree that Arch finds and Debian does not -- and the failure
# is the silent kind, because the loader simply falls back to the system tree.
REL_LIB="${SYS_LIB_ROOT#"$SYS_PREFIX"/}"
[[ "$REL_LIB" != "$SYS_LIB_ROOT" ]] || REL_LIB="lib/wine"   # loader outside the prefix; best effort
SYS_SHARE="$(readlink -f "$SYS_PREFIX/share/wine" 2>/dev/null || echo /usr/share/wine)"
REL_SHARE="share/wine"

# our patched files, and the marker that proves each one is ours
PATCHED_UNIX=( winealsa.so winex11.so mountmgr.so wineusb.so )
PATCHED_PE=( mountmgr.sys wineusb.sys )
declare -A MARKER=(
  [winealsa.so]=RBW-EVENT [winex11.so]=RBW-POPUP [mountmgr.so]=RBW-REMOVABLE
  [wineusb.so]=RBW-USBHCD [mountmgr.sys]=RBW-VOLNODE [wineusb.sys]=RBW-USBHCD
)

echo "system wine : $WINE_VER  ($SYS_LIB_ROOT)"
echo "layout      : \$prefix/$REL_LIB  — mirrored so the loader resolves it"
echo "private tree: $TREE"

for f in "${PATCHED_UNIX[@]}" "${PATCHED_PE[@]}"; do
  [[ -f "$SRCDIR/$f" ]] || { echo "missing patched build: $SRCDIR/$f — run bin/build-patched-dlls.sh" >&2; exit 1; }
  if [[ "$(strings -a "$SRCDIR/$f" | grep -c -- "${MARKER[$f]}" || true)" -eq 0 ]]; then
    echo "refusing: $SRCDIR/$f has no ${MARKER[$f]} marker, so it is not a patched build" >&2; exit 1
  fi
done

rm -rf "$TREE"
mkdir -p "$TREE/bin" "$TREE/$REL_LIB" "$TREE/$(dirname "$REL_SHARE")"

# Loader binaries: REAL copies. Wine resolves /proc/self/exe to find its tree,
# and a symlink here resolves to /usr/bin and defeats the whole exercise.
for b in wine wine64 wineserver wineboot winecfg wine-preloader wine64-preloader; do
  src="$(dirname "$WINE_BIN")/$b"
  [[ -e "$src" ]] && cp -a "$src" "$TREE/bin/" 2>/dev/null || true
done
[[ -x "$TREE/bin/wine" ]] || { echo "no wine loader copied from $(dirname "$WINE_BIN")" >&2; exit 1; }

# Everything else: symlinks, so the tree costs megabytes and tracks the system
# Wine file-for-file.
link_dir() {   # $1 = subdir under the lib root
  local sub="$1" s
  mkdir -p "$TREE/$REL_LIB/$sub"
  for s in "$SYS_LIB_ROOT/$sub"/*; do
    [[ -e "$s" ]] || continue
    ln -sfn "$(readlink -f "$s")" "$TREE/$REL_LIB/$sub/$(basename "$s")"
  done
}
for sub in "$SYS_LIB_ROOT"/*/; do link_dir "$(basename "$sub")"; done
for s in "$SYS_LIB_ROOT"/*; do
  [[ -f "$s" ]] && ln -sfn "$(readlink -f "$s")" "$TREE/$REL_LIB/$(basename "$s")"
done
ln -sfn "$SYS_SHARE" "$TREE/$REL_SHARE"

# The preloader must ALSO be a real copy, and this is the subtle one: `wine`
# execs wine-preloader, and from that moment Wine derives its tree from
# /proc/self/exe -- which is now the preloader. Leave it a symlink and the
# resolved path is /usr/lib/wine, so the loader walks straight back to the
# system tree and silently uses the STOCK libraries while every marker check
# still passes. Measured exactly that: rekordbox ran with
# exe=/usr/lib/wine/x86_64-unix/wine-preloader and mapped stock winealsa.
#
# ntdll.so has to be real for the same reason, one step further along: the
# loader dlopens it through our symlink, the kernel resolves that to
# /usr/lib/wine, and Wine then re-derives its tree from the *resolved* path and
# uses the system libraries for everything afterwards. Measured: with ntdll.so
# symlinked, a private tree with a real patched winex11.so still loaded the
# stock one, and every marker check still passed because the checks look at the
# file on disk rather than at what the process mapped.
#
# So: the loader chain (bin/wine*, wine-preloader, ntdll.so) must be real
# copies. Everything else can be a symlink, which is what keeps this at ~5 MB.
for core in "$SYS_LIB_ROOT"/*/wine*-preloader "$SYS_LIB_ROOT"/*/ntdll.so; do
  [[ -f "$core" ]] || continue
  rel="${core#$SYS_LIB_ROOT/}"
  rm -f "$TREE/$REL_LIB/$rel"
  cp -a "$core" "$TREE/$REL_LIB/$rel"
done

# Now the real files, replacing those symlinks.
u="$(basename "$WINE_UNIX_DIR")"; p="$(basename "$WINE_PE_DIR")"
for f in "${PATCHED_UNIX[@]}"; do rm -f "$TREE/$REL_LIB/$u/$f"; install -m644 "$SRCDIR/$f" "$TREE/$REL_LIB/$u/$f"; done
for f in "${PATCHED_PE[@]}";   do rm -f "$TREE/$REL_LIB/$p/$f"; install -m644 "$SRCDIR/$f" "$TREE/$REL_LIB/$p/$f"; done

echo "$WINE_VER" > "$TREE/.wine-version"
# Consumers must not guess the layout -- record it beside the tree.
echo "$REL_LIB" > "$TREE/.wine-layout"
echo
echo "built: $(du -sh "$TREE" | cut -f1) ($(find "$TREE" -type l | wc -l) symlinks, $(find "$TREE" -type f | wc -l) real files)"
for f in "${PATCHED_UNIX[@]}"; do printf "  %-14s %s\n" "$f" "${MARKER[$f]} verified"; done
for f in "${PATCHED_PE[@]}";   do printf "  %-14s %s\n" "$f" "${MARKER[$f]} verified"; done
echo
echo "The system Wine was not modified. Run against this tree with:"
echo "  $TREE/bin/wine <program>"
