#!/usr/bin/env bash
# build-wineusb-hcd — build a wineusb.sys that exposes \\.\HCDn to user mode.
#
# WHY
#
# rekordbox identifies a Pioneer controller over HID, builds the right
# per-model object (djplay::MidiMapDDJ400), and then validates it by walking the
# USB bus the way usbview.exe does: CreateFile on \\.\HCD0..\\.\HCD9, then the
# USB hub IOCTLs, to read the device's bcdDevice. Wine has no \\.\HCDn device
# object at all, so all ten opens fail with STATUS_OBJECT_NAME_NOT_FOUND, the
# validation returns negative, and rekordbox destroys the device object it just
# built and never opens the controller's MIDI port.
#
# Measured in runs/20260813T163916-hidopen/wine.log: ten CreateFileW on HCD0..9,
# ten x status c0000034, and zero midiInOpen calls in the whole run.
#
# WHAT THIS BUILDS
#
# unixlib.c/h gain a sysfs-backed enumeration (unix_usb_enum_hcd) and wineusb.c
# gains the device objects and IOCTL handlers, spliced in from
# upstream/rbw-usbhcd.c so the change stays reviewable in one place.
#
# Both halves have to be rebuilt and installed: wineusb.sys is the PE driver and
# wineusb.so is its unix side, and they must match.
#
# Usage: bin/build-wineusb-hcd.sh          build only, into artifacts/winedll/
#        sudo bin/install-wineusb-hcd.sh   install (separate, asks for root)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
CACHE="${RBW_WINE_BUILD:-$HOME/.cache/rbw-wine-build}"
WINE_VER="${WINE_VER:-$(wine --version 2>/dev/null | sed 's/^wine-//;s/ .*//')}"
SRC="$CACHE/wine-$WINE_VER"
MARKER="RBW-USBHCD"

[[ -d "$SRC" ]] || { echo "no wine source at $SRC — run bin/build-patched-dlls.sh first"; exit 1; }
cd "$SRC"

# ---------------------------------------------------------------- splice
# Idempotent: if the marker is already in wineusb.c the splice has been done.
if grep -q "$MARKER" dlls/wineusb.sys/wineusb.c; then
  echo "wineusb.c already carries the $MARKER block"
else
  echo "splicing $ROOT/upstream/rbw-usbhcd.c into dlls/wineusb.sys/wineusb.c"
  python3 - "$ROOT/upstream/rbw-usbhcd.c" <<'PY'
import sys, re
block = open(sys.argv[1]).read()
p = "dlls/wineusb.sys/wineusb.c"
s = open(p).read()

# 1. the implementation goes after the driver-wide statics, which is the first
#    point where DEVICE_OBJECT and the unixlib are both available.
anchor = "static DRIVER_OBJECT *driver_obj;\nstatic DEVICE_OBJECT *bus_fdo, *bus_pdo;\n"
assert anchor in s, "static declarations not found - has wineusb.c changed?"
s = s.replace(anchor, anchor + "\n" + block + "\n", 1)

# 2. wire the dispatch entries and create the devices. wineusb.sys previously
#    handled only IRP_MJ_PNP and IRP_MJ_INTERNAL_DEVICE_CONTROL, so CREATE,
#    CLOSE and DEVICE_CONTROL are additive and cannot change existing paths.
old = """    driver->DriverExtension->AddDevice = driver_add_device;
    driver->DriverUnload = driver_unload;
    driver->MajorFunction[IRP_MJ_PNP] = driver_pnp;
    driver->MajorFunction[IRP_MJ_INTERNAL_DEVICE_CONTROL] = driver_internal_ioctl;
"""
new = """    driver->DriverExtension->AddDevice = driver_add_device;
    driver->DriverUnload = driver_unload;
    driver->MajorFunction[IRP_MJ_PNP] = driver_pnp;
    driver->MajorFunction[IRP_MJ_INTERNAL_DEVICE_CONTROL] = driver_internal_ioctl;
    /* RBW-USBHCD */
    driver->MajorFunction[IRP_MJ_CREATE] = rbw_dispatch_create_close;
    driver->MajorFunction[IRP_MJ_CLOSE] = rbw_dispatch_create_close;
    driver->MajorFunction[IRP_MJ_DEVICE_CONTROL] = rbw_dispatch_ioctl;

    rbw_create_host_controllers(driver);
"""
assert old in s, "DriverEntry dispatch block not found - has wineusb.c changed?"
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("  spliced")
PY
fi

grep -q "$MARKER" dlls/wineusb.sys/wineusb.c || { echo "splice failed"; exit 1; }
# The unix half lives in upstream/0010, not in the splice, because it is an
# ordinary diff against two files. bin/build-patched-dlls.sh applies the whole
# 0*.patch series and so will already have done this; apply it here too so this
# script also works standalone. Without it the build produced a wineusb.sys
# whose only caller of the new unixlib entry point had nothing to call --
# and, worse, the enumeration existed ONLY in a developer's working tree.
if ! grep -q "$MARKER" dlls/wineusb.sys/unixlib.c; then
  if patch -p1 --dry-run -s -f < "$ROOT/upstream/0010-wineusb-hcd-unixlib.patch" >/dev/null 2>&1; then
    patch -p1 -s < "$ROOT/upstream/0010-wineusb-hcd-unixlib.patch"
    echo "applied 0010-wineusb-hcd-unixlib.patch"
  else
    echo "unixlib.c is missing the $MARKER enumeration and 0010 will not apply"; exit 1
  fi
fi
grep -q "$MARKER" dlls/wineusb.sys/unixlib.c || { echo "unixlib.c is still missing the $MARKER enumeration"; exit 1; }

# --------------------------------------------------- seed import libraries
# winebuild links a PE driver against import libraries, and generating them from
# scratch needs `dlltool`, which is not installed here (it comes with the mingw
# binutils). The installed Wine already ships the very same .a files, so seed
# them instead of building a toolchain.
#
# The name mapping matters: bin/build-patched-dlls.sh strips "lib" and drops the
# result into dlls/<name>/, but Wine's directory for ntoskrnl is
# dlls/ntoskrnl.exe/ -- so the seed landed in dlls/ntoskrnl/ where nothing looks
# for it, and the link failed with "cannot find the 'dlltool' tool".
. "$ROOT/bin/winepaths.sh"
WINE_LIB="$WINE_PE_DIR"
for pair in ntoskrnl:ntoskrnl.exe hal:hal; do
  lib="${pair%%:*}"; dir="${pair##*:}"
  if [[ -f "$WINE_LIB/lib$lib.a" && ! -f "dlls/$dir/x86_64-windows/lib$lib.a" ]]; then
    mkdir -p "dlls/$dir/x86_64-windows"
    cp -f "$WINE_LIB/lib$lib.a" "dlls/$dir/x86_64-windows/lib$lib.a"
    echo "  seeded lib$lib.a -> dlls/$dir/x86_64-windows/"
  fi
done

# ---------------------------------------------------------------- build
echo "building wineusb.sys (PE) and wineusb.so (unix)..."
make dlls/wineusb.sys/x86_64-windows/wineusb.sys dlls/wineusb.sys/wineusb.so \
  >"$CACHE/build-wineusb.log" 2>&1 \
  || { echo "build failed — see $CACHE/build-wineusb.log"; tail -25 "$CACHE/build-wineusb.log"; exit 1; }

SYS="$SRC/dlls/wineusb.sys/x86_64-windows/wineusb.sys"
SO="$SRC/dlls/wineusb.sys/wineusb.so"
[[ -f "$SYS" ]] || { echo "no $SYS after build"; exit 1; }
[[ -f "$SO"  ]] || { echo "no $SO after build";  exit 1; }

# A patch is not a fix until it is loaded and greppable. Process substitution,
# not a pipe: grep -q exits early and SIGPIPEs strings, which under pipefail
# fails a check that actually succeeded.
grep -q "$MARKER" <(strings -a "$SYS") || { echo "built .sys has no $MARKER marker"; exit 1; }
grep -q "$MARKER" <(strings -a "$SO")  || { echo "built .so has no $MARKER marker";  exit 1; }

mkdir -p "$ROOT/artifacts/winedll"
cp -f "$SYS" "$ROOT/artifacts/winedll/wineusb.sys"
cp -f "$SO"  "$ROOT/artifacts/winedll/wineusb.so"
echo
echo "built, both halves carry the $MARKER marker:"
ls -l "$ROOT/artifacts/winedll/wineusb.sys" "$ROOT/artifacts/winedll/wineusb.so"
echo
echo "install with:  sudo $ROOT/bin/install-wineusb-hcd.sh"
