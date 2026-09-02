#!/usr/bin/env bash
# install.sh — install the rekordbox-wine package built for the Wine you have.
#
#   curl -fsSL https://raw.githubusercontent.com/MrNorm/rekordbox-wine/master/bin/install.sh | bash
#
# Picks the release asset matching your wine-staging version, verifies it
# against the release's SHA256SUMS, and installs it. The patched libraries are
# compiled against Wine internals and are valid for one Wine version only, which
# is why the asset is chosen by version rather than "latest".
#
# Falls back to nothing: if no asset matches, it says so and prints the
# from-source command rather than installing something that cannot work.
set -uo pipefail

REPO="${RBW_REPO:-MrNorm/rekordbox-wine}"
API="https://api.github.com/repos/$REPO/releases/latest"

die() { printf '\033[31merror\033[0m  %s\n' "$*" >&2; exit 1; }
say() { printf '\033[32m==>\033[0m %s\n' "$*"; }

command -v curl    >/dev/null || die "curl is required"
command -v pacman  >/dev/null || die "this installer is for Arch. Other distributions: build from source, see the README."
command -v wine    >/dev/null || die "wine is not installed. Install wine-staging first: sudo pacman -S wine-staging"

WINE_VER="$(wine --version 2>/dev/null | sed 's/^wine-//;s/ .*//')"
[[ -n "$WINE_VER" ]] || die "could not read 'wine --version'"
say "wine $WINE_VER"

JSON="$(curl -fsSL "$API")" || die "could not reach the GitHub releases API"
TAG="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' <<<"$JSON" | head -1)"

urls() { grep -oE '"browser_download_url": *"[^"]+"' <<<"$JSON" | cut -d'"' -f4; }
SUM_URL="$(urls | grep -E '/SHA256SUMS$' | head -1)"
[[ -n "$SUM_URL" ]] || die "release $TAG has no SHA256SUMS; refusing to install unverified"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/SHA256SUMS" "$SUM_URL" || die "could not fetch SHA256SUMS"

# SHA256SUMS is the authority on WHICH asset to take, not just on its hash.
# A release can carry more than one package -- a re-run of the release workflow
# appends a second build -- and picking the first name that matches the Wine
# version can land on one the checksum file does not cover. Then the only thing
# standing between a curl|bash and an unverified binary is a warning nobody
# reads. So: choose from the checksum file, or stop.
PKG_NAME="$(awk '{sub(/^\*/,"",$2); print $2}' "$TMP/SHA256SUMS" \
            | grep -F -- "-wine${WINE_VER}.pkg.tar.zst" | head -1)"
PKG_URL=""
[[ -n "$PKG_NAME" ]] && PKG_URL="$(urls | grep -F -- "/$PKG_NAME" | head -1)"
if [[ -n "$PKG_NAME" && -z "$PKG_URL" ]]; then
  die "SHA256SUMS lists $PKG_NAME but the release has no such asset"
fi

if [[ -z "$PKG_URL" ]]; then
  cat >&2 <<MSG

No package in $TAG was built for wine $WINE_VER.

The patched Wine components only work with the Wine they were compiled against,
so installing another build would give you an application that starts and does
not render. Build against your Wine instead — 20-30 minutes, no root for the
build itself:

  git clone https://github.com/$REPO.git
  cd rekordbox-wine/packaging && makepkg -si

MSG
  exit 1
fi

PKG="$TMP/$PKG_NAME"

say "$TAG — $PKG_NAME"
curl -fL# -o "$PKG" "$PKG_URL" || die "download failed"

want="$(awk -v f="$PKG_NAME" '{sub(/^\*/,"",$2)} $2==f {print $1}' "$TMP/SHA256SUMS" | head -1)"
got="$(sha256sum "$PKG" | cut -d' ' -f1)"
[[ -n "$want" ]] || die "no checksum for $PKG_NAME"
[[ "$want" == "$got" ]] || die "checksum mismatch — expected $want, got $got"
say "sha256 verified"

say "installing (needs sudo)"
sudo pacman -U --noconfirm "$PKG" || die "pacman failed"

cat <<'MSG'

Installed. Two commands, neither needs root:

  rekordbox-wine --install     download and install rekordbox itself
  rekordbox-wine               launch

MSG
