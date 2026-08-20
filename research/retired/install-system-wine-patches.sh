#!/usr/bin/env bash
#
# install-system-wine-patches — replace the SYSTEM Wine libraries that cannot be
# overridden from inside a prefix, keeping a backup of each beside it.
#
# Wine's DllOverrides mechanism only reaches PE modules loaded out of the
# prefix. The unix-side libraries below are loaded by Wine from its own lib
# directory; DllOverrides does not apply and WINEDLLPATH does not cover them
# either (measured — the AUDCLNT_E_BUFFER_TOO_LARGE refusal count was unchanged
# at 343). So they have to replace the system files, which means root, which is
# why this is a separate script that reports every change and can undo it.
#
#   winealsa.so   0003  signal the client event only when a period is actually
#                       free. Stock winealsa signals once per period regardless,
#                       so a client that trusts the "a buffer is ready" contract
#                       asks for a full period and is refused. Measured on a
#                       DDJ-400 at 44100 Hz: 343 refusals across 344 periods;
#                       with the patch, zero.
#                 0004  name MIDI ports the way Windows does. Stock reports
#                       "DDJ-400 - DDJ-400 MIDI 1"; Windows reports "DDJ-400",
#                       and rekordbox keys its mapping profiles on that string.
#
#   winex11.so    0005  do not hand popup menus and their drop shadows to the
#                       window manager. Managed, KWin gave them a frame and
#                       placed them offscreen, so the File menu and the
#                       view-mode selector — which gates EXPORT mode — never
#                       appeared.
#
#   mountmgr.so   0006  a removable UDisks drive whose media type is unknown is
#                       still a removable drive, not "no media".
#   mountmgr.sys  0007  report an honest STORAGE_DEVICE_DESCRIPTOR: removable
#                       media, bus type USB.
#                 0009  publish STORAGE\Volume device nodes so that a volume can
#                       be found by SetupAPI at all. Without them rekordbox's
#                       device list is empty however healthy the mount is: it
#                       intersects the SetupAPI volume enumeration with
#                       GetDriveType, and an empty intersection is an empty USB
#                       panel.
#
# Every one of these files is owned by the `wine` package, so a wine upgrade
# silently reverts them. The launcher checks the markers on every start and says
# so. The real fix is upstream, which is why upstream/ exists.
#
# Reversal:  sudo research/retired/install-system-wine-patches.sh --revert
set -euo pipefail

. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/winepaths.sh"
UNIX_DIR="$WINE_UNIX_DIR"
PE_DIR="$WINE_PE_DIR"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# In the source tree the builds land in artifacts/winedll; the package installs
# them to /usr/share/rekordbox-wine/winedll. Look in both, because getting this
# wrong makes the script fail only on a real installed system -- the one place
# it is never run during development.
if [[ -n "${RBW_WINEDLL_DIR:-}" ]]; then
  SRCDIR="$RBW_WINEDLL_DIR"
elif [[ -d "$HERE/artifacts/winedll" ]]; then
  SRCDIR="$HERE/artifacts/winedll"
else
  SRCDIR="$HERE/winedll"
fi

# file : destination dir : marker that proves the build is ours
FILES=(
  "winealsa.so:$UNIX_DIR:RBW-EVENT"
  "winex11.so:$UNIX_DIR:RBW-POPUP"
  "mountmgr.so:$UNIX_DIR:RBW-REMOVABLE"
  "mountmgr.sys:$PE_DIR:RBW-VOLNODE"
)

has_marker() { [[ "$(strings -a "$1" | grep -c -- "$2" || true)" -gt 0 ]]; }

if [[ "${1:-}" == --revert ]]; then
  [[ $EUID -eq 0 ]] || { echo "needs root: sudo $0 --revert" >&2; exit 1; }
  n=0
  for spec in "${FILES[@]}"; do
    IFS=: read -r f dir _ <<<"$spec"
    if [[ -f "$dir/$f.rbw-backup" ]]; then
      mv -f "$dir/$f.rbw-backup" "$dir/$f"; echo "reverted $dir/$f"; n=$((n+1))
    fi
  done
  [[ $n -gt 0 ]] || echo "no backups found — nothing to revert"
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "needs root: sudo $0" >&2; exit 1; }

for spec in "${FILES[@]}"; do
  IFS=: read -r f dir marker <<<"$spec"
  src="$SRCDIR/$f" dst="$dir/$f" backup="$dir/$f.rbw-backup"

  [[ -f "$src" ]] || { echo "no patched build at $src — run bin/build-patched-dlls.sh" >&2; exit 1; }
  [[ -f "$dst" ]] || { echo "no system $f at $dst" >&2; exit 1; }

  # Refuse to overwrite a file that is not ours with one that is unmarked --
  # that would lose the real system file behind a backup of a patched build.
  has_marker "$src" "$marker" \
    || { echo "refusing: $src has no $marker marker, so it is not a patched build" >&2; exit 1; }

  if [[ -f "$backup" ]]; then
    echo "$f: backup already present (keeping the original stock file)"
  else
    cp -a "$dst" "$backup"; echo "$f: backed up stock file -> $backup"
  fi

  install -m644 "$src" "$dst"
  if has_marker "$dst" "$marker"; then
    echo "$f: installed and verified ($marker present)"
  else
    echo "$f: VERIFY FAILED — restoring backup" >&2; mv -f "$backup" "$dst"; exit 1
  fi
done

echo
echo "Revert at any time with:  sudo $0 --revert"
