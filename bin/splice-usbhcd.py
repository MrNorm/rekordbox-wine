#!/usr/bin/env python3
# splice-usbhcd -- splice upstream/patches/rbw-usbhcd.c into a Wine tree's
# dlls/wineusb.sys/wineusb.c. Shared by build-wineusb-hcd.sh (the component
# build) and build-wine-runtime.sh (the whole vendored Wine), so the two can
# never splice differently. Idempotent: a tree that already carries the
# RBW-USBHCD block is left alone.
#
# Usage: splice-usbhcd.py <rbw-usbhcd.c> [wine source dir, default .]
import os, sys
if len(sys.argv) > 2:
    os.chdir(sys.argv[2])
p = "dlls/wineusb.sys/wineusb.c"
if "RBW-USBHCD" in open(p).read():
    print("  wineusb.c already carries the RBW-USBHCD block")
    sys.exit(0)
block = open(sys.argv[1]).read()
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
