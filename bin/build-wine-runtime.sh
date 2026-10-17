#!/usr/bin/env bash
# build-wine-runtime — build the complete Wine that rekordbox-wine ships, with
# the patch series compiled in, and install it into a DESTDIR.
#
# WHY THE PACKAGE CARRIES ITS OWN WINE. The series patches Wine internals, which
# change between releases. Patching the distro's Wine meant that every routine
# system update that moved Wine broke rekordbox: Arch moved wine-staging three
# times between 2026-08-27 and 2026-09-28, and each move needed a rebuild, a
# private symlink tree and an ABI gate (THEMES/T14, T15), all of which the user
# met as "rekordbox doesn't work again". A pinned Wine inside the package cannot
# be moved by anyone but this project.
#
# WHAT IS BUILT. Exactly the Wine in upstream/wine-runtime.conf:
#   1. the WineHQ source tarball, sha256-checked
#   2. the wine-staging patchset of the same version, sha256-checked, all of it,
#      because every measurement in this project was made on wine-staging
#   3. upstream/patches/0*.patch in order. Fuzz fails the build unless that exact
#      hunk is in upstream/patches/reviewed-fuzz.txt
#   4. the RBW-USBHCD splice (bin/splice-usbhcd.py)
# Configured in WoW64 mode (--enable-archs=i386,x86_64): 32-bit Windows programs
# run through 64-bit unix libraries, so no lib32 packages are needed.
#
# Every patched file is then checked for its marker IN THE INSTALLED TREE, and
# every unix library is checked for unresolved shared-library dependencies.
#
# Usage: bin/build-wine-runtime.sh <destdir>
#   The runtime lands at <destdir>$RUNTIME_PREFIX (/usr/lib/rekordbox-wine/wine).
# Env:   RBW_WINE_BUILD  download cache and build directory (default ~/.cache/rbw-runtime-build)
#        JOBS            parallel make jobs (default: nproc)
set -euo pipefail
DEST="${1:?usage: build-wine-runtime.sh <destdir>}"
mkdir -p "$DEST"; DEST="$(cd "$DEST" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
. "$ROOT/upstream/wine-runtime.conf"
CACHE="${RBW_WINE_BUILD:-$HOME/.cache/rbw-runtime-build}"
JOBS="${JOBS:-$(nproc)}"
SRC="$CACHE/wine-$WINE_VER-rbw"
P="$DEST$RUNTIME_PREFIX"
mkdir -p "$CACHE"

echo "wine runtime : $WINE_VER + staging + $(ls "$ROOT"/upstream/patches/0*.patch | wc -l) patches"
echo "build tree   : $SRC"
echo "installs to  : $P"

# ---------------------------------------------------------------- fetch
fetch() {   # url sha256 file
  local url="$1" sum="$2" out="$CACHE/$3"
  if [[ ! -f "$out" ]] || ! echo "$sum  $out" | sha256sum -c --status; then
    echo "fetching $url"
    curl -fL --retry 3 -o "$out.part" "$url"
    mv -f "$out.part" "$out"
  fi
  # A mismatched tarball is not "probably fine": it is not the Wine this
  # package claims to ship.
  echo "$sum  $out" | sha256sum -c --status \
    || { echo "sha256 mismatch for $out — expected $sum"; exit 1; }
}
fetch "$WINE_URL"    "$WINE_SHA256"    "wine-$WINE_VER.tar.xz"
fetch "$STAGING_URL" "$STAGING_SHA256" "wine-staging-$WINE_VER.tar.gz"
ADDONS=https://dl.winehq.org/wine
fetch "$ADDONS/wine-mono/$MONO_VER/wine-mono-$MONO_VER-x86.msi"           "$MONO_SHA256"         "wine-mono-$MONO_VER-x86.msi"
fetch "$ADDONS/wine-gecko/$GECKO_VER/wine-gecko-$GECKO_VER-x86.msi"       "$GECKO_X86_SHA256"    "wine-gecko-$GECKO_VER-x86.msi"
fetch "$ADDONS/wine-gecko/$GECKO_VER/wine-gecko-$GECKO_VER-x86_64.msi"    "$GECKO_X86_64_SHA256" "wine-gecko-$GECKO_VER-x86_64.msi"

# ---------------------------------------------------------------- source
# Always from scratch. A reused tree is how diagnostic code from one session
# ends up in the next session's package.
rm -rf "$SRC" "$CACHE/staging-$WINE_VER"
mkdir -p "$SRC" "$CACHE/staging-$WINE_VER"
tar -C "$SRC" --strip-components=1 -xf "$CACHE/wine-$WINE_VER.tar.xz"
tar -C "$CACHE/staging-$WINE_VER" --strip-components=1 -xzf "$CACHE/wine-staging-$WINE_VER.tar.gz"

echo
echo "=== wine-staging ==="
python3 "$CACHE/staging-$WINE_VER/staging/patchinstall.py" --all -d "$SRC" \
  >"$CACHE/staging.log" 2>&1 \
  || { echo "staging patchset failed to apply — see $CACHE/staging.log"; tail -5 "$CACHE/staging.log"; exit 1; }
echo "  applied ($(grep -c 'gitapply.sh' "$CACHE/staging.log") patches)"

echo
echo "=== patch series ==="
REVIEWED="$ROOT/upstream/patches/reviewed-fuzz.txt"
for p in "$ROOT"/upstream/patches/0*.patch; do
  name="$(basename "$p")"
  out="$(cd "$SRC" && patch -p1 -f --no-backup-if-mismatch < "$p" 2>&1)" \
    || { echo "  FAILED  $name"; echo "$out" | sed 's/^/      /'; exit 1; }
  echo "  applied $name"
  while read -r line; do
    if grep -qxF "$name $line" "$REVIEWED"; then
      echo "      fuzz, reviewed: $line"
    else
      echo "      UNREVIEWED FUZZ: $line"
      echo "  GNU patch ignored context lines that no longer match, so this hunk may"
      echo "  sit in code whose logic has changed. Read it in $SRC; if it is"
      echo "  harmless, add this exact line to $REVIEWED:"
      echo "    $name $line"
      exit 1
    fi
  done < <(grep "with fuzz" <<<"$out" || true)
done
python3 "$ROOT/bin/splice-usbhcd.py" "$ROOT/upstream/patches/rbw-usbhcd.c" "$SRC"

# ---------------------------------------------------------------- configure
cd "$SRC"
echo
echo "=== configure ==="
# No -g: this tree is shipped, not debugged, and debug info roughly triples the
# PE half. Unix libraries are stripped below in any case.
export CFLAGS="${CFLAGS:--O2 -pipe}" CROSSCFLAGS="${CROSSCFLAGS:--O2 -pipe}"
./configure --prefix="$RUNTIME_PREFIX" --libdir="$RUNTIME_PREFIX/lib" \
  --enable-archs=i386,x86_64 --disable-tests \
  --with-x --with-alsa --with-opengl --with-dbus --with-gnutls --with-freetype \
  --with-fontconfig --with-usb --with-udev \
  >"$CACHE/configure.log" 2>&1 \
  || { echo "configure failed — see $CACHE/configure.log:"; tail -6 "$CACHE/configure.log" | sed 's/^/    /'; exit 1; }

# configure does not fail when a library is missing: it prints a note and drops
# the feature. Each of these is a capability rekordbox is known to need, and a
# runtime without one is a package that installs, launches and is broken.
#   X/GL: the window (T01, issue #3)   ALSA: audio and MIDI (T03, T05)
#   libusb/udev: the DDJ-400 (T05)     dbus: removable drives (T02)
#   gnutls: HTTPS sign-in              freetype/fontconfig: any text at all
REQUIRED='libusb|libudev|gnutls|FreeType|fontconfig|OpenGL|EGL|Xrandr|XInput2|Xcursor|Xcomposite|Xext|X development|ALSA|dbus|MinGW|unrecognized options'
if grep -E "^configure: " "$CACHE/configure.log" | grep -Ei "$REQUIRED" | grep -vi "OSS"; then
  echo "configure dropped a feature rekordbox needs (above). Install its development"
  echo "package and rerun."
  exit 1
fi
echo "  ok — no required feature dropped"

# ---------------------------------------------------------------- build
echo
echo "=== build (-j$JOBS; the first build takes a while) ==="
make -j"$JOBS" >"$CACHE/build.log" 2>&1 \
  || { echo "build failed — see $CACHE/build.log"; grep -E "error|Error" "$CACHE/build.log" | tail -10; exit 1; }
rm -rf "$P"
make install DESTDIR="$DEST" >"$CACHE/install.log" 2>&1 \
  || { echo "install failed — see $CACHE/install.log"; tail -10 "$CACHE/install.log"; exit 1; }

# ---------------------------------------------------------------- trim
# Only what running a Windows program needs. The compilers and import
# libraries are for building against Wine; the .desktop files and man pages
# would register a second "Wine" with the desktop, with MIME types, which is
# exactly the cross-talk with the distro's Wine this package exists to avoid.
rm -rf "$P/include" "$P/share/man" "$P/share/applications"
for t in winegcc wineg++ winecpp winebuild winedump winemaker wmc wrc widl function_grep.pl; do
  rm -f "$P/bin/$t"
done
find "$P/lib/wine" -name '*.a' -delete
# Unix side only. PE files are not ELF and strip would corrupt them.
while IFS= read -r -d '' f; do
  [[ "$(head -c4 "$f" | od -An -tx1 | tr -d ' \n')" == 7f454c46 ]] && strip --strip-unneeded "$f" 2>/dev/null || true
done < <(find "$P/bin" "$P/lib/wine/x86_64-unix" -type f -print0)

# ---------------------------------------------------------------- addons
# Wine looks for these in <datadir>/wine/{mono,gecko} before it offers to
# download them (dlls/appwiz.cpl/addons.c). Without them every new prefix stops
# on a "Wine Mono Installer" prompt (THEMES/T21). The version must match the
# one this Wine was compiled to ask for, so it is checked against the source.
grep -q "MONO_VERSION \"$MONO_VER\"" dlls/mscoree/mscoree_private.h \
  || { echo "this Wine wants a different Wine Mono than $MONO_VER (dlls/mscoree/mscoree_private.h)"; exit 1; }
grep -q "GECKO_VERSION \"$GECKO_VER\"" dlls/appwiz.cpl/addons.c \
  || { echo "this Wine wants a different Wine Gecko than $GECKO_VER (dlls/appwiz.cpl/addons.c)"; exit 1; }
install -Dm644 "$CACHE/wine-mono-$MONO_VER-x86.msi"     "$P/share/wine/mono/wine-mono-$MONO_VER-x86.msi"
install -Dm644 "$CACHE/wine-gecko-$GECKO_VER-x86.msi"    "$P/share/wine/gecko/wine-gecko-$GECKO_VER-x86.msi"
install -Dm644 "$CACHE/wine-gecko-$GECKO_VER-x86_64.msi" "$P/share/wine/gecko/wine-gecko-$GECKO_VER-x86_64.msi"

# ---------------------------------------------------------------- stamps
# The shared libraries Wine dlopen()s by soname at run time. They are not in
# any ELF NEEDED list, so ldd never sees them; rbw-runtime-check checks these
# against the running system, because a distro soname bump (libgnutls.so.30 ->
# .31) would otherwise silently remove HTTPS, or GL, from a working install.
grep -E '^#define SONAME_' include/config.h | sed -E 's/^#define (SONAME_[A-Z0-9_]+) "(.*)"/\1 \2/' \
  > "$P/.rbw-sonames"

series_sum="$(cat "$ROOT"/upstream/patches/0*.patch "$ROOT/upstream/patches/rbw-usbhcd.c" | sha256sum | cut -c1-16)"
cat > "$P/.rbw-runtime" <<EOF
wine=$WINE_VER
flavour=staging
series=$series_sum
EOF
# ---------------------------------------------------------------- verify
echo
echo "=== verify the installed tree ==="
# The marker list lives in one place, shared with check() and every CI job.
"$ROOT/packaging/verify-tree.sh" "$DEST" || exit 1
# Every unix library must resolve on THIS system -- except Wine's own ntdll.so
# and win32u.so, which Wine loads itself from the same directory and ldd
# therefore cannot find. (The first version of this check failed on exactly
# those, for every library in the tree.)
"$ROOT/bin/rbw-runtime-check" "$P" || { echo "VERIFY FAILED: the runtime cannot load on this system"; exit 1; }

echo
echo "runtime ok: $(du -sh "$P" | cut -f1) at $P"
echo "  $(cat "$P/.rbw-runtime" | tr '\n' ' ')"
