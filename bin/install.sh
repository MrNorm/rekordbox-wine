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

# ---------------------------------------------------------------- preflight
#
# Report EVERYTHING that is wrong, then stop -- rather than dying on the first
# missing thing, which makes a user fix one problem, re-run, and meet the next.
# Each failure carries the command that fixes it.
PASS=$'\033[32m✓\033[0m'; FAILM=$'\033[31m✗\033[0m'; WARNM=$'\033[33m!\033[0m'
PROBLEMS=0
declare -a REMEDY=()
ck()   { printf '  %s %s\n' "$PASS" "$*"; }
ckno() { printf '  %s %s\n' "$FAILM" "$1"; shift; [[ $# -gt 0 ]] && REMEDY+=("$*"); PROBLEMS=$((PROBLEMS+1)); }
ckwarn() { printf '  %s %s\n' "$WARNM" "$*"; }

echo "Checking prerequisites"

# Architecture. The patched components are x86_64 PE and unix libraries.
ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" ]]; then ck "architecture $ARCH"
else ckno "architecture $ARCH — only x86_64 is built"; fi

# Package manager, and therefore which distribution path applies. Resolved
# BEFORE anything else that gives advice: telling a Debian user to run
# `pacman -S curl` is worse than saying nothing.
DISTRO=""; INSTALL_CMD=""
if   command -v pacman  >/dev/null; then DISTRO=arch; INSTALL_CMD="sudo pacman -S"
elif command -v apt-get >/dev/null; then DISTRO=deb;  INSTALL_CMD="sudo apt install"
elif command -v dnf     >/dev/null; then DISTRO=rpm;  INSTALL_CMD="sudo dnf install"
elif command -v zypper  >/dev/null; then DISTRO=rpm;  INSTALL_CMD="sudo zypper install"
fi
case "$DISTRO" in
  arch) ck "Arch (pacman)" ;;
  deb|rpm)
    ckno "no prebuilt package for this distribution yet" \
         "Build from source: https://github.com/$REPO#build-from-source" ;;
  *)
    ckno "could not identify the package manager" \
         "Build from source: https://github.com/$REPO#build-from-source" ;;
esac

WINE_PKG="wine-staging"; [[ "$DISTRO" == deb || "$DISTRO" == rpm ]] && WINE_PKG="winehq-staging"

command -v curl >/dev/null && ck "curl" \
  || ckno "curl is missing" "${INSTALL_CMD:-install} curl"

if command -v sudo >/dev/null; then ck "sudo"
else ckno "sudo is missing — installing the package needs root" \
          "Install sudo, or run the package manager as root yourself"; fi

# Wine, and whether it is a version something was built for.
WINE_VER=""
if command -v wine >/dev/null; then
  WINE_VER="$(wine --version 2>/dev/null | sed 's/^wine-//;s/ .*//')"
  if [[ -n "$WINE_VER" ]]; then
    ck "wine $WINE_VER"
    wine --version 2>/dev/null | grep -qi staging \
      || ckwarn "this is not wine-staging; every measurement in this project was made on staging"
  else
    ckno "'wine --version' produced nothing" "Reinstall Wine: ${INSTALL_CMD:-install} $WINE_PKG"
  fi
else
  ckno "wine is not installed" "${INSTALL_CMD:-install} $WINE_PKG"
fi

# Disk. The package is small; rekordbox itself is not, and this is the last
# comfortable moment to say so.
FREE_MB="$(df -Pm /tmp 2>/dev/null | awk 'NR==2{print $4}')"
if [[ -n "$FREE_MB" && "$FREE_MB" -lt 200 ]]; then
  ckno "only ${FREE_MB} MB free on /tmp" "Free some space; the download needs ~200 MB"
elif [[ -n "$FREE_MB" ]]; then ck "disk space on /tmp (${FREE_MB} MB free)"; fi

if [[ $PROBLEMS -gt 0 ]]; then
  echo
  printf '\033[31m%s\033[0m\n' "$PROBLEMS thing(s) need fixing first:"
  for r in "${REMEDY[@]}"; do printf '  · %s\n' "$r"; done
  echo
  exit 1
fi
echo

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
