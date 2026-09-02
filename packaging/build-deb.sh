#!/usr/bin/env bash
# build-deb — build the Debian package.
#
# WHY THIS EXISTS. dpkg-buildpackage requires debian/ at the SOURCE ROOT, and
# this repository keeps packaging under packaging/ so the three formats sit
# together. packaging/debian/ therefore has to be staged to ./debian before a
# build. Without this step dpkg-buildpackage stops at
# "cannot open file debian/changelog", which is how these files sat unbuilt.
#
# Wine: needs the version in upstream/patches/supported-wine.txt. Debian's own
# wine is too old (trixie ships 10.0); use the WineHQ repository:
#   https://gitlab.winehq.org/wine/wine/-/wikis/Debian-Ubuntu
#
# Usage: packaging/build-deb.sh [outdir]     (default: ../ , as dpkg does)
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
ROOT="$PWD"
OUT="${1:-}"

command -v dpkg-buildpackage >/dev/null || {
  echo "build-deb: dpkg-buildpackage not found. Install: sudo apt install devscripts debhelper" >&2
  exit 1; }

# Stage packaging/debian -> debian, and take it away again afterwards so a
# source tree is never left with a half-real debian/ directory in it.
if [[ -e debian && ! -e .rbw-staged-debian ]]; then
  echo "build-deb: a debian/ directory already exists here and is not ours; refusing" >&2
  exit 1
fi
cleanup() { rm -rf "$ROOT/debian" "$ROOT/.rbw-staged-debian"; }
trap cleanup EXIT
cp -r packaging/debian "$ROOT/debian"
touch "$ROOT/.rbw-staged-debian"

dpkg-buildpackage -us -uc -b

# dpkg writes the .deb beside the source tree.
if [[ -n "$OUT" ]]; then
  mkdir -p "$OUT"
  mv -f ../rekordbox-wine_*.deb ../rekordbox-wine_*.buildinfo ../rekordbox-wine_*.changes "$OUT/" 2>/dev/null || true
  echo; echo "built: $(ls "$OUT"/rekordbox-wine_*.deb 2>/dev/null)"
else
  echo; echo "built: $(ls ../rekordbox-wine_*.deb 2>/dev/null)"
fi
