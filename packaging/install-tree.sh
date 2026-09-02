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

# Sourced by every script below to locate Wine's library directories, which sit
# somewhere different on every distro. It must ship beside them.
install -Dm755 bin/winepaths.sh                   "$share/bin/winepaths.sh"
# Builds the private Wine tree: symlinks to the system Wine plus our six patched
# files. This replaces install-system-wine-patches.sh and install-wineusb-hcd.sh,
# which overwrote files owned by the distro's wine package -- a file conflict, a
# change undone by every wine upgrade, and a behaviour change forced on every
# other Wine application on the machine. Neither is shipped any more.
install -Dm755 bin/make-private-wine.sh           "$share/bin/make-private-wine.sh"
# Reads /proc/<pid>/maps to check what a RUNNING process mapped, which is the
# only check that cannot pass while the fixes are inactive.
install -Dm755 bin/verifyloaded.sh                "$share/bin/verifyloaded.sh"
install -Dm755 bin/build-patched-dlls.sh          "$share/bin/build-patched-dlls.sh"
install -Dm755 bin/build-wineusb-hcd.sh           "$share/bin/build-wineusb-hcd.sh"
install -Dm755 bin/rbclean.sh                     "$share/bin/rbclean.sh"
install -Dm755 bin/pdbcheck.py                    "$share/bin/pdbcheck.py"

# PE builtins, overridden per-prefix by the launcher.
install -dm755 "$share/artifacts"
install -m644 artifacts/*-patched-native-*.dll    "$share/artifacts/"

# Unix-side and driver libraries. Deliberately NOT installed over the system
# files by the package -- they are owned by the distro's wine package, and a
# file conflict (or a silent overwrite undone by the next wine upgrade) is worse
# than asking the user to run one script. Files only: artifacts/winedll/bisect/
# holds historical builds and `install` on a directory fails the build.
install -dm755 "$share/winedll"
install -m644 artifacts/winedll/*.so artifacts/winedll/*.sys "$share/winedll/"
# The Wine version these were COMPILED against. Without it, make-private-wine.sh
# cannot tell a matching set from a stale one, and on 2026-09-02 it assembled
# 11.15 libraries into an 11.16 tree, stamped the tree 11.16, and produced an
# install that passed every check and would not start. See THEMES/T14.
install -m644 artifacts/winedll/.built-for-wine    "$share/winedll/.built-for-wine"

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
EOF

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
# Which rekordbox versions have been measured. The launcher reads this at
# startup to say whether the version you are running has been through the
# acceptance tests -- it warns, it does not refuse. It lives beside the docs
# rather than under patches/ because it constrains nothing about the build.
install -m644 upstream/supported-rekordbox.txt "$share/supported-rekordbox.txt"
install -m644 upstream/supported-rekordbox.txt "$doc/supported-rekordbox.txt"
for n in upstream/reports/NOTES-*.md; do [[ -f "$n" ]] && install -m644 "$n" "$doc/patches/"; done

echo "staged rekordbox-wine into $DEST"
