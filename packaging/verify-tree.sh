#!/usr/bin/env bash
# verify-tree — does a staged or packaged tree carry a PATCHED Wine runtime?
#
# THE ONE LIST of what "patched" means, by marker string. Called by
# bin/build-wine-runtime.sh on the tree it installs, by the PKGBUILD's check(),
# and by every CI job on the files extracted from the finished .pkg/.deb/.rpm.
# Before this file existed the same list was written out in five places, and
# a list that is missing a component in one of them is a package that ships it
# stock -- which loads perfectly and behaves as though nothing was fixed.
#
# Usage: packaging/verify-tree.sh <root>
#   <root> is what /usr would be relative to: a DESTDIR, an extracted package,
#   or / for the installed system.
set -uo pipefail
ROOT="${1:?usage: verify-tree.sh <root>}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. upstream/wine-runtime.conf
RT="$ROOT$RUNTIME_PREFIX"
fail=0

need() {   # <path under lib/wine> <marker>
  local f="$RT/lib/wine/$1"
  if [[ ! -f "$f" ]]; then echo "  MISSING   $1"; fail=1; return; fi
  # Count, not grep -q: grep exits early, strings dies of SIGPIPE, and under
  # pipefail the check fails on success.
  if [[ "$(strings -a "$f" | grep -c -- "$2" || true)" -eq 0 ]]; then
    echo "  NO MARKER $1 ($2) — stock build?"; fail=1
  else
    echo "  ok  $1  ($2)"
  fi
}

[[ -x "$RT/bin/wine" ]] || { echo "  MISSING   $RUNTIME_PREFIX/bin/wine"; fail=1; }
need x86_64-windows/dxgi.dll       RBW-PATCH                  # T01 WaitForVBlank
need x86_64-windows/mmdevapi.dll   RBW-MMDEV                  # T03 exclusive events
need x86_64-windows/setupapi.dll   PhysicalDeviceObjectName   # T02 volume matching
need x86_64-windows/mountmgr.sys   RBW-BUSTYPE                # T02
need x86_64-windows/mountmgr.sys   RBW-VOLNODE                # T02
need x86_64-windows/wineusb.sys    RBW-USBHCD                 # T05 \\.\HCDn
need x86_64-unix/winealsa.so       RBW-EVENT3                 # T03
need x86_64-unix/winealsa.so       alsa_rawmidi_open          # T05 SysEx/rawmidi
need x86_64-unix/winex11.so        RBW-POPUP                  # T04 menus
need x86_64-unix/winex11.so        '^glX'                     # issue #3: GL present
need x86_64-unix/mountmgr.so       RBW-REMOVABLE              # T02
need x86_64-unix/wineusb.so        RBW-USBHCD                 # T05
# WoW64: the 32-bit half must exist, or 32-bit installers cannot run.
need i386-windows/ntdll.dll        'Wine builtin DLL'

for f in .rbw-runtime .rbw-sonames; do
  [[ -s "$RT/$f" ]] && echo "  ok  $f" || { echo "  MISSING   $f"; fail=1; }
done
if [[ -s "$RT/.rbw-runtime" ]] && ! grep -qx "wine=$WINE_VER" "$RT/.rbw-runtime"; then
  echo "  .rbw-runtime says $(grep '^wine=' "$RT/.rbw-runtime"), the pin is $WINE_VER"; fail=1
fi
# The trim in build-wine-runtime.sh: a runtime that ships Wine's .desktop
# files registers a second "Wine" with the desktop and its MIME types.
[[ -d "$RT/share/applications" ]] && { echo "  runtime ships share/applications"; fail=1; }
# T21: without these a new prefix stops on a download prompt.
for f in "mono/wine-mono-$MONO_VER-x86.msi" "gecko/wine-gecko-$GECKO_VER-x86.msi" "gecko/wine-gecko-$GECKO_VER-x86_64.msi"; do
  [[ -s "$RT/share/wine/$f" ]] && echo "  ok  share/wine/$f" || { echo "  MISSING   share/wine/$f (THEMES/T21)"; fail=1; }
done

[[ $fail -eq 0 ]] && echo "runtime verified: $RT" || echo "VERIFY FAILED: $RT"
exit $fail
