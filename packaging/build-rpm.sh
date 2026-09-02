#!/usr/bin/env bash
# build-rpm — build the Fedora package.
#
# The spec uses %autosetup, so it needs a source tarball whose top-level
# directory is rekordbox-wine-<version>. This makes one from the working tree
# and runs rpmbuild against it.
#
# Wine: needs the version in upstream/patches/supported-wine.txt. Fedora 43 is
# the first release that can reach it (own wine 11.0, WineHQ 11.16); on Fedora
# 41 and 42 the newest WineHQ builds are 10.18 and 11.8, which are too old.
#   https://gitlab.winehq.org/wine/wine/-/wikis/Fedora
#
# Usage: packaging/build-rpm.sh [outdir]
set -euo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
OUT="${1:-}"

command -v rpmbuild >/dev/null || {
  echo "build-rpm: rpmbuild not found. Install: sudo dnf install rpm-build rpmdevtools" >&2
  exit 1; }

VER="$(awk -F'[ \t]+' '/^Version:/{print $2; exit}' packaging/rekordbox-wine.spec)"
[[ -n "$VER" ]] || { echo "build-rpm: cannot read Version: from the spec" >&2; exit 1; }

rpmdev-setuptree
TARBALL="$HOME/rpmbuild/SOURCES/rekordbox-wine-$VER.tar.gz"
tar --transform "s,^\.,rekordbox-wine-$VER," \
    --exclude=.git --exclude=./runs --exclude=./prefixes --exclude=./debian \
    -czf "$TARBALL" .
echo "source: $TARBALL"

rpmbuild -bb packaging/rekordbox-wine.spec

FOUND="$(find "$HOME/rpmbuild/RPMS" -name "rekordbox-wine-$VER*.rpm" | head -1)"
if [[ -n "$OUT" && -n "$FOUND" ]]; then
  mkdir -p "$OUT"; cp -f "$FOUND" "$OUT/"; FOUND="$OUT/$(basename "$FOUND")"
fi
echo; echo "built: ${FOUND:-nothing}"
