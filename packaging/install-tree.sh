#!/usr/bin/env bash
# install-tree — stage the whole rekordbox-wine payload into a DESTDIR.
#
# ONE definition of what the package contains, called by all three packaging
# formats: PKGBUILD's package(), debian/rules, and the rpm %install scriptlet.
# Three hand-maintained copies of this list would drift, and a file quietly
# missing from one of them is precisely the failure this project keeps paying
# for -- the launcher demanding DLLs nothing built any more, the winedll
# directory that only existed in the source layout.
#
# Usage: packaging/install-tree.sh <destdir>
#        run from the source root, after bin/build-patched-dlls.sh
set -euo pipefail
DEST="${1:?usage: install-tree.sh <destdir>}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PKG=rekordbox-wine
share="$DEST/usr/share/$PKG"
doc="$DEST/usr/share/doc/$PKG"

install -Dm755 bin/rekordbox-wine                 "$DEST/usr/bin/rekordbox-wine"

# THE WINE RUNTIME: a complete Wine 11.18-staging with the series compiled in,
# built by bin/build-wine-runtime.sh into build/runtime. rekordbox runs on this
# and never on the distro's Wine, so a system update that moves Wine cannot
# break it (THEMES/T19). Until 2026-10-17 the package shipped only the patched
# files and assembled a private tree around the SYSTEM Wine -- which broke on
# every Wine upgrade (T14, T15).
RUNTIME_STAGE="${RBW_RUNTIME_STAGE:-build/runtime}"
. upstream/wine-runtime.conf
[[ -x "$RUNTIME_STAGE$RUNTIME_PREFIX/bin/wine" && -f "$RUNTIME_STAGE$RUNTIME_PREFIX/.rbw-runtime" ]] || {
  echo "no built runtime at $RUNTIME_STAGE$RUNTIME_PREFIX — run bin/build-wine-runtime.sh $RUNTIME_STAGE first" >&2
  exit 1; }
install -dm755 "$DEST$(dirname "$RUNTIME_PREFIX")"
cp -a "$RUNTIME_STAGE$RUNTIME_PREFIX" "$DEST$RUNTIME_PREFIX"

# Reads /proc/<pid>/maps to check what a RUNNING process mapped, which is the
# only check that cannot pass while the fixes are inactive.
install -Dm755 bin/verifyloaded.sh                "$share/bin/verifyloaded.sh"
# Can the runtime still load its system libraries? Run by the launcher on every
# start and by the pacman hook below after every transaction.
install -Dm755 bin/rbw-runtime-check              "$share/bin/rbw-runtime-check"
install -Dm755 bin/rbclean.sh                     "$share/bin/rbclean.sh"
# Finds and downloads the latest rekordbox installer from rekordbox.com, which
# is what `rekordbox-wine --install` with no argument calls.
install -Dm755 bin/fetch-rekordbox.sh             "$share/bin/fetch-rekordbox.sh"
# The one-line installer, shipped so an installed copy can be inspected offline.
install -Dm755 bin/install.sh                     "$share/bin/install.sh"
install -Dm755 bin/pdbcheck.py                    "$share/bin/pdbcheck.py"

install -Dm644 packaging/60-pioneer-ddj.rules \
               "$DEST/usr/lib/udev/rules.d/60-pioneer-ddj.rules"

install -Dm644 /dev/stdin "$DEST/usr/lib/modprobe.d/$PKG.conf" <<'EOF'
# rekordbox binds the first MIDI device it enumerates. snd_seq_dummy's
# "Midi Through" loopback sorts ahead of real hardware, so rekordbox talks to
# the loopback and nothing reaches the controller.
blacklist snd_seq_dummy
EOF

install -Dm644 /dev/stdin "$DEST/usr/lib/modules-load.d/$PKG.conf" <<'EOF'
# Kernel-side Windows sync primitives. Without this every wait in rekordbox is a
# wineserver round-trip and the UI is laggy. wineserver opens /dev/ntsync once
# at startup and caches it, so this must be loaded before the first Wine start.
ntsync
# The controller's MIDI sequencer port and its audio interface. Both are
# normally loaded on demand when the DDJ is plugged in -- which fails after a
# kernel upgrade without a reboot, because the running kernel's module tree has
# been deleted. Loading them at boot means they are already in memory when that
# happens (THEMES/T16).
snd_seq_midi
snd_usb_audio
EOF

# After every pacman transaction, check that the runtime's system libraries
# still resolve and that a kernel upgrade has not left the controller without
# its MIDI driver. Silent when healthy. Arch only: dpkg and rpm have no general
# post-transaction hook, and the launcher runs the same check on every start.
if [[ "${RBW_ALPM_HOOK:-1}" == 1 ]]; then
  install -Dm644 packaging/rekordbox-wine.hook "$DEST/usr/share/libalpm/hooks/rekordbox-wine.hook"
fi

install -Dm644 /dev/stdin "$DEST/usr/share/applications/$PKG.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=rekordbox (Wine)
Comment=DJ software for the DDJ-400, with the Wine fixes it needs
Exec=rekordbox-wine
Terminal=false
Categories=AudioVideo;Audio;Music;
StartupWMClass=rekordbox.exe
EOF

install -Dm644 README.md "$doc/README.md"
install -Dm644 LICENSE   "$doc/LICENSE"
for f in docs/*.md; do [[ -f "$f" ]] && install -Dm644 "$f" "$doc/$(basename "$f")"; done
install -dm755 "$doc/THEMES"
install -m644 docs/investigation/THEMES/T*.md "$doc/THEMES/"

# The patches, so anyone can rebuild them or send them upstream.
install -dm755 "$doc/patches"
install -m644 upstream/patches/0*.patch "$doc/patches/"
install -m644 upstream/patches/rbw-usbhcd.c "$doc/patches/"
install -m644 upstream/patches/supported-wine.txt "$doc/patches/"
install -m644 upstream/patches/reviewed-fuzz.txt "$doc/patches/"
install -m644 upstream/wine-runtime.conf "$doc/patches/"
# Which rekordbox versions have been measured. The launcher reads this at
# startup to say whether the version you are running has been through the
# acceptance tests -- it warns, it does not refuse. It lives beside the docs
# rather than under patches/ because it constrains nothing about the build.
install -m644 upstream/supported-rekordbox.txt "$share/supported-rekordbox.txt"
install -m644 upstream/supported-rekordbox.txt "$doc/supported-rekordbox.txt"
for n in upstream/reports/NOTES-*.md; do [[ -f "$n" ]] && install -m644 "$n" "$doc/patches/"; done

echo "staged rekordbox-wine into $DEST"
