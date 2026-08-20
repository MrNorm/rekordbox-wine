# T02 — CDJ-readable USB export

**Status:** PARKED (blocked on T01) · **Opened:** 2026-08-12

## Symptom
Wine classifies every volume as `DRIVE_FIXED`, so rekordbox's Device/export panel
is empty. Not "Wine has no mass storage support" — that 2012 AppDB line is wrong
and still tops search results. The kernel mounts the stick; rekordbox writes
ordinary files. The fault is classification plus PnP enumeration.

Wine's `mountmgr.sys` creates disk and volume devices entirely outside the PnP
tree — it never calls `IoRegisterDeviceInterface` — so `HKLM\System\CurrentControlSet\Enum`
has no storage entries and `SetupDiGetClassDevsW(GUID_DEVCLASS_VOLUME)` enumerates
zero devices. `SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` is still a NULL placeholder at
`dlls/setupapi/devinst.c:608` in master.

Related bugs, all UNCONFIRMED with zero developer replies: 56735 (the tracker),
56731, 56732, 56734, and 16091 (open since Nov 2008).

## The one question that decides the cost

**Does rekordbox call `SetupDiGetClassDevsW` on `GUID_DEVCLASS_VOLUME`, or is
`GetDriveTypeW` returning `DRIVE_REMOVABLE` enough?**

- No SetupAPI call → config-only fix, an evening.
- SetupAPI required → a self-maintained patched Wine build with no upstream, a season.

One trace answers it. Nothing else in T02 should be attempted before that trace.
jpf91's reduced testcase cannot answer it; only rekordbox can.

## Known local hack (not yet attempted)
jpf91/proton-wine, tag `rekordbox_1` — 3 commits, 2 files, 23 lines. Repository
**archived read-only since 2025-02-25** and the diff no longer applies to master
(the setupapi property table was replaced with a `PROPERTY_MAP_ENTRY` macro).
Also needs a `.reg` whose hardcoded `\Device\Harddisk1` is a per-boot
allocation-order variable, and must survive Wine's own udisks2 integration
stealing the drive letter and deleting the registry drive type at mountmgr start.

## Validation rule
Any stick produced here is parsed **natively, outside Wine**, with
`rekordcrate` (from git — the crates.io 0.3.0 is Jan 2025 and lacks the 2026 PDB
read fixes) or Deep-Symmetry `crate-digger`, before it goes anywhere near hardware.

---

# 2026-08-19 — the decisive question is answered, and it is the cheap answer

T02 said: *"Does rekordbox call `SetupDiGetClassDevsW` on `GUID_DEVCLASS_VOLUME`,
or is `GetDriveTypeW` returning `DRIVE_REMOVABLE` enough? No SetupAPI call →
config-only fix, an evening. SetupAPI required → a self-maintained patched Wine
build with no upstream, a season. One trace answers it."*

**The trace is run. There is no SetupAPI call.**

`WINEDEBUG=+setupapi,+mountmgr`, full startup *and* the switch into EXPORT mode.
All **twenty** `SetupDiGetClassDevs*` calls are:

    SetupDiGetClassDevsExW (null) L"ROOT" 0 0x00000004 0 (null) 0

— the `ROOT` enumerator with `DIGCF_ALLCLASSES`. **Not one call names
`GUID_DEVCLASS_VOLUME` or `GUID_DEVINTERFACE_VOLUME`.** The season-long branch
is dead; this is configuration.

(The switch into EXPORT mode was possible at all only because of the same day's
`winex11` fix — see T04. The view-mode selector had never opened before.)

## Two real defects found on the way, both now fixed

`bin/../upstream/drivetest.c` is a new freestanding probe that prints, in one
line per drive, what Wine tells an application. Before:

    C: FIXED  label ""  fs "NTFS"
    E: FIXED  label "REKORDBOX"  fs "NTFS"
    SetupDiGetClassDevsW(GUID_DEVINTERFACE_VOLUME) -> 0 volume interface(s)

**1. Wine could not read the filesystem.** The trace says why:

    warn:mountmgr:get_volume_device_info Failed to open "/dev/sda1", err 5

`/dev/sda1` is `root:disk 0660` and the user is not in the `disk` group, so
mountmgr fell back to reporting NTFS for a FAT32 stick. Granting read access
(`setfacl -m u:$USER:rw /dev/sda1`, or a udev rule for packaging) fixes it —
`fs "FAT32"` immediately.

**2. Wine does not call a removable UDisks drive removable.**
`udisks2_add_device()` derives the device type from UDisks' `MediaCompatibility`,
which is **empty for a plain USB mass-storage stick**, so the type stayed
`DEVICE_UNKNOWN` — even though UDisks had separately reported the drive as
*removable*, which is what put it down the `ADD_DOS_DEVICE` path in the first
place:

    trace:mountmgr:add_dos_device added device e: udi ".../sda1" ... type 0

`device.c` already maps `DEVICE_HARDDISK` to `DRIVE_REMOVABLE`. Patched in
`upstream/0006-mountmgr-removable-unknown-media.patch` (marker `RBW-REMOVABLE`).
After:

    D: REMOVABLE  label "ARCH_202608"  fs "CDFS"
    E: REMOVABLE  label "REKORDBOX"    fs "FAT32"

## Where it stands

The stick is now, as far as Win32 is concerned, exactly what it is: a removable
FAT32 volume called REKORDBOX on E:. **rekordbox still does not list it** in the
EXPORT-mode tree, and has not opened a single file on it (`/proc/<pid>/fd` shows
nothing under the mount point, and the stick is still empty). Replugging it
while the application runs — which makes Wine's UDisks integration remove and
re-add the DOS device — does not change that.

So the remaining question is narrower than the one T02 opened with: **by what
mechanism does rekordbox discover a device, given that it is not SetupAPI?**
Candidates, in the order they should be tried:

1. `DeviceIoControl` on `\\.\E:` — `IOCTL_STORAGE_QUERY_PROPERTY`,
   `IOCTL_STORAGE_GET_DEVICE_NUMBER`. Trace with `+file,+ntoskrnl`.
2. A `RegisterDeviceNotification` / `WM_DEVICECHANGE` registration whose filter
   we do not satisfy. `upstream/devwatch.c` already exists for this.
3. WMI (`Win32_LogicalDisk`, `Win32_DiskDrive`) — Wine's WMI is thin.

## A harness trap, found the hard way

A modal **"iTunes Library — Settings must be configured to display the iTunes
library"** dialog opens if the iTunes source is selected, and it **silently
swallows every subsequent click**. Several probes in this session returned
"nothing opened" against a UI that was simply blocked. `bin/dismiss.sh` should
learn this dialog, and any UI probe that starts returning uniform negatives
should screenshot the whole window before the result is believed.

## The chain, complete and measured — 2026-08-19 (evening)

Every link below is an observation, not an inference.

1. **rekordbox polls every drive letter.** A relay trace scoped to the volume
   APIs (`RelayInclude` in `HKCU\Software\Wine\Debug`) shows, during startup:

        2452 GetDriveTypeW        A:\ .. Z:\, ~190 rounds
        2402 GetVolumeInformationW
        1414 DeviceIoControl
         807 GetDiskFreeSpaceExW
           3 RegisterDeviceNotification{A,W}

   and the `GetDriveTypeW` return values are **2064 x DRIVE_NO_ROOT_DIR,
   194 x DRIVE_REMOVABLE, 194 x DRIVE_FIXED**. With the two Wine fixes in place
   it *does* see the stick as removable.

2. **Its storage IOCTLs succeed.** Of 1414 `DeviceIoControl` calls only 9 fail,
   and the only storage one among them is `SMART_GET_VERSION` (0x00074080),
   which fails on Windows too for a USB stick. `IOCTL_STORAGE_QUERY_PROPERTY`
   (0x002d1400) is called and **succeeds**.

3. **The UI is reached and it is genuinely empty.** EXPORT mode's source strip
   has an **Explorer** entry (laptop icon) and a **Devices** entry (USB icon,
   tooltip *"Display Devices"*). Explorer lists `C:` and `Z:` — the **fixed**
   drives. Devices opens, and its tree contains the root node and **nothing
   else**. So rekordbox splits the two by drive type, and the split works; the
   stick simply never enters the Devices list.

4. **Nothing happens on replug.** Unmounting and remounting the stick while the
   Devices view is open produces: no new `StorageDeviceProperty` query (the count
   stays at the 3 issued during startup), no file opened on the mount point, and
   no change in the tree.

5. **And here is why.** rekordbox registers for device notifications with
   `RegisterDeviceNotificationW(hwnd, &filter, DEVICE_NOTIFY_ALL_INTERFACE_CLASSES)`
   — it is waiting for a **`DBT_DEVTYP_DEVICEINTERFACE`** arrival.
   `upstream/devwatch.exe` registers with **exactly the same flags** and, across
   a full unmount/mount cycle, receives:

        5.9 s  WM_DEVICECHANGE  DBT_DEVICEARRIVAL  devicetype=2   (DBT_DEVTYP_VOLUME)
        ... 10 events, every one of them devicetype=2 ...
        0 events with devicetype=5 (DBT_DEVTYP_DEVICEINTERFACE)

   **Wine broadcasts volume arrivals and never announces a device interface.**

That is the same root as `SetupDiGetClassDevsW(GUID_DEVINTERFACE_VOLUME)`
returning zero, and it is what T02 wrote down on day one from reading the
source: `mountmgr.sys` creates its disk and volume devices outside the PnP tree
and never calls `IoRegisterDeviceInterface`, so there is no interface to arrive
and nothing for SetupAPI to enumerate.

### What would fix it

`mountmgr.sys` should register `GUID_DEVINTERFACE_VOLUME` (and
`GUID_DEVINTERFACE_DISK`) for the device objects it creates, and enable them
with `IoSetDeviceInterfaceState`, which is what broadcasts
`DBT_DEVTYP_DEVICEINTERFACE`. Both entry points already exist in Wine's
`ntoskrnl.exe`. **This is a much smaller change than the archived jpf91
setupapi-property hack this theme has been assuming**, because the goal is the
*notification*, not a full `SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` implementation.

The open question for that patch is whether Wine's `IoRegisterDeviceInterface`
tolerates a device object that has no PnP device node — mountmgr's do not.

## And the notification alone is NOT enough — `upstream/devpoke.c`

Before paying for a mountmgr rewrite, the cheap question was asked: *if the
device-interface arrival simply happens, is that enough?*

`upstream/devpoke.c` (new) synthesises exactly that arrival — a
`DEV_BROADCAST_DEVICEINTERFACE` for `GUID_DEVINTERFACE_VOLUME` and for
`GUID_DEVINTERFACE_DISK`, named in the Windows form
`\\?\STORAGE#Volume#…#{53f5630d-…}` — and sends it to every top-level window.

Two things had to be got right, and both are worth writing down:

* `BroadcastSystemMessageW` reaches **nothing** here. Walking `EnumWindows` and
  using `SendMessageTimeout` per window works.
* It must be **sent, not posted** (a posted message cannot carry a pointer
  across a process boundary), and it must be sent **in the charset the target
  window was registered with** — Wine does not convert the name embedded in a
  `DEV_BROADCAST_DEVICEINTERFACE` between A and W, so a W struct sent to an ANSI
  window is silently dropped. That cost two iterations.

With those fixed, `devwatch` confirms delivery:

    5.0 s  WM_DEVICECHANGE  DBT_DEVICEARRIVAL  iface=\\?\STORAGE#Volume#…{53f5630d-…}
    5.3 s  WM_DEVICECHANGE  DBT_DEVICEARRIVAL  iface=…
    5.7 s  WM_DEVICECHANGE  DBT_DEVICEARRIVAL  devicetype=2

**And rekordbox does not react at all.** With its Devices view open and the
notification delivered to all 26 of its windows: the tree stays empty, no new
`StorageDeviceProperty` query is issued (the count stays at the 3 from startup),
and no file is opened on the mount point.

So the missing notification is *necessary but not sufficient*, and a user-space
helper cannot substitute for the real thing. rekordbox wants a device that
exists, not merely an announcement that one arrived.

## Next action — and it should use the technique that cracked T04 and T10

Stop guessing at the API and find the code. The Devices list is populated by
something in `rekordbox.exe`; the tools to find it now exist and are proven:

1. `perf record -e cycles:u --call-graph lbr` sliced to the moment the Devices
   view is opened, diffed against the Explorer view — which *does* populate.
   Explorer and Devices are the same widget fed by two different enumerators, so
   the diff is small and the working one is right there as a control.
2. Then hardware execute breakpoints on the branch that rejects the volume,
   exactly as T10 phase 34 did with the rendezvous.

The two views differing by drive type is the strongest lead in the theme: **the
code that decides "this belongs in Devices" is reachable, and Explorer is its
control.**

### Two dead ends from the first attempt at that diff, so they are not repeated

* **The LBR diff of Devices vs Explorer was run** (10 timed clicks each,
  `perf -F 9999 --call-graph lbr`, sliced to 350 ms after each click). It gives a
  clean split — Explorer executes **14** addresses Devices never does, Devices
  executes exactly **one**, `0x141561708` — but that one is a **destructor**
  (`FUN_1415616e0`: installs vtables `0x143780618`/`0x143780448`, destroys six
  sub-objects at a 0x168 stride, tail-jumps to `0x142af6230`). So the Devices
  view *builds a model object and tears it straight down*, which confirms
  "enumerates nothing" without naming the enumerator.
* **The class those vtables belong to is shared.** `bin/pexrefva.py` puts its
  methods in `0x14156135e..0x14156547a`, and profiling that whole range shows
  Devices and Explorer executing it almost identically (`0x141567232` 39 vs 33,
  `0x14156210d` 16 vs 16, …). It is the browser widget both views use, not the
  device enumerator.

So the enumerator is upstream of the widget. The next cut should slice on the
**Explorer-only** functions instead — `FUN_141480440` (2058 bytes),
`FUN_141482940` (1179), `FUN_141482f30` (582), `FUN_14151ae10` (5896),
`FUN_14151d570` (757), `FUN_14146e320` (243), `FUN_14151ac80` (191) — and find
the one that walks drive letters; its Devices-side twin is the function to
breakpoint.

* **rekordbox's own device log will not help.** `DeviceLogEnable=1` streams the
  **controller** layer (HID/MIDI authentication) to 127.0.0.1:10001, per
  `bin/devicelog.py`. There is no storage logging in it.

---

# CORRECTION — rekordbox DOES use SetupAPI, and T02 was right on day one

**The earlier claim in this file — "there is no SetupAPI call" — is wrong, and it
was wrong because of how the evidence was read, not what it said.** The relay
log was grepped and only the first six of nineteen `SetupDiGetClassDevsW` lines
were inspected; they happened to be the `L"ROOT"` ones. The full tally is:

    8 x SetupDiGetClassDevsW(NULL, L"ROOT", NULL, DIGCF_ALLCLASSES)   ← unrelated
    7 x  ... from inside Wine's own DLLs                              ← unrelated
    2 x SetupDiGetClassDevsW(0x143b968d8, NULL, NULL, 0x12)  ret=0x141d6eb96
    2 x SetupDiGetClassDevsW(0x143cdc730, NULL, NULL, 0x02)  ret=0x141d6f660

and the two GUIDs in the binary are

    0x143cdc730 = {71a27cdd-812a-11d0-bec7-08002be2092f}  GUID_DEVCLASS_VOLUME
    0x143b968d8 = {53f56307-b6bf-11d0-94f2-00a0c91efb8b}  GUID_DEVINTERFACE_DISK

So **the expensive branch is the real one**, and T02's opening analysis was
correct from the start.

## The enumerator, read out of the machine code

`FUN_141d6f4d0` (1893 bytes) — found statically with `bin/pecallsites.py` (new:
every `call *IAT(%rip)` for a given import, with the containing function from
`.pdata`), because it is the only function in the binary that calls both
`GetLogicalDriveStringsW` and `GetDriveTypeW` twice each.

    r14 = SetupDiGetClassDevsW(GUID_DEVCLASS_VOLUME, NULL, NULL, DIGCF_PRESENT)
    if (r14 == INVALID_HANDLE_VALUE) return false
    for (i = 0; SetupDiEnumDeviceInfo(r14, i, &info); i++)      <-- EXITS IMMEDIATELY HERE
    {
        SetupDiGetDeviceRegistryPropertyW(.., 0x0f, ..)   SPDRP_CAPABILITIES
        SetupDiGetDeviceRegistryPropertyW(.., 0x00, ..)   SPDRP_DEVICEDESC
        SetupDiGetDeviceRegistryPropertyW(.., 0x0e, ..)   SPDRP_PHYSICAL_DEVICE_OBJECT_NAME  -> buf A
        SetupDiGetDeviceRegistryPropertyW(.., 0x0c, ..)   SPDRP_FRIENDLYNAME
        CM_Get_Parent / CM_Get_DevNode_Status / CM_Request_Device_EjectW
        GetLogicalDriveStringsW
        for each drive letter:
            if (GetDriveTypeW(letter) != DRIVE_REMOVABLE) continue
            if (!QueryDosDeviceW(letter, buf B, 0x101)) continue
            if (compare(buf A, buf B) != 0) continue          <-- the match
            ... this drive belongs to this device: add it ...
    }

**The device list is the intersection of two enumerations**: SetupAPI's volume
devices on one side, `GetDriveType`/`QueryDosDevice` on the other, joined on
`SPDRP_PHYSICAL_DEVICE_OBJECT_NAME == QueryDosDeviceW(letter)`.

Under Wine the first enumeration is empty, so the intersection is empty, so the
Devices list is empty — and the drive-letter half, which today's two patches
fixed, never gets used.

This also explains, exactly, why the synthetic `DBT_DEVTYP_DEVICEINTERFACE`
arrival changed nothing: the notification only prompts a rescan, and the rescan
still finds no volume devices.

## What it would actually take

Two things, and T02 named both on 2026-08-12:

1. **`mountmgr.sys` must put its volumes in the PnP tree** so
   `SetupDiGetClassDevsW(GUID_DEVCLASS_VOLUME, DIGCF_PRESENT)` returns them.
   Today it never calls `IoRegisterDeviceInterface`, and Wine's
   `IoRegisterDeviceInterface` in any case requires `DO_BUS_ENUMERATED_DEVICE`,
   which mountmgr's plain `IoCreateDevice` objects are not.
2. **`SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` must return the real
   `\Device\HarddiskVolumeN`**, which is the NULL placeholder T02 quoted at
   `dlls/setupapi/devinst.c`.

Neither is a workaround away. The estimate T02 opened with — *"a self-maintained
patched Wine build with no upstream"* — stands, but it is now a **specified**
piece of work rather than an open-ended one: the GUID, the four properties, the
join key and the consuming function are all known.

---

# 2026-08-19 — THE DEVICE IS LISTED

    ▼ Devices
      ▶ [icon] E:REKORDBOX   [Auth]

`runs/T02-device-listed.png`. First time in this project.

## What it took, and why it is far cheaper than this theme assumed

The decisive discovery is that **Wine's SetupAPI device-*class* enumeration is
purely registry-driven and does not require a PnP device object at all.**
`SETUPDI_EnumerateMatchingDeviceInstances()` walks
`HKLM\SYSTEM\CurrentControlSet\Enum\<enumerator>\<name>\<instance>`, reads
`ClassGUID`, and creates a device for every match. **It does not even test
`DIGCF_PRESENT`.** So making `SetupDiGetClassDevsW(GUID_DEVCLASS_VOLUME,
DIGCF_PRESENT)` return a volume needs *registry keys*, not
`IoRegisterDeviceInterface` and not a bus driver.

Three pieces, all now in place:

1. **The drive must be `DRIVE_REMOVABLE`** — `upstream/0006`, plus read access to
   the raw device node so the filesystem is read as FAT32 rather than NTFS.
2. **`SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` must be readable.** It was
   `{ 0, NULL, NULL, DEVPROP_TYPE_STRING }` in
   `dlls/setupapi/devinst.c`'s `PropertyMap` — a NULL placeholder, so every read
   failed. Mapped to a registry value (`RBW-PDONAME`, marker greppable in
   `setupapi.dll`).
3. **A devnode must exist for the volume**, with `ClassGUID` =
   `{71a27cdd-812a-11d0-bec7-08002be2092f}` and
   `PhysicalDeviceObjectName` equal to what `QueryDosDeviceW` returns for the
   drive letter. Here, by measurement:

        QueryDosDeviceW(L"E:")  ->  \Device\Harddisk1

   so the proof-of-concept devnode is
   `Enum\STORAGE\Volume\RBW_E_TEST` with `PhysicalDeviceObjectName` =
   `\Device\Harddisk1`, plus `DeviceDesc`, `FriendlyName`, `Capabilities`
   (0x84 = removable | surprise-removal-ok), `Class`, `Mfg`, `Service`.

`upstream/drivetest.exe` now performs rekordbox's own enumeration and confirms
each step:

    E: REMOVABLE  label "REKORDBOX"  fs "FAT32"  nt "\Device\Harddisk1"
    SetupDiGetClassDevsW(GUID_DEVCLASS_VOLUME, DIGCF_PRESENT)
       device 0:  desc "Generic volume"  name "REKORDBOX"  caps 132  PDO "\Device\Harddisk1"

## What the real fix is

**`mountmgr.sys` should write that devnode when it creates a volume, and remove
it when the volume goes.** It already knows everything needed — the NT device
name, the drive letter, the label, and whether the device is removable. This is
registry work inside a driver that already does registry work
(`initialize_dos_devices` reads `HKLM\Software\Wine\Drives`), **not** the bus-driver
rewrite this theme had assumed and not the archived jpf91 setupapi hack.

The one piece that is genuinely a Wine bug in its own right, and is already
fixed here, is the `SPDRP_PHYSICAL_DEVICE_OBJECT_NAME` placeholder.

## Still to prove

The device is listed. Whether rekordbox can **export to it** — write the
`PIONEER` tree, and produce a stick a CDJ will read — is the next thing, and
T02's validation rule stands: parse the result **natively, outside Wine**, with
`rekordcrate` or `crate-digger` before it goes near hardware.

---

# 2026-08-19 — USB EXPORT WORKS, AND THE STICK VALIDATES

    Export Track -> E:REKORDBOX

    /run/media/<user>/REKORDBOX
      Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3     6,899,624 bytes
      PIONEER/rekordbox/export.pdb                             167,936
      PIONEER/rekordbox/exportExt.pdb / exportLibrary.db(+wal,+shm)
      PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT / .EXT / .2EX
      PIONEER/djprofile.nxs, MYSETTING.DAT, MYSETTING2.DAT, DJMMYSETTING.DAT
      PIONEER/extracted/gcred.dat

All three ANLZ files begin `50 4d 41 49` — **`PMAI`**, the correct rekordbox
analysis magic. The audio is byte-for-byte the size of the source file.

## Validated outside Wine, as this theme requires

`bin/pdbcheck.py` (new) reads the DeviceSQL header and table directory natively:

    page size   : 4096
    tables      : 20
    next unused : 49   sequence: 9
    tracks 1-2, genres 3, artists 5-6, albums 7, labels 9-10, keys 11,
    colors 13-14, playlist_tree 15, playlist_entries 17, artwork 27,
    columns 33-34, history 39-40   … every page range inside the file
    strings 'Demo Track 1', 'Loopmasters', '/Contents/', '.mp3'  all present

    VERDICT: structurally sound and the exported track is present

**This is the gate, not the finish line.** A full parse with `rekordcrate` or
Deep-Symmetry `crate-digger` is still required before the stick goes into a CDJ,
and that remains the standing rule.

## One UI trap

The first `Export Track` attempt silently does nothing: an informational
**"Convert to OneLibrary"** dialog opens over the top and swallows it. Dismiss
it and repeat, and the export runs. Worth adding to `bin/dismiss.sh` alongside
the iTunes one.

## What still has to be done properly

The devnode is currently **hand-written** into the registry
(`Enum\STORAGE\Volume\RBW_E_TEST`). That is a proof, not a product. The real fix
is for `mountmgr.sys` to write and remove it as volumes come and go — it already
has every field it needs. Until then the entry is per-stick and its
`PhysicalDeviceObjectName` (`\Device\Harddisk1` here) is a per-boot,
allocation-order value, exactly as this theme warned about the archived jpf91
`.reg`.
