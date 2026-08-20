# T06 — Wine's device tree cannot express a composite USB device

**Status:** OPEN. Two real Wine defects found and one of them fixed. **The
causal claim below was tested and REFUTED** — read the correction first.

## CORRECTION, same session — rekordbox does not walk the device tree

Run `20260813T145820-rb7-cfgmgr32-trace`, `WINEDEBUG=+setupapi`, 1894 lines,
controller connected, full application startup:

    CM_Get_Child        0 calls
    CM_Get_Sibling      0 calls
    CM_Get_DevNode_Status 0 calls
    CM_Get_Parent       0 calls

Zero. Not "fails" — **never called**. The theory that rekordbox navigates from
the HID interface to the MIDI interface via a parent/child/sibling walk is dead,
and with it the claim that Defect B is the blocker. Everything about the tree
being too shallow is still *true*; it is simply not what rekordbox is doing.

What it actually does, from the same trace:

    CM_Locate_DevNode_ExW  L"HID\VID_2B73&PID_0026&MI_04\259&-----&0&0&0"
    CM_Locate_DevNode_ExW  L"USB\VID_2B73&PID_0026&MI_04\259&-----&0&0&0"

It locates both nodes **by explicit instance ID**, so it already knows the
string for the USB PDO without asking the tree for it — most likely by
substituting the enumerator prefix, since the rest of the ID is identical.
64 `CM_Locate_DevNode_ExW` and 126 `CM_Open_Class_Key_ExW` calls, no walking.

**Methodological note worth keeping.** A previous session's audit reported that
the cfgmgr32 devnode-walk FIXMEs "fire". They do not — the 47 `stub!` lines in
this trace are `RegisterTouchWindow`, `GetUserObjectSecurity` and
`PowerRegisterSuspendResumeNotification`. Reading a stub list and assuming the
interesting one is on it is not measurement. Two hours went into a hypothesis
that one `grep -c` would have killed at the start.

**Also note:** the missing `RBW-CFGMGR` marker in this trace does *not* show the
patched DLL failed to load — the marker only prints on the first
`CM_Get_Child_Ex` call, which never happens. Loadedness is still unverified for
the rb7 prefix and needs a different marker to establish.

## Next lead — ContainerID, not topology

The trace shows `SetupDiSetDeviceRegistryPropertyW ... prop 36`, which is
`SPDRP_BASE_CONTAINERID`. **ContainerID is how Windows groups the interfaces of
one physical device**: every interface of a composite USB device shares a GUID
derived from the device's serial number, and that is the documented way to ask
"which MIDI port belongs to this HID device" without walking anything.

No `ContainerID` value is present on the DDJ-400's devnodes in
`prefixes/rb7/system.reg`. That is a far better fit for the observed behaviour
than the sibling walk, and it is the hypothesis to test next.

**Supersedes the open question in:** [T05](T05-controller.md) ("identified but never bound")

## The finding

rekordbox finds the DDJ-400's HID interface and then needs to get from it to the
*same physical device's* MIDI interface. Under Wine that journey is impossible,
because Wine does not model the USB composite device at all.

Read straight out of `prefixes/rb7/system.reg` — these are Wine's own
`DEVPKEY_Device_Parent` / `_Children` / `_Siblings` values, decoded:

    HID\VID_2B73&PID_0026&MI_04\259&...
        Parent:   USB\VID_2B73&PID_0026&MI_04\259&...
        Siblings: (EMPTY)

    USB\VID_2B73&PID_0026&MI_04\259&...
        Parent:   ROOT\WINE\WINEBUS
        Children: HID\VID_2B73&PID_0026&MI_04\259&...
        Siblings: WINEBUS\VID_845E&PID_0001\...   <- Wine's emulated mouse
                  WINEBUS\VID_845E&PID_0002\...   <- Wine's emulated keyboard
        BusReportedDeviceDesc: DDJ-400

So Wine's tree is two nodes deep and hangs off a synthetic bus root:

    ROOT\WINE\WINEBUS
    └── USB\…&MI_04          siblings = unrelated Wine emulated devices
        └── HID\…&MI_04      siblings = none

Windows' tree for the same hardware is a composite device with six interfaces:

    USB\VID_2B73&PID_0026\<serial>          <- composite parent. DOES NOT EXIST IN WINE.
    ├── USB\…&MI_00                          audio control
    ├── USB\…&MI_01 / &MI_02                 audio streaming
    ├── USB\…&MI_03                          MIDI          <- what rekordbox is looking for
    └── USB\…&MI_04                          HID
        └── HID\…&MI_04

Three separate things are wrong, and each alone is enough to break the walk:

1. **There is no composite parent.** `CM_Get_Parent` on the HID node reaches
   winebus's root, not the DDJ-400.
2. **The siblings are strangers.** `MI_04`'s sibling list is every other device
   winebus happens to have created, so "find my sibling interface" finds a
   Microsoft mouse.
3. **Interfaces MI_00–MI_03 have no devnodes at all.** winebus enumerates HID
   only, so the MIDI interface rekordbox wants to reach does not exist as a
   device node even in principle.

## Why this explains the exact symptom

It resolves the contradiction T05 was stuck on — rekordbox demonstrably knows
the controller is a DDJ-400, yet treats its MIDI port as an anonymous device:

- It wrote `DDJ-400.midi.csv` once Wine reported the port under its bare name
  (patch 0004), i.e. it **did** see a MIDI device called `DDJ-400`.
- But it wrote a **15-byte empty stub**, not the shipped 243-row factory
  mapping — the treatment a *generic* MIDI device gets.
- Separately it located `HID\VID_2B73&PID_0026&MI_04\…` and knows that node is a
  DDJ-400 (`BusReportedDeviceDesc` above).

Two correct halves that are never joined. The join is the devnode walk, and the
walk is what Wine cannot do. Name matching is not the mechanism — we already
gave it the exact Windows name and it changed nothing.

## A second defect found on the way — dangerous stubs

`dlls/cfgmgr32/cfgmgr32.c`, wine-11.15:

    CM_Get_Child_Ex          :2076   FIXME + return CR_SUCCESS  — *child never written
    CM_Get_DevNode_Status_Ex :2111   FIXME + return CR_SUCCESS  — *status, *problem never written
    CM_Get_Sibling_Ex        :2129   FIXME + return CR_FAILURE   (honest; terminates a walk)

The first two are worse than unimplemented. They report success and leave the
caller reading **uninitialised stack memory** as a device handle or a device
status. A caller that checks "is this device started and problem-free" gets
whatever was on the stack. This is independently worth fixing and is good
upstream material regardless of whether it is rekordbox's blocker.

The data needed to implement all three is already in the registry —
`DEVPKEY_Device_Children` and `DEVPKEY_Device_Siblings` are populated, and
`CM_Get_Parent_Ex` (:1799) is the exact pattern to copy.

## Measured, not inferred — `upstream/devtreetest.c`

The probe walks the tree exactly as an application would, with the out-params
pre-poisoned to `0xdeadbeef` so a stub that returns `CR_SUCCESS` without writing
them is *visible* rather than looking like a plausible device state.

One variable, same scratch prefix, same physical controller. Transcripts:
`upstream/devtree-output-stock.txt` vs `upstream/devtree-output-patched.txt`.

| call | stock cfgmgr32 | patched (0005) |
|---|---|---|
| `CM_Get_DevNode_Status` | `CR_SUCCESS`, `st=DEADBEEF prob=DEADBEEF` | `CR_SUCCESS`, `st=0000000A prob=00000000` |
| `CM_Get_Child` | `CR_SUCCESS`, **never wrote `*child`** | walks into the child correctly |
| `CM_Get_Sibling` | `CR_FAILURE` — walk dies at the first node | enumerates all three children |

`0x0A` = `DN_DRIVER_LOADED | DN_STARTED`. Note what the stock column means for a
real application: it asks "is this device started and problem-free", is told
**yes it succeeded**, and reads `problem = 0xDEADBEEF` — a device with a fault.
Whatever happened to be on the caller's stack decides how the device is treated.

**Defect A is fixed and proven fixed. It did not fix the controller**, and the
patched output shows precisely why — the walk now succeeds and reports the
truth:

    ROOT\WINE\WINEBUS
      WINEBUS\VID_845E&PID_0001\...              <- Wine's emulated mouse
      WINEBUS\VID_845E&PID_0002\...              <- Wine's emulated keyboard
      USB\VID_2B73&PID_0026&MI_04\259&...        <- the DDJ-400's HID interface

The DDJ-400's "siblings" are a Microsoft mouse and keyboard, and there is no
node for the MIDI interface anywhere in the tree. An honest API over an
incomplete tree returns an honest "nothing here". **Defect B is the blocker.**

## Fix plan

**Step 1 — implement the three cfgmgr32 calls honestly.** Self-contained,
upstreamable, and cfgmgr32 is a PE DLL so it can be tested as a per-prefix
`native` override with no system-wide change (unlike `winealsa.so`).
Patch: `upstream/0005-cfgmgr32-implement-child-sibling-and-status.patch`.

**Step 2 — give winebus a real composite parent.** Larger. winebus would need to
create a `USB\VID_xxxx&PID_xxxx\<serial>` node and reparent per-interface PDOs
under it. **Deprioritised by the correction above** — worth doing for general
correctness, but it is not what rekordbox is asking for, so it is not the cure
either. Do not start it before the ContainerID hypothesis is tested.

Step 1 does not fix the controller. It is a correctness fix that happens to sit
next to the bug, and the trace shows rekordbox never reaches it. Its value is
upstream, not here.

## Next action

Test the ContainerID hypothesis, cheapest first:

1. `WINEDEBUG=+setupapi` again, grepping for `prop 36` / `BaseContainerID` /
   `DEVPKEY_Device_ContainerId` — **does rekordbox read a ContainerID**, and on
   which devnode? If it reads one and gets nothing, that is the join key.
2. If so, find where Wine sets `SPDRP_BASE_CONTAINERID` (winebus / setupapi
   device installation) and what it assigns for a hidraw device.
3. Windows derives the ContainerID from the USB serial number, so all
   interfaces of one device share it. Wine can do the same from the hidraw
   device's `ID_SERIAL` — but the MIDI side still has no devnode to carry it,
   which is where this rejoins the topology problem.

Also still unanswered and now the more likely shape of the whole thing: rekordbox
may not be trying to reach MIDI from HID at all. The vendor HID interface
(`UP:FFA0`, from the HardwareId in the registry) is the one Pioneer uses for its
device handshake. If that handshake is what gates Performance mode, this becomes
a scope question — see the scope rule in CLAUDE.md — and the honest finding may
be "NO-GO, hard wall" rather than a Wine bug. Establish which before patching
anything else.
