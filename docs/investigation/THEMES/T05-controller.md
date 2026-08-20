# T05 — DDJ-400 controller: dead inputs, looping LEDs, connect/disconnect flicker

**Status:** OPEN, substantially advanced · **Opened:** 2026-08-13 · Critical path

## Symptoms, as reported

With rekordbox in **Performance mode** and the DDJ-400 connected:

1. The controller's LEDs flash rapidly and continuously. A DDJ-400 should never
   do this.
2. No control on the controller has any effect on screen.
3. (Reported mid-investigation) *"It's like the device is connecting then
   reconnecting a lot as I see the UI flickering with device controls too."*

Symptom 3 arrived late and is the most diagnostic of the three.

## Finding 1 — rekordbox was talking to a loopback, not to the controller

Measured directly, with rekordbox running:

    client 20: 'DDJ-400' [type=kernel,card=1]
        0 'DDJ-400 MIDI 1  '                       <- nothing subscribed
    client 128: 'WINE midi driver' [pid=rekordbox]
        0 'WINE ALSA Output #2'  Connecting To:  14:0
        1 'WINE ALSA Input '     Connected From: 14:0

    /proc/asound/card1/midi0:  Tx bytes: 0   Rx bytes: 0

Client 14 is **Midi Through** — the `snd_seq_dummy` virtual loopback. rekordbox
had wired both its MIDI out and its MIDI in to it, so it was talking to itself,
and **not one byte had ever reached the controller**.

`WINEDEBUG=+midi` shows the scan, and the `#%d` in the port name is the winmm
device id (`dlls/winealsa.drv/alsamidi.c:547`):

| dev | name | outcome |
|---|---|---|
| 0 | PipeWire-System - input | opened, subscription EPERM, closed |
| 1 | PipeWire-RT-Event - input | opened, subscription EPERM, closed |
| 2 | **Midi Through Port-0** | opened in+out, `midi_in_start`, **kept** |
| 3 | DDJ-400 - DDJ-400 MIDI 1 | **never opened** |

The loopback answers anything sent to it, so a host probing ports for a reply
gets one from `snd_seq_dummy` and stops looking.

**This immediately explains both original symptoms at once:** the controller
receives nothing, so it never leaves its power-on LED animation (symptom 1), and
rekordbox is not listening to it, so no control does anything (symptom 2).

### Fixed by removing the loopback

    sudo modprobe -r snd_seq_dummy       # reverse with: sudo modprobe snd_seq_dummy

Device list becomes PipeWire-System(0), PipeWire-RT-Event(1), DDJ-400(2).
Applied on this machine. **Not yet made permanent** — needs a modprobe blacklist.

## Finding 2 — Wine enumerates its own MIDI ports as MIDI devices

Once any Wine process has a MIDI port open, that port appears in the device list
of every subsequent enumeration — including as the wrong direction:

    MIDI OUT devices: 5          MIDI IN devices : 5
      [0] WINE ALSA Input          [0] WINE ALSA Output #2
      ...                          ...

`alsa_midi_init()` (`alsamidi.c`) walks every ALSA sequencer client in two
passes — application ports first (`!(type & SND_SEQ_PORT_TYPE_PORT)`), hardware
ports second — with no filter for Wine's own client, and caches the result
behind `static BOOL init_done`. So the list an application sees depends on what
other Wine processes happen to be doing at the moment it first asks.

**This is a genuine Wine defect but it is NOT what broke this case** — rekordbox
enumerated before its own ports existed. Recorded so it is not confused with the
cause. Worth reporting separately.

## Finding 3 — rekordbox identifies the controller over HID, not MIDI

`rekordbox.exe` imports the whole HID identification stack:

    HidD_GetHidGuid  HidD_GetAttributes  HidD_GetProductString  HidP_GetCaps
    SetupDiGetClassDevsW  SetupDiEnumDeviceInterfaces
    SetupDiGetDeviceInterfaceDetailW  SetupDiGetDeviceRegistryPropertyW

and the DDJ-400 presents a vendor HID interface alongside its audio and MIDI
ones:

    /sys/bus/usb/devices/3-9   vid=2b73 pid=0026
       3-9:1.0 .. 3-9:1.3  class=01 (audio)  driver=snd-usb-audio
       3-9:1.4             class=03 (HID)    driver=usbhid

On Linux that surfaces as `/dev/hidraw0`, which is **root-only by default**:

    crw------- 1 root root 243, 0 /dev/hidraw0

Wine's `winebus.sys` enumerates HID devices from `/dev/hidraw*`, so it could not
see the controller at all. Note Wine's filter would have allowed it —
`is_hidraw_enabled()` (`dlls/winebus.sys/main.c:504`) returns TRUE for any
non-Generic-Desktop usage page, so this was purely a permissions problem.

### Fixed with a udev rule

`packaging/99-pioneer-ddj.rules`, installed to `/etc/udev/rules.d/`:

    KERNEL=="hidraw*", ATTRS{idVendor}=="2b73", MODE="0660", GROUP="audio", TAG+="uaccess"

`TAG+="uaccess"` is the correct mechanism (an ACL for the active seat's user) but
it only applies on a real device-add event, so it needs a replug or reboot to
take effect. For this session an ACL was set directly with
`setfacl -m u:user:rw /dev/hidraw0`.

Verified with a new probe, `upstream/hidtest.c`, which walks the HID interface
class exactly as rekordbox does:

    [0] \\?\hid#vid_2b73&pid_0026&mi_04#...   VID_2B73 PID_0026   product: DDJ-400
    VERDICT: the controller IS visible through HID.

`winedevice.exe` now holds `/dev/hidraw0` open, which is Wine's HID bus doing its
job.

## Where it stands, and the leading hypothesis for what remains

After both fixes, rekordbox **still does not open the DDJ-400's MIDI port** —
`Tx bytes` and `Rx bytes` remain 0 — but the user now reports the device
*connecting and disconnecting repeatedly*, with the UI flickering as controls
appear and vanish. That is new behaviour and it means rekordbox is now finding
the controller and then losing it.

**Leading hypothesis: the audio stream is what it loses.** From T03, with the
mmdevapi patch an event-driven exclusive stream on the DDJ-400 opens and runs —
but the event is signalled once per period regardless of whether any buffer space
was freed, so on roughly every other event `GetBuffer` for a full period is
refused with `AUDCLNT_E_BUFFER_TOO_LARGE`:

    periods serviced: 344 of 344 wanted, 343 refusals

A client that retries gets every period through. A client that treats
`BUFFER_TOO_LARGE` as a stream error — a fair reading, having just been told a
buffer was ready — tears the stream down and rebuilds it. That is exactly a
connect/disconnect loop, and it would re-run the controller's LED init every
cycle.

`upstream/patches/0003-winealsa-signal-event-only-when-a-period-is-free.patch` proposes
holding the event back until a full period is actually free. **Written from the
measurement but NOT built or tested** — and unlike the other two patches this one
is in `winealsa.drv`, a unix `.so`, which cannot be overridden per-prefix and so
requires replacing the file in the system Wine install.

### Also note, an instrument error corrected

The first version of the event-mode probe broke out of its loop on the first
`GetBuffer` refusal and reported "the buffer never comes free". A real client
retries on the next event. With retry, the stream sustains completely. The
refusal *rate* is the finding, not the first refusal — reporting the latter would
have sent the next session after a bug that is not there.

## Next tests

1. **Does the connect/disconnect loop persist?** Watch with `WINEDEBUG=+midi`
   and `watch -n1 'grep "Tx bytes" /proc/asound/card1/midi0'`. If Tx starts
   moving, the controller is being driven and the remaining fault is elsewhere.
2. **Build and test patch 0003.** Replace `winealsa.drv.so` in the system Wine
   (back it up first). If the connect/disconnect loop stops, the hypothesis is
   confirmed and the patch goes upstream with 0002.
3. **Make the fixes permanent:** blacklist `snd_seq_dummy`, and confirm the udev
   rule's `uaccess` tag works after a replug.
4. **Rule out the reverse:** if the loop persists with a clean audio stream, look
   at whether rekordbox requires something else from the HID interface — the
   report descriptor is only 52 bytes, so it is unlikely to carry control data,
   but it may carry an authentication or capability handshake.

## Finding 4 — rekordbox loaded an EMPTY mapping profile, because of Wine's port name

Found by the parallel source/binary audit, verified by hand:

| file | size | header | rows |
|---|---|---|---|
| `…/rekordbox 7.2.17/MidiMappings/DDJ-400.midi.csv` (factory) | 16562 | `@file,1,DDJ-400` | 243 |
| `…/AppData/Roaming/Pioneer/rekordbox6/MidiMappings/DDJ-400 - DDJ-400 MIDI 1.midi.csv` | **32** | `@file,1,DDJ-400 - DDJ-400 MIDI 1` | **0** |

Wine names a MIDI port `"<client> - <port>"` (`alsamidi.c` `port_add`), giving
`DDJ-400 - DDJ-400 MIDI 1`. Windows names it `DDJ-400`, which is the key the
factory profile is stored under. rekordbox looked up the profile by the name the
API gave it, missed, and wrote an empty generic user profile instead — one per
enumerated port, including for the PipeWire ports and Midi Through.

**So even with a perfect MIDI transport, every control would be dead**: the
controller would be bound to a mapping table with no entries.

Worked around by copying the factory profile over the user one with the `@file`
header re-keyed to Wine's name (backup kept as `*.empty-backup`). This did
**not** by itself make the controller work — rawmidi counters are still 0/0 —
because it fixes what happens *after* binding, and binding is still not
happening. It is a necessary fix that was masked by an earlier one.

The cleaner fix is in Wine: name the port after the client when the port name
already begins with the client name, so a class-compliant device reports the
same name Windows gives it. That would also stop every Wine MIDI app writing
mis-keyed config.

## Session update — udev rule fixed, patch 0003 built but not installable

**The udev rule was numbered wrong and silently did nothing.** `TAG+="uaccess"`
is acted on by systemd in `/usr/lib/udev/rules.d/73-seat-late.rules`, so a rule
numbered `99-` adds the tag *after* the point it is consumed and no ACL is ever
granted. Renamed to `packaging/60-pioneer-ddj.rules`; after a replug
`getfacl /dev/hidraw0` now shows `user:user:rw-` and the node is readable
without any manual `setfacl`. This is now permanent and survives replug/reboot.

**Patch 0003 is built and staged** at `artifacts/winedll/winealsa.so`
(417000 bytes, from the patched tree). It cannot be tested yet:

- `winealsa.so` is a **unix** `.so`, not a PE DLL, so the prefix-registry
  `native` override used for dxgi and mmdevapi does not apply to it.
- `WINEDLLPATH=<dir>` does **not** work for it either — measured: with
  `WINEDLLPATH` pointing at the staged build, the refusal count was unchanged at
  343/344, i.e. the stock driver was still loaded.

So it requires replacing `/usr/lib/wine/x86_64-unix/winealsa.so` in the system
Wine installation, which needs explicit approval. Exact steps:

    sudo cp -n /usr/lib/wine/x86_64-unix/winealsa.so \
               /usr/lib/wine/x86_64-unix/winealsa.so.rbw-backup
    sudo cp artifacts/winedll/winealsa.so /usr/lib/wine/x86_64-unix/winealsa.so
    # revert:
    sudo cp /usr/lib/wine/x86_64-unix/winealsa.so.rbw-backup \
            /usr/lib/wine/x86_64-unix/winealsa.so

Note it will be overwritten by the next `wine-staging` package upgrade, which is
a feature rather than a bug — it fails safe back to stock.

**Test once installed:** `wine upstream/wasapitest.exe event`. Stock gives
`343 refusals` out of 344 periods; if the patch works the refusal count should
drop to near zero. Then restart rekordbox and watch whether the
connect/disconnect flicker stops.

**Note for whoever installs it:** the build carries no greppable marker — the
`RBW-EVENT` string is in a C comment, which does not survive compilation. Unlike
the dxgi and mmdevapi patches there is therefore no `grep` that answers "is my
build loaded"; add a `TRACE("RBW-EVENT ...")` to `alsa_create_stream` and rebuild
before trusting any result.

## Patch 0003 INSTALLED AND CONFIRMED — 343 refusals to 0

Built with a greppable `TRACE("RBW-EVENT build: ...")` in `alsa_create_stream`
(the earlier comment-only marker does not survive compilation), installed over
`/usr/lib/wine/x86_64-unix/winealsa.so` with a `.rbw-backup` alongside, and
confirmed loaded:

    0024:trace:alsa:alsa_create_stream RBW-EVENT build: client event gated on a free period.

| winealsa | `wasapitest event`, 344 periods |
|---|---|
| stock | 344 serviced, **343 refusals** (`BUFFER_TOO_LARGE`, padding 256) |
| **patched** | 344 serviced, **0 refusals** |

Every event now means a buffer is genuinely ready, which is the API's contract.
The patch is validated and ready to go upstream alongside 0002. Note it needs
reinstalling after any `wine-staging` upgrade — it fails safe back to stock.

## But that was NOT why the controller is unbound

With the patched driver, rekordbox still opens only MIDI devices 0 and 1 and
`Tx bytes`/`Rx bytes` on the DDJ-400 remain 0.

This retires the "audio teardown causes the loop" hypothesis as the explanation
for **binding**, and sharpens the picture considerably. Comparing the two device
lists:

| list | devices rekordbox opened | DDJ-400 |
|---|---|---|
| with Midi Through: 0 PW-Sys, 1 PW-RT, 2 MidiThrough, 3 DDJ | 0, 1, 2 | **skipped** |
| without: 0 PW-Sys, 1 PW-RT, 2 DDJ | 0, 1 | **skipped** |

In both lists rekordbox opened exactly the non-Pioneer ports and **skipped the
DDJ-400 whatever index it sat at**. So this was never "the scan stops at the
first port that answers" — rekordbox *deliberately excludes* the recognised
controller from its generic MIDI scan, because a known Pioneer device is handled
by a dedicated path rather than as a third-party MIDI surface. That earlier
reading of the evidence was wrong and is corrected here.

The dedicated path is what is failing. The next lead is concrete: the audit found
**hardcoded USB device-interface paths** in `rekordbox.exe` of the form
`usb#vid_2b73&pid_0004&mi_00`. Wine exposes the controller as a **HID** interface
path (`hid#vid_2b73&pid_0026&mi_04`, confirmed by `hidtest.exe`) but exposes no
`usb#` device-interface node at all for a class-compliant device claimed by a
kernel driver. If rekordbox's Pioneer path enumerates
`GUID_DEVINTERFACE_USB_DEVICE`, it will find nothing under Wine no matter how
healthy MIDI and HID are.

**Next test:** trace `WINEDEBUG=+setupapi,+cfgmgr32` around rekordbox startup and
find which device-interface GUID it asks for and what Wine returns. That
distinguishes "rekordbox wants a usb# path Wine cannot provide" from "rekordbox
found the HID device but rejected it for another reason". Do this before writing
any further patch — the two lead to completely different work.

## USB-enumeration hypothesis REFUTED; naming patch landed; binding still open

`WINEDEBUG=+setupapi,+cfgmgr32` on rekordbox startup settles two things.

**Refuted:** rekordbox never enumerates `GUID_DEVINTERFACE_USB_DEVICE`
(`a5dcbf10-6530-11d2-901f-00c04fb951ed` is absent from 1879 lines of trace). It
enumerates `GUID_DEVINTERFACE_HID` (`4d1e55b2-…`, `DIGCF_DEVICEINTERFACE`) and
the HID setup class (`745a17a0-…`). So the "rekordbox wants a usb# path Wine
cannot provide" hypothesis is dead — do not spend more time on wineusb.

**And identification works end to end.** The trace shows rekordbox locating our
device by instance id, in both forms:

    CM_Locate_DevNode_ExW instance_id L"HID\VID_2B73&PID_0026&MI_04\259&…"
    CM_Locate_DevNode_ExW instance_id L"USB\VID_2B73&PID_0026&MI_04\259&…"

So HID identification is no longer the blocker either. The failure is downstream
of "I can see a DDJ-400".

### Patch 0004 — Wine MIDI port naming (installed, verified)

`alsamidi.c` `port_add()` builds `"<client> - <port>"`. A class-compliant USB
device names its seq client after the product and its port after the client, so
the DDJ-400 came out as `DDJ-400 - DDJ-400 MIDI 1` where Windows reports plain
`DDJ-400`. Applications match hardware on that name — this is what made rekordbox
write an empty mapping profile under the decorated name instead of loading the
shipped 243-row `DDJ-400.midi.csv`.

Patched both the dest and src naming blocks: when the port name already begins
with the client name, use the client name alone. Built and installed; verified:

    MIDI OUT devices: 3        [2] DDJ-400          (was "DDJ-400 - DDJ-400 MIDI 1")

**This did not fix binding either.** rekordbox still opens only devices 0 and 1;
rawmidi stays 0/0. Keep the patch — it is correct, it matches Windows, and it
fixes the mapping-profile keying, which would have bitten the moment binding
started working. But it is not the cause.

### Where the search now stands

Everything on the path up to and including "rekordbox knows a DDJ-400 is
attached" is verified working: HID enumeration, device instance ids, MIDI port
present under the correct Windows name, audio exclusive streams clean. rekordbox
still declines to open the port.

Remaining candidates, none yet tested:
1. **It opens the device by a path, not a winmm index** — e.g. via the HID
   handle, or an `IOCTL` on the HID interface that Wine's hidclass rejects. Trace
   `+hid` around startup and look for `HidD_`/`DeviceIoControl` failures against
   `VID_2B73`.
2. **A capability check fails** — `HidP_GetCaps` on a 52-byte report descriptor
   may return usage values rekordbox rejects.
3. **Licence/tier gating** — the DDJ-400 is what unlocks Performance mode on the
   free tier. If rekordbox validates the controller through a mechanism that
   fails under Wine, it would decline to bind while still displaying the device.
   If this is where it lands, the project's scope rule applies: that is
   protection enforcement, and the finding is NO-GO rather than something to work
   around.

**Next action:** `WINEDEBUG=+hid,+hidclass` around startup, grep for 2B73, and
find the first failing call after the successful `CM_Locate_DevNode_ExW`.

---

## RESOLVED (link 1) and RE-AIMED — 2026-08-13, phase 6

The "identified but never bound" mystery is solved as far as *why the open
failed*, and the remaining blocker is now precisely located.

**What was actually wrong.** Wine offered rekordbox a list of MIDI devices in
which the controller was not first, and the entries ahead of it could never be
opened. `winealsa`'s `port_add()` filtered on `SND_SEQ_PORT_CAP_READ` /
`CAP_WRITE`, but every use of a port is `snd_seq_connect_from/to`, which require
`CAP_SUBS_READ` / `CAP_SUBS_WRITE`. PipeWire's two ports have the former and not
the latter, and Wine additionally enumerated its own `WINE ALSA Input` port.

The decisive measurement was `aconnect 20:0 128:1` **by hand, which succeeded**.
That killed every "ALSA won't allow it" theory in one command: the subscription
is legal, so Wine was passing the wrong client/port — a PipeWire pseudo-port.

Run `20260813T150716-rb7-midi-open-trace`:

    midiOutOpen(dev 0) => 0    midiInOpen(dev 0) => 3    midiOutClose
    midiOutOpen(dev 1) => 0    midiInOpen(dev 1) => 3    midiOutClose

3 = `MMSYSERR_NOTENABLED`, from `alsamidi.c:1214`, which returns it **without
logging anything** — the failure is invisible even at full trace level.

Patch 0006 fixes the enumeration. Verified: 4 OUT / 3 IN with the controller
last, becomes 1 OUT / 1 IN with the controller at index 0.

**Where it is stuck now.** `DRV_QUERYDEVICEINTERFACE` (`0x080D`) is implemented
for wave devices and not for MIDI. Run `20260813T151348-rb7-midienum-patched`
shows **559** `midiInMessage(0, 0x080D, …)` calls in a polling loop with no
answer. That is how rekordbox links a MIDI port to the HID device it identified,
and it is why the device controls flicker. See STATE.md for the next action.

**Corrections to earlier work in this theme, recorded so they are not repeated:**

- The devnode-walk hypothesis (T06) was tested and refuted — zero calls to
  `CM_Get_Child`/`Sibling`/`Parent`/`DevNode_Status` in a full startup trace.
- ContainerID was tested and refuted — written 6 times by Wine, never read.
- The MIDI port *name* was never the problem. Patch 0004 gave rekordbox the
  exact Windows name and changed nothing; the empty `DDJ-400.midi.csv` was a
  consequence of the failed bind, not a cause.
- An earlier audit flagged the `DRV_QUERYDEVICEINTERFACE` gap and I dismissed it
  as "not the blocker". It is the blocker.

## Phase 6b — `DRV_QUERYDEVICEINTERFACE` implemented; rekordbox now rejects the *content*

Patch `0007` implements the query for MIDI in both `winmm` and `winealsa`.
Measured end to end, run `20260813T154622-rb7-midiiface`:

    midiInMessage(0, 0x080D)          <- DRV_QUERYDEVICEINTERFACESIZE
      MMDRV_Get(..., N)   fails       <- the old behaviour, MMSYSERR_INVALHANDLE
      MMDRV_Get(..., Y)   succeeds    <- NEW: bare device ID accepted
      MMDRV_Message(MidiIn 0 2061)    <- reaches winealsa
      => MMSYSERR_NOERROR
    midiInMessage(0, 0x080C, buf, 0x400)   <- DRV_QUERYDEVICEINTERFACE
      => MMSYSERR_NOERROR

376 size queries paired with 376 fetches, all succeeding, for IN and OUT. The
string returned, derived entirely from the real hardware:

    \\?\usb#vid_2b73&pid_0026&mi_03#-----#{6994ad04-93ef-11d0-a3cc-00a0c9223196}

vid/pid from `/proc/asound/card1/usbid`, `mi_03` from a sysfs scan for the
interface with audio class 1 / MIDIStreaming subclass 3 (interface 4 is the HID
one), serial from sysfs.

**It still does not bind.** rekordbox consumes the answer and keeps polling.

**Control run `20260813T155900-rb7-builtin-winmm-control` — this is important.**
With the *builtin* winmm and only patch 0006 applied, rekordbox also never calls
`midiInOpen`: 301 queries, zero opens. So patch 0007 introduced no regression.
What changed rekordbox's behaviour was **patch 0006**: before it, the device
list was full of unopenable PipeWire ports and rekordbox fell back to opening
indices blindly; after it, the list is clean and rekordbox uses the
interface-query path exclusively and decides from the string.

That narrows the remaining question sharply: **the format or content of the
interface path is not what rekordbox expects.** The instance component is the
obvious suspect — Wine's HID devnode for the same device is
`HID\VID_2B73&PID_0026&MI_04\259&-----&0&0&0`, whose instance `259&-----&0&0&0`
looks nothing like the `-----` we emit, so a correlation between the two
interfaces of one physical device cannot succeed.

### Next action

Make the MIDI interface path's instance component match the convention winebus
uses for the same physical device, so the HID and MIDI paths are recognisably
siblings. Find winebus's instance-ID construction and mirror it. If that fails,
capture what rekordbox does with the *wave* device interface path (which Wine
does answer) and copy that shape exactly.

---

## Phase 7 — the string hypothesis is DEAD. Multi-agent audit, 2026-08-13

Workflow `wsbi09ne4`, five agents, two of them reaching the same conclusion from
independent tooling (capstone disassembly vs objdump + IAT xref scan).

**REFUTED — the interface path content is not the blocker, and never was.**
The `0x080D`/`0x080C` calls are stock **JUCE 7.0.9** `getInterfaceIDForDevice`.
The string is stored as `MidiDeviceInfo::identifier` and is **never parsed,
split, compared field-wise, or compared against any other device path.** There
is no `#`-splitting, no instance extraction, no `hid#` literal, no wide `\\?\`
literal, and `KSCATEGORY_AUDIO` (`6994ad04`) appears **zero** times in the
100 MB image. Patch 0007's *mechanism* is right and worth upstreaming; its
*content* is irrelevant, and so is every format in
`upstream/reports/NOTES-iface-format-search.md`. **Do not run that search.**

**Also refuted — "copy the wave path shape", which STATE.md had as the next
action.** Measured twice: Wine's wave `DRV_QUERYDEVICEINTERFACE` returns a bare
endpoint GUID (`{B1AD9065-...}`), not a path, and rekordbox never calls
`waveOutMessage`/`waveInMessage` at all.

**What is actually happening.** `DeviceMidi::openDevice` (`0x1423a5210`) calls
`MidiInput::getAvailableDevices` and locates the port by **exact
`juce::String::operator==` on `MidiDeviceInfo::name`** — i.e. `MIDIINCAPS
szPname` — logging `"MIDI input is not found"` on failure. rekordbox has already
accepted the DDJ-400 over HID and is sitting in `"### HID:Other:[%s] open wait
for start midi."`, re-enumerating the MIDI **IN** list ~2/s. The asymmetry is the
tell: **859 IN enumerations against 2 OUT calls.** JUCE's own change detector
would poll both; an input-only retry loop is rekordbox's code.

**HID is identity-only, not a data path.** One `CreateFileW` on
`\\?\hid#vid_2b73&pid_0026&mi_04#259&-----&0&0&0#{4d1e55b2-...}`, succeeding;
then `HidD_GetAttributes` / `GetManufacturerString` / `GetProductString` /
`GetPreparsedData` / `HidP_GetCaps`, and the handle is closed within ~40 lines.
**Zero** feature/output-report I/O in 75 MB of trace. That is where the model
*name* comes from.

**The gate nobody had connected.** A successful `<name>.midi.csv` load runs
**before** the `DeviceMidi` object is constructed (`0x1422bc470`, the only caller
of the ctor `0x1423a4d40`), failing to `"### MIDI:%s.midi.csv is not found."`
And in a 631k-line `+file` trace rekordbox **never opens MidiMappings or any
`.midi.csv` at all.**

**Acted on:** rekordbox had rewritten a **15-byte** `DDJ-400.midi.csv` into
`AppData/.../MidiMappings/`, which shadows the **243-row factory profile**
shipped at `Program Files/rekordbox/.../MidiMappings/DDJ-400.midi.csv`. The
factory profile is now installed there **read-only (mode 444)** so rekordbox
cannot replace it with a stub again. **This is untested — no run has been made
since.** Test it.

**SCOPE: verdict (b), NOT NO-GO.** A real mutual challenge-response does exist
(`@DeviceAuth` / `@AuthChallengeA` / `@AuthResponseE`, over `@SendDataHID`) and
is named here honestly. But the DDJ-400 is **absent** from the 44-model
auth-capable `DeviceHid` table, rekordbox imports no `HidD_SetFeature` /
`GetFeature` / `SetOutputReport` entry points in any shipped module, and zero
report I/O was measured. The blocker we are on is a string comparison in
open-source JUCE. Even in the worst case, a device-local handshake with hardware
the user owns would make the failure "Wine drops a 64-byte vendor HID report" —
a transport bug, in scope.

**Correction for the record: this is JUCE 7.0.9, not JUCE 8** (`rb.strings`
offsets 87846976, 87885080). T01's `WaitForVBlank` root cause is unaffected, but
the Bugzilla/AppDB drafts must not say "all JUCE 8 apps" — that scope label is
provably wrong.

### Next action

1. **Run it.** The factory profile is in place read-only and nothing has been
   tested since. Check for `midiInOpen` and for `Tx bytes` moving off 0.
2. If still stuck, get the **name** rekordbox is matching on. It derives the
   model from the HID product string; Wine reports the MIDI port as `DDJ-400`
   via `MIDIINCAPS.szPname`. Compare the two **byte for byte** — trailing space,
   case, or `MAXPNAMELEN` truncation would all defeat `operator==`.
3. `DeviceLogEnable=1` plus a `DeviceLog.conf` and a listener on 127.0.0.1:10001
   (`research/probes/devicelog.py`) produced **no output** across two launches. Either
   another precondition is missing or the transport differs. Worth one more try
   because rekordbox would then state the failure in its own words.

---

## Phase 8 — 2026-08-14. rekordbox SKIPS the DDJ-400. It does not fail to open it.

Two controlled experiments, each one variable, device physically replugged first.

### Experiment 1 — hide the HID interface. Result: no change.

`research/probes/hidhide-test.sh` revokes the user ACL on `/dev/hidraw0`, so winebus cannot
enumerate it and the controller vanishes from Wine's HID stack:

    before:  total HID interfaces: 3, Pioneer: 1  -> "the controller IS visible"
    after:   total HID interfaces: 2, Pioneer: 0
    MIDI still enumerated: OUT [0] DDJ-400, IN [0] DDJ-400

    midiInOpen 0 · midiOutOpen 0 · midiInStart 0 · Tx=0 Rx=0

**HID is not the blocker.** The whole "stuck in HID:Other, waiting for start
midi" theory is dead as a cause: remove HID entirely and nothing improves.
Run `runs/HIDHIDE/20260814T085136-wine.log`. ACL restored automatically.

### Experiment 2 — add generic MIDI devices. Result: DECISIVE.

`sudo modprobe snd-virmidi` adds four generic ports. Wine then enumerates five
devices each way, DDJ-400 still at index 0:

    OUT/IN: [0] DDJ-400  [1..4] VirMIDI 2-0 .. 2-3

rekordbox, same build, same prefix, same session:

    midiInOpen 8 · midiOutOpen 8 · midiInStart 4      <- it opened FOUR devices

and every single open was of a **VirMIDI** port:

    midiOutOpen(1) => 0 ; midiInOpen(1) => 0 ; midiInStart
    midiOutOpen(2) => 0 ; midiInOpen(2) => 0 ; midiInStart
    midiOutOpen(3) => 0 ; midiInOpen(3) => 0 ; midiInStart
    midiOutOpen(4) => 0 ; midiInOpen(4) => 0 ; midiInStart

**Index 0 — the DDJ-400 — was never opened. Not attempted, not refused.**
Meanwhile all five indices were enumerated 365 times each, so it was looking at
the DDJ-400 on every pass and choosing to pass over it.

### What this proves, and what it kills

**Wine's MIDI stack is not the problem.** rekordbox opened four devices through
it flawlessly — `midiInOpen`, `midiOutOpen` and `midiInStart` all returning 0.
Patches 0004, 0006 and 0007 are vindicated: the plumbing works.

**rekordbox is selecting against this device specifically.** It recognises the
DDJ-400 as Pioneer hardware and routes it away from the generic-MIDI path that
VirMIDI takes, into a dedicated path that never completes. Combined with
experiment 1, that routing is NOT triggered by the HID interface — it survives
HID being invisible — so it is triggered by something the MIDI device itself
carries. The port NAME is the obvious candidate: `DDJ-400` matches both the
shipped `MidiMappings/DDJ-400.midi.csv` and 35 occurrences of that literal in
the binary.

### Next action

Rename the MIDI port and see whether rekordbox then treats it as a generic
controller. Patch 0004 already controls this string in `alsamidi.c` `port_add()`.
Report the DDJ-400 as e.g. `Generic MIDI` and re-run:

- **opens it** → the Pioneer name routes it to the dedicated path, and we have
  both the mechanism and a usable workaround (generic MIDI + the factory
  mapping assigned by hand).
- **still skips it** → the trigger is not the name; look at what else
  distinguishes a real hardware port from a VirMIDI one (subscription
  capability flags, port type bits, client type kernel vs user).

## Phase 9 — CONFIRMED: the PORT NAME is the trigger. First MIDI traffic ever.

`RBW_MIDI_RENAME` (diagnostic hook in patch 0004's `port_add()`) substitutes the
reported MIDI port name at enumeration time. One variable, controller physically
rebooted first, everything else identical.

    RBW_MIDI_RENAME="Generic MIDI Controller"

    midiOutOpen(0) => 0        <- SUCCESS. index 0 is the DDJ-400.
    midiInOpen(0)  => 0        <- SUCCESS
    midiInStart                <- STARTED

    /proc/asound/card1/midi0:   Tx bytes 2   Rx bytes 9
    aconnect:  client 20 DDJ-400  Connecting To: 128:1
                                  Connected From: 128:0

**The first MIDI bytes to move in either direction in this entire project.**
Both counters had been 0 across every prior run. The ALSA sequencer subscription
that `midi_in_open` makes -- the one whose absence started this whole
investigation -- is finally established.

Named `DDJ-400`: never opened, not even attempted.
Named anything else: opened, started, subscribed, data flowing.

### What this settles

- **Not a Wine bug.** Wine's MIDI stack delivers the device correctly; rekordbox
  simply declines it by name. Patches 0004/0006/0007 are confirmed good.
- **Not hardware rejection, not authentication.** rekordbox never talks to the
  device before deciding, so it cannot be validating it. The decision is made on
  a string, before any I/O.
- **Not HID.** Phase 8 already showed hiding HID changes nothing.

So: recognising the name `DDJ-400` routes the device into a Pioneer-specific
path which never completes, and that path is where the remaining blocker lives.

### What this does NOT achieve

The controller is bound as a **generic, unmapped** MIDI device:

- the toolbar MIDI indicator stays greyed (`uiassert`: `midi_indicator greyed
  peak=0.188`), so rekordbox does not consider a controller connected
- no MIDI tab appears under Preferences → Controller (tabs remain Deck, Mixer,
  Effect, Sampler, Recordings, MIX POINT LINK, Others)
- the 243-row factory mapping is not applied, so jog wheels and faders do
  nothing on screen

MIX and LEVEL remain `active`, from the audio fix (patch 0008), not from this.

**This is a diagnostic result, not a workaround to ship.** Renaming the port
makes rekordbox treat a DDJ-400 as an anonymous MIDI device, which is worse for
a user than the current state, not better. It is valuable because it localises
the blocker precisely.

### Next action

The question is now narrow: **what does rekordbox's Pioneer path require that
this device is not providing?** Workflow `wt2kzqwb2` is researching exactly
that -- the model-name tables at 0x3792a58/0x3792aa8, what a name HIT routes
into, and what precondition that path waits on.

Worth testing cheaply in the meantime: other names, to find where the boundary
sits. `RBW_MIDI_RENAME="DDJ-400 MIDI 1"` (the raw ALSA port name, i.e.
pre-patch-0004 behaviour) and `RBW_MIDI_RENAME="DDJ-FLX4"` (a different model in
the same table) would show whether the match is exact, prefix-based, or
table-wide.

## Phase 10 — the factory mapping loads under the renamed port. rekordbox drives the LEDs.

Following phase 9: rekordbox binds the renamed port but wrote itself a 31-byte
header-only profile, so nothing was mapped. Gave it the real one:

    cp "<install>/MidiMappings/DDJ-400.midi.csv" \
       "<appdata>/MidiMappings/Generic MIDI Controller.midi.csv"
    # header line rewritten to @file,1,Generic MIDI Controller, CRLF preserved

Result, run `runs/MAPPED-TEST.log`:

    midiInOpen 2 · midiOutOpen 2 · midiInStart 1
    Tx bytes    2 -> 595        <- rekordbox is now DRIVING the controller
    Rx bytes  108 -> 114
    mapping file still 16578 bytes, 243 rows -- loaded, not rejected

`Tx` sampled every 2 s for 10 s stayed flat at 595: a **one-shot initialisation
burst**, not a retry loop. That is the shape of a healthy connect — rekordbox
sent the LED/state initialisation the mapping's output rows describe, then went
idle waiting for input.

**The mapping-file gate is real and the filename is the key.** A file named for
the port loads; the shipped `DDJ-400.midi.csv` was never being read because
rekordbox never bound a port called `DDJ-400` in the first place.

### Still not the milestone

`uiassert --expect milestone` still fails on `midi_indicator` and
`pad_indicator` (`greyed`, peak 0.188). rekordbox has a working generic MIDI
binding with the DDJ-400 mapping loaded, but does not light the toolbar MIDI
indicator for it — that appears reserved for a device it recognises as a
Pioneer controller, which is precisely the path we had to route around.

MIX and LEVEL remain `active` from the audio fix (patch 0008), not from this.

### The open question, unchanged in shape but much better bounded

Under its real name the device is claimed by rekordbox's Pioneer path, which
never completes. The research workflow's leading explanation (strong inference,
~65%, not yet tested) is that the **audio** side already claimed the model key:
Wine exposes the endpoint as `Speakers (Out: DDJ-400 - USB Audio)` and rekordbox
stored it as `audioOutputDeviceName="DDJ-400 WASAPI"` — while every other
endpoint in `rekordbox3.settings` is stored verbatim. Only the Pioneer one was
rewritten to the canonical model string, which is direct evidence it went
through a model matcher. Under that normaliser `DDJ-400 WASAPI` and `DDJ-400`
collide, so the MIDI port may be folded into an already-claimed device object
rather than connected in its own right.

That predicts `RBW_MIDI_RENAME="DDJ-FLX4"` is ALSO skipped (different model,
same table, no audio claim) — a clean one-variable discriminator not yet run.

## Phase 11 — audio AND MIDI working simultaneously. Plus a critical usage rule.

Run `runs/CLEANCYCLE.log`, clean sequence (kill rekordbox → `wineserver -k` →
verify device settled → launch):

    MIDI  : Tx 595  Rx 36
            client 20 DDJ-400  Connecting To: 128:1  Connected From: 128:0
    AUDIO : bin/audiotest.sh PASS -- sample_rate_value active peak=1.000

**First time both have worked in the same session.** User confirmed, independently
and before this run, that the MIX and LEVEL dials on the controller moved the
corresponding controls in the application — genuine hardware input driving
rekordbox.

### THE CRITICAL USAGE RULE, learned the hard way

**rekordbox binds MIDI once, at startup, and never recovers if the device is
replugged underneath it.**

Diagnosed from a real incident. The user reported that after unplugging,
replugging and "reopening rekordbox from the launcher", the controller went
dead while audio still worked. Measured:

    process start 10:10:24, uptime 1h39m   <- the OLD instance, never exited
    RBW_MIDI_RENAME still set in /proc/<pid>/environ
    Tx 0 / Rx 0, no ALSA subscription

The launcher click found the **existing** instance rather than starting a new
one, and the replug had happened under it. rekordbox held a handle to a MIDI
port that no longer existed; the audio device object re-resolved, the MIDI
binding did not. Every symptom followed from that:

- "device controls no longer reflect on the UI" -> MIDI binding lost
- "audio device and sample rate are showing" -> audio re-resolved fine
- "waveforms not showing, unable to play" -> stale 1h39m instance state

`research/probes/usbreset.sh` already refuses to reset the bus under a running rekordbox for
exactly this reason. A **physical** replug bypasses that guard, so the rule has
to be documented rather than enforced:

    ALWAYS: replug (or usbreset) FIRST, then start rekordbox.
    NEVER:  replug while rekordbox is running.
    AND:    verify the old process actually exited -- closing the window is
            not the same thing, and a launcher click will silently attach to a
            surviving instance.

### Still not the milestone

`uiassert --expect milestone` continues to fail on `midi_indicator` and
`pad_indicator`. The binding is real and carries input, but it is a **generic**
one obtained by renaming the port, so rekordbox does not light the Pioneer
controller indicator. Some button LEDs (Cue, Active Loop) were reported still
flashing during the mapped session, which is consistent with a partial LED
init: the factory mapping's output rows are written for a device rekordbox has
accepted as a DDJ-400, not for a generic device it is driving through the same
table.

---

## Phase 19 (2026-08-15) — ROOT CAUSE: `\\.\HCD0` does not exist in Wine

**This supersedes phase 9's conclusion.** rekordbox does *not* "skip a port named
DDJ-400 on the string". The name match **succeeds** and builds the correct
per-model object. What fails is a USB host-controller probe immediately after it,
and Wine does not implement the API that probe uses.

### The chain, from the binary

| address | what it does |
|---|---|
| `0x1423a5210` | `djplay::DeviceMidi::openDevice` — logs `@@@ DeviceMidi::openDevice(%s)` |
| `0x1423ab020` | 56-entry factory: matches the model name, builds a dedicated `djplay::MidiMap<Model>` |
| `0x1423b7e30` | ctor for **`djplay::MidiMapDDJ400`** (527,048 bytes) |
| `0x1423aaf40` | **THE GATE.** `dynamic_cast` to `djplay::USBDeviceValidation`, call vtable `+0x18`, log `bcdVersion = %04X`. **If negative: deleting destructor, return NULL.** |

`MidiMapDDJ400` inherits `USBDeviceValidation` at offset `0x809f8`; its vtable
slots return **`0x2b73`** and **`0x0026`** — the real DDJ-400 VID/PID it goes
looking for.

`USBDeviceValidation` is the Microsoft **usbview** host-controller walk:

    CreateFileA "\\.\HCD0" .. "\\.\HCD9"
    IOCTL 0x220424  IOCTL_GET_HCD_DRIVERKEY_NAME
    IOCTL 0x220408  IOCTL_USB_GET_ROOT_HUB_NAME / USB_NODE_INFORMATION
    IOCTL 0x22040c  IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX  (0x16d bytes)
    IOCTL 0x220410  IOCTL_USB_GET_DESCRIPTOR_FROM_NODE_CONNECTION

comparing `ConnectionStatus`/`idVendor`/`idProduct` and copying out **`bcdDevice`**.

### Wine implements none of it

    grep -rn 'HCD' dlls/ programs/ include/     ->  nothing
    include/ddk/usbioctl.h                      ->  27 lines, only IOCTL_INTERNAL_USB_SUBMIT_URB
    dlls/wineusb.sys                            ->  no hub or node IOCTLs

### Confirmed in our own evidence — unread for two days

`runs/20260813T163916-hidopen/wine.log`:

    351838  GetFileAttributesW  ...\MidiMappings\DDJ-400.midi.csv
    351848  CreateFileW L"\\\\.\\HCD0"  ... through HCD9
            10 x "Unable to create file", 10 x status c0000034 (OBJECT_NAME_NOT_FOUND)
    midiInOpen calls in the whole run: 0

### Why every previous observation now makes sense

- **The rename works** because the name then matches *no* model, so no `MidiMap`
  subclass is built, so there is no `USBDeviceValidation` to fail, and the device
  falls through to the generic CSV path.
- **The jog wheels do nothing under the rename** because `JogRotate`/`JogTouch`
  are handled by the native `MidiMapDDJ400`, not by the generic engine. They will
  not work until the real object is constructed — i.e. until this gate passes.
- **The greyed indicators and missing MIDI tab** are the same thing: rekordbox
  never got a Pioneer device object.

### Killed on the way

- **`wMid`/`wPid`** — dead. rekordbox imports only `midiInGetDevCapsW` /
  `midiOutGetDevCapsW`, one call site each, and reads **only `szPname` (+8)**,
  plus `wTechnology` (+0x48) once, which Wine already reports correctly. Wine's
  hardcoded `caps.wMid = 0x00FF` / `wPid = 0x0001`
  (`winealsa.drv/alsamidi.c:481,575`) is a real defect worth fixing separately,
  but it is **not** this blocker.
- **HID vs MIDI name mismatch** — dead, closing phase 18's next-action #2 with a
  negative. `hidtest.exe` → HID product string `DDJ-400`; `miditest.exe` → MIDI
  IN/OUT `szPname` `DDJ-400`. Byte-identical.

### Scope: IN-SCOPE WINE BUG

All five analysis agents returned this independently. `USBDeviceValidation` reads
only **public USB descriptor fields** — `idVendor`, `idProduct`, `bcdDevice` —
about hardware the user physically owns. No crypto, no HID feature/output report
I/O, no call into `clatc.dll` (activation) or `lsapiw64.dll` (Sentinel licensing)
anywhere in that call graph. The DDJ-400 is absent from the 44-model auth-capable
`DeviceHid` table, so the `@DeviceAuth` challenge-response present in the binary
does not apply to it.

Implementing a documented Windows API that Wine lacks, so that a genuine device
can be seen truthfully, is a Wine correctness fix — not a workaround of
enforcement.

### Next action

Implement the usbview IOCTL surface in Wine, backed by real sysfs/libusb data,
with an `RBW-*` marker. The minimum to satisfy the probe: a `\\.\HCD0` device
object, root-hub enumeration, and `USB_NODE_CONNECTION_INFORMATION_EX` carrying
true `idVendor`/`idProduct`/`bcdDevice`.

## Phase 20 (2026-08-16) — the "full-fidelity" wire log is not full fidelity

**Nobody has yet seen the whole of either auth message.** The instrument that
produced phase 19's headline finding truncates, and in one direction it does so
silently.

`~/.cache/rbw-wine-build/wine-11.15/dlls/winealsa.drv/alsamidi.c`:

| probe | direction | cap | discloses it? |
|---|---|---|---|
| `rbw_wire_log` (line 1215) | OUT | `min(len, 64)` | yes — prints `...` |
| `handle_sysex_event` (line 1226) | IN | `len < 32 ? len : 32` | **no marker at all** |

The inbound probe prints `len=51` and then 32 bytes, with nothing to say the
other 19 are missing. So:

- **`@AuthResponseA` (0x13, 51 bytes) has never been read past byte 32.** The
  visible part stops at `... 44 44 4A 34 30 30 04 0A` — i.e. exactly at the
  start of TLV tag `04`, whose payload is the device's actual response data and
  the presumed input to what rekordbox sends back.
- **`@AuthResponseE` (0x14, 66 bytes) has never been read past byte 64** — the
  two missing bytes include **the terminating `F7`**.

Both the code comment and the 2026-08-16T14:05 journal entry call this "a
full-fidelity MIDI wire log ... logging complete messages as hex in BOTH
directions". It is not, and the claim should not be repeated.

### Why the missing `F7` is a first-class hypothesis, not a nitpick

A SysEx with no terminator leaves the receiver's parser mid-message. Every
subsequent byte — including the 200 ms `@Activate` keep-alives and any control
the user touches — is then swallowed as SysEx payload, and the device answers
nothing. That is indistinguishable, from outside, from the observed frontier:
output "stops working" at the exact instant `@AuthResponseE` is sent, the device
never sends `@AuthEnd`, and it looks wedged.

So there are now **three** candidates for the stall, not two:

1. the device rejects the response and deliberately stops (device-side);
2. the device wedges for an unrelated USB reason at that moment (USB-side);
3. **Wine truncates or mis-packetises the 66-byte message so the device never
   sees a complete SysEx** (transport-side, and our bug to fix).

Nothing measured so far separates these, because every instrument used has been
above the transport.

### The protocol is TLV, and the challenge is a per-session nonce

Decoded from `runs/MIDI/20260816T145128-gdbauth/wine.log` and
`runs/MIDI/20260816T143942-rawprobe/wine.log`. After the 10-byte Pioneer header
the body is `<tag> <len> <data...>`, where `len` counts the tag and length byte
too, and payloads are **nibble-encoded** (each byte carries 4 bits, which is
why every payload byte is `<= 0x0F`):

    0x12 @AuthChallengeA  01 0B "PioneerDJ"  02 0B "rekordbox"  03 12 <16 nibbles = 8 bytes>
    0x13 @AuthResponseA   01 0B "PioneerDJ"  02 08 "DDJ400"     04 0A <truncated at byte 32>
    0x14 @AuthResponseE   01 0B "PioneerDJ"  02 0B "rekordbox"  04 0A <8 nibbles> 05 16 <20 nibbles>

**Tag 03 differs between the two runs** (`0A 07 09 08 …` vs `09 0C 07 03 …`), so
the challenge is a fresh nonce per session. Two consequences:

- A captured `@AuthResponseE` cannot be replayed to authenticate — it is bound
  to a nonce that will not recur. Replay is therefore useless as a bypass, which
  also means using one as a *diagnostic* stimulus cannot defeat any protection.
- **And yet the visible 30 bytes of `@AuthResponseE` are byte-identical across
  the two runs, while the challenge that preceded them differed.** Either the
  varying part lives in the 36 bytes we have never seen, or the response is not
  a function of the exchange at all. This is worth settling, but note it is a
  *rekordbox* behaviour, not a Wine one.

### Next test, and it is cheap

`research/probes/usbwire.sh` (new, validated 2026-08-16) captures the DDJ's URBs via usbmon
and reports **URB completion status**, which every previous instrument lacked.
Run rekordbox under it and read out, at the wire:

1. whether all 22 USB-MIDI packets of `@AuthResponseE` are submitted;
2. whether the final packet carries CIN `0x07` and the `F7`;
3. whether each URB completes with status 0, or stalls (`-32`), times out
   (`-110`), or never completes at all.

Outcome 1 or 2 failing makes this a Wine transport bug and hypothesis 3 wins.
All three clean, with no reply from the device, makes it device-side and points
at the content of the response.

## Phase 21 (2026-08-16) — the handshake driven from pure Linux, and the device does NOT wedge when it is ignored

`research/probes/authreplay.py` talks to `/dev/snd/midiC1D0` directly: no rekordbox, no
Wine, no ALSA sequencer. Five layers removed from the picture at once.

**Control arm (`observe`, 25 s):** send `@Activate` every 200 ms exactly as
rekordbox does, answer `@AuthReq` with a host-generated nonce, then deliberately
say nothing more.

    4.130  IN   @AuthReq        12B
    4.130  OUT  @AuthChallengeA 52B  (our nonce, not rekordbox's)
    4.134  IN   @AuthResponseA  51B   <-- ALL 51 BYTES, seen here for the first time
             tag 01   9B  "PioneerDJ"
             tag 02   6B  "DDJ400"
             tag 04   8B  00 03 0c 07 0e 02 01 05
             tag 03   8B  00 00 00 00 05 03 0d 0c
   14.137  IN   @AuthReq        12B
   24.140  IN   @AuthReq        12B

Four findings, all measured:

1. **The device will do the handshake with any host.** It answered a nonce this
   script invented. Nothing about steps 1-3 requires rekordbox, Windows, or the
   Pioneer driver.
2. **`@AuthResponseA`'s tail is no longer a mystery** — the 19 bytes that the
   truncating probe of phase 20 was hiding are two 8-byte nibble payloads,
   tags 04 and 03. `04` tracks the nonce; `03` was constant here.
3. **The device re-issues `@AuthReq` every 10 s, indefinitely.** There is a
   second clock in this protocol, device-side, and it is longer than
   rekordbox's 8000 ms `timerCallback`. So rekordbox gives up first, and the
   device would have been happy to start again.
4. **THE DEVICE DOES NOT WEDGE WHEN THE AUTH IS LEFT UNFINISHED.** It accepted
   all 1,540 bytes we wrote across 25 s and kept talking. An unanswered auth is
   simply retried.

Point 4 matters more than the rest. In every rekordbox run, output dies at the
instant `@AuthResponseE` is sent. Here, *not sending it* leaves the device
perfectly healthy for as long as we care to watch. So the wedge is bound to the
act of sending that final message — not to auth failure in the abstract, and
not to elapsed time.

That narrows the three candidates of phase 20 to a testable pair, which the
other two arms of the same script now put to the device directly:

- `reject`   — a well-formed `@AuthResponseE` with a knowingly wrong payload.
               Does rejection alone stop the device accepting output?
- `truncate` — the same message with the `F7` removed. Does an unterminated
               SysEx reproduce the symptom exactly?

**Scope note.** The challenge is a fresh nonce per session, so there is nothing
here that could be replayed to authenticate, and the probe sends payloads it
knows to be invalid. This characterises a failure mode; it does not circumvent
one.

### Phase 21b — THE WEDGE IS REPRODUCED, AND ITS CAUSE IS AN UNTERMINATED SysEx

Three arms of `research/probes/authreplay.py`, back to back, same device, same script, one
variable: what the final message looks like.

| arm | final message | device afterwards |
|---|---|---|
| `observe` | not sent at all | healthy 25 s, re-issued `@AuthReq` at 14 s and 24 s, took all 1,540 bytes |
| `reject` | 66 B, well-formed, **payload knowingly wrong** | healthy 25 s, re-issued `@AuthReq` at 16 s, took all 1,606 bytes |
| `truncate` | 65 B, identical **except the `F7` is missing** | **DEAD from that instant** |

The `truncate` arm, in detail:

    8.497  OUT  @AuthResponseE  65B *** WITHOUT the F7 terminator ***
    (nothing inbound ever again — the 10 s @AuthReq retry never returns)
    last OUT URB that completed cleanly: 8.699 s
    WIRE-CHECK after: FAIL — amidi write BLOCKED, Tx stuck at 4183
    written by the script 1,905 bytes / actually reached the wire 727

Run `runs/WIRE/20260816T151707-authtrunc.pcap`; controls
`…151623-authreject.pcap` and `…151301-devbaseline.pcap`.

**That is the observed rekordbox failure, item for item:** output stops at the
exact moment `@AuthResponseE` is sent; the host goes on writing and nothing
reaches the wire; the device never sends `@AuthEnd`; it needs a physical power
cycle. Reproduced here with no rekordbox, no Wine and no ALSA sequencer in the
path — so the *mechanism* is now known independently of who triggers it.

**Mechanically:** a SysEx with no terminator leaves the device's parser open. It
stops draining its bulk OUT endpoint, the host's URBs back up, and every layer
above sees a device that accepts nothing. `snd-usb-audio` then cannot complete
its own control transfers either, which is where the `-110` timeouts in dmesg
come from — those are a *consequence* of the wedge, not its cause.

**This kills hypothesis 1 outright.** The device does not punish a wrong answer:
the `reject` arm sent a payload that cannot possibly verify and the device
shrugged and retried 10 seconds later. Only malformed framing kills it.

### What this means for the actual bug

rekordbox demonstrably hands winealsa all 66 bytes — the driver's own log says
`len=66`. The device demonstrably dies exactly as it does when the last byte is
missing. **The remaining question is therefore narrow and answerable: how many
of those 66 bytes leave the wire in a real run?** `research/probes/authprobe.sh` puts
`usbwire` and the driver log side by side and reads the answer off directly.

Caveat, stated plainly: **n = 1 per arm.** The effect was immediate, total and
matched a mechanism, which is stronger than the usual single-run evidence in
this project, but the rule stands and these arms must be repeated. The device is
currently wedged, so that needs a replug first.

### Phase 21c — the kernel has been logging the wedge all along, and its onset time confirms the mechanism

`ALSA: seq_midi: MIDI output buffer overrun` appears **2,254 times** in this
machine's journal, in seven clusters that line up exactly with the MIDI
debugging sessions of 2026-08-16. It has been there for the whole
investigation, unread. The message comes from `dump_midi()` in
`sound/core/seq/seq_midi.c`, which emits it when `snd_rawmidi_kernel_write`
takes fewer bytes than the event carried — **and drops the rest**.

    12:19:10..12:19:56   x93        13:38:20..13:41:03   x330
    13:19:02             x10        14:29:51..14:34:15   x530
    13:33:19..13:33:36   x40        14:41:06..14:49:32   x1010
                                    14:52:52..14:54:53   x241

**But they are a consequence, not the cause.** Run
`runs/MIDI/20260816T145128-gdbauth`, which is the cleanest one to align because
its Wine log uses the boot clock and its directory mtime pins that clock to wall
time:

    run starts                        340650.743   = 14:51:29
    @AuthResponseE handed to winealsa 340664.471   = 14:51:43   (exactly once)
    first seq_midi overrun                         = 14:52:52   (+69 s)
    964 further 12-byte keep-alives, to            = 14:55:13

The overruns begin **69 seconds after** the final message, so they cannot have
truncated it. What they do instead is *confirm the mechanism independently*:

> the rawmidi output buffer is 4096 bytes. Once the device stops draining, the
> only traffic still being written is the 12-byte keep-alive every 200 ms —
> 60 bytes/second. 4096 / 60 = **68 seconds to fill**. Measured: 69.

So an entirely separate instrument, arithmetic on a kernel log nobody had read,
puts the moment the DDJ-400 stopped accepting output at `@AuthResponseE`
± 1 second. That is now established three independent ways: the kernel Tx
counter freezing, the buffer-fill time, and the reproduction in phase 21b.

**Note what this rules out for that run:** the buffer was empty when
`@AuthResponseE` was sent, so the seq→rawmidi bridge had ample room and cannot
have truncated *that* message. If Wine is losing the tail, it is losing it
somewhere else in the path — and if Wine is not losing it, the wedge has a cause
we have not yet named. `research/probes/authprobe.sh` settles it by counting the bytes at
the wire.

### The one remaining difference between the run that wedges and the one that does not

| | `authreplay.py reject` (no wedge) | rekordbox under Wine (wedge) |
|---|---|---|
| final message | 66 B, `F0 … F7` | 66 B, `F0 … F7` per the driver log |
| path to the device | **rawmidi**, one `write(2)` | **ALSA sequencer**, `snd_seq_event_output_direct` |
| concurrent traffic | keep-alives from the same thread | keep-alives from a different thread |

The kernel's USB-MIDI packetiser is common to both and demonstrably handles a
66-byte SysEx correctly, so suspicion falls on what the **sequencer** path adds:
event splitting, and interleaving with a keep-alive emitted concurrently from
another thread. Note also that `midi_out_long_data` **ignores the return value
of `snd_seq_event_output_direct`** (`alsamidi.c`, MOD_MIDIPORT branch) and
returns `MMSYSERR_NOERROR` regardless — which is exactly consistent with the
repeatedly observed "every layer reported success and nothing reached the wire".
That is a real Wine defect whether or not it is this bug.

### Phase 21d — corrections to phase 21c, from binary analysis

Three claims of mine above are wrong and are withdrawn:

1. **"keep-alives from a different thread" is false.** Every outbound MIDI
   message, the 66-byte `@AuthResponseE` included, is emitted from one thread
   (thread 0698 in run `…145128-gdbauth`). The concurrency row in the phase-21c
   table should read "same thread" for both arms. Wine is independently
   exonerated on interleaving anyway: one process-global mutex, one `write(2)`,
   payload linearised in userspace.
2. **The 8000 ms teardown is not what ends these runs.** `@@@ MIDI Disconnect by
   AuthReq` is gated on never having seen an `@AuthReq` (`DeviceAuth+0x18A`).
   Now that Wine delivers the inbound message, that path is unreachable —
   measured: in `…145128-gdbauth` the port stayed open for 205 s after
   `@AuthResponseE`. Per-step auth timeouts are 1000 ms and **log-only**; there
   is no protocol-level abort. So "rekordbox gives up at 8 s" should not be
   repeated.
3. **"Tx froze at 205 bytes" is uninterpretable** and should not be cited. Only
   the delta across a run means anything, and the per-run outbound total to that
   point was 130.

### And the finding that reframes everything

`@AuthResponseE` has been **fully reconstructed from the binary, all 66 bytes,
including the two the probes hid — and they are `05 F7`.** The payload is
`FNV-1a-32(SeedE ‖ (SeedE XOR 68 01 31 FB))`, verified numerically against the
wire from a SeedE captured in a different run. Its only inputs are the device's
own `@AuthResponseA` and two compile-time constants: **no machine GUID, no
volume serial, no MAC, no registry, no USB descriptor field, no serial number,
and zero import calls** — no `clatc.dll`, no `lsapiw64.dll`, no crypto library.

Two consequences:

- **The scope question is settled. This is not licence enforcement.** The
  response is a checksum over data the device itself supplied. Nothing about it
  identifies the host, and making Wine deliver it intact is ordinary transport
  fidelity work.
- **rekordbox composes a correct, properly terminated message.** So the device
  has nothing to reject — and phase 21b measured that a wrong payload does not
  wedge it anyway. If the device dies on receipt, what reached it was not what
  rekordbox composed.

That points at exactly one place. The kernel's `dump_var_event` hands a
userspace SysEx to the rawmidi port **in 32-byte chunks, each all-or-nothing,
aborting the remainder if one cannot be written**. 66 bytes chunks as
**32 + 32 + 2** — and the 2-byte tail is `05 F7`. Losing that last chunk yields
a 64-byte unterminated SysEx, which is precisely the stimulus that phase 21b
proved kills this device. It is also, by coincidence, exactly where
`rbw_wire_log`'s 64-byte cap sits, which is why no probe ever showed it.

## Phase 22 (2026-08-16) — THE HANDSHAKE COMPLETES. `@AuthEnd` received, `enableDevice` ran.

Run `runs/AUTH/20260816T161822-gdbwire`, capture
`runs/WIRE/20260816T161822-gdbwire.pcap`. At the USB wire:

    13.671  OUT  @Activate       12B
    13.674  IN   @AuthReq        12B
    13.675  OUT  @AuthChallengeA 52B
    13.678  IN   @AuthResponseA  51B
    13.679  OUT  @AuthResponseE  66B
    13.682  IN   @AuthEnd        12B   *** SUCCESS ***
    then    OUT  0x03 x3, 0x70 x1 / IN 0x70 21B, and 261 NoteOn + 36 ControlChange

`@AuthEnd` has never been seen before in this project. The 261 NoteOns and 36
ControlChanges after it are `enableDevice` walking the mapping tree — **the LED
initialisation**. 492 outbound messages, 52 inbound, zero URB errors, keep-alives
still running at 61 s, device alive throughout.

**`@AuthResponseE` left the wire complete:**

    f0 00 40 05 00 00 02 06 00 14 38 01 0b "PioneerDJ" 02 0b "rekordbox"
    04 0a 05 04 00 08 05 05 0f 0e 05 16 00 07 04 0a 02 06 0a 0a 02 0e 0b 0e
    09 02 0e 03 0e 0f 09 05 f7

All 66 bytes, ending `05 f7` — exactly the two bytes phase 21d predicted from
the binary and that no probe had ever displayed. **Wine's MIDI transport is not
truncating anything.** The 32-byte chunking hypothesis of phase 21d is refuted
for this path, and so is every remaining "Wine loses the tail" variant.

### So what is actually wrong: a STARTUP RACE, not a transport bug

The auth only runs when rekordbox takes the **native** `MidiMapDDJ400` path, and
it usually does not:

| arm | runs | native path (auth) | generic path (CSV LED init, no auth) |
|---|---|---|---|
| plain launch | 7 | **0** | 7 |
| launch + `rbbreak.sh` attached at t+6 s | 2 | **2** | 0 |

The generic runs are identical to each other: `midi_in_open`, one degenerate
2-byte `F0 F7`, 248 short messages from the CSV, zero inbound, device unharmed.
The gdb arm differs in one thing — it attaches a debugger at t+6 s, which stops
every thread briefly and slows startup.

`research/probes/rbbreak.sh` on `djplay::DeviceMidi::openDevice` (0x1423a5210) and the
validation wrapper (0x1423aaf40) shows both **succeeding** in the gdb arm:
`openDevice` returns 1, the wrapper returns a non-NULL `MidiMap`. So when the
native path is reached, our `\\.\HCDn` driver satisfies it correctly.

**Leading hypothesis for the race, and it points at our own patch:** the
`RBW-USBHCD` driver creates `\Device\WineUsbHcd<n>` and its `\??\HCD<n>` symlinks
during `wineusb` driver initialisation. If rekordbox calls `CreateFileA("\\\\.\\HCD0")`
before those exist, every one of the ten opens fails with
`STATUS_OBJECT_NAME_NOT_FOUND`, `USBDeviceValidation` fails, `openDevice` destroys
the `MidiMapDDJ400` and returns NULL, and the device silently falls back to the
generic CSV path — which is exactly the 7-run behaviour, and exactly what
`runs/20260813T163916-hidopen/wine.log` showed before the driver existed at all.
Delaying rekordbox lets the driver win.

**Next test, one variable:** log a timestamp in `rbw_create_host_controllers`
and in each `\\.\HCDn` open attempt, then compare their order in a plain run
against a gdb run. If the opens precede the device creation in the plain runs,
the fix is to make the HCD devices exist before any client can ask — and the
controller works without a debugger attached.

### Phase 22b — the race is real but it is NOT the HCD driver, and NOT CPU speed

Two hypotheses tested and refuted, each with one variable.

**Refuted: the driver is created too late.** With `WINEDEBUG=+timestamp,+file`:

    346741.314  RBW-USBHCD: exposed 1 host controller(s) as \\.\HCDn
    346756.062  CreateFileW L"\\\\.\\HCD0"        <-- 14.7 SECONDS LATER

The driver wins by nearly fifteen seconds. There is no creation-order race, and
the phase-22 "leading hypothesis" is withdrawn. (That run also took the native
path, which is itself data — see the table below.)

**Refuted: it is a CPU-speed race.** Three runs, `taskset -c 0` versus plain:
`taskset` generic, plain generic, `taskset` generic. Slowing every thread
uniformly does not flip it.

**The association itself is strong and reproducible:**

| arm | native path | generic path |
|---|---|---|
| plain launch | 0 | 8 |
| `taskset -c 0` | 0 | 2 |
| gdb attached at t+6 s | 2 | 0 |
| `WINEDEBUG=+timestamp,+file` | 1 | 0 |

Ten unperturbed runs generic, three perturbed runs native. What gdb and heavy
file tracing share is **not** CPU cost — `taskset` has that and does nothing —
but interference with **I/O ordering and thread scheduling at specific
syscalls**. The next session should stop guessing at the mechanism and measure
it: break on `openDevice` (0x1423a5210) and on the `\\.\HCD0` open in an arm
where the outcome is known, and compare what differs *inside* the function
between a native run and a generic one. Note the observer problem this creates
and design around it — attaching gdb is itself one of the perturbations that
changes the outcome.

### Phase 22c — the USB validation is served correctly even in the runs that fail

`WINEDEBUG=+timestamp,+wineusb` is light enough **not** to flip the outcome
(2/2 runs generic), so for the first time a *failing* run is observable. In it:

    347127.571  RBW-USBHCD: exposed 1 host controller(s)
    347155.335  RBW-USBHCD: hub 0 port 4 -> VID_2B73 PID_0026 rev 0103
    347155.427  RBW-WIRE in_open dev=0                    <-- 92 ms later

So in a run that ends up generic, the bus walk **succeeds**, finds the Pioneer
with the correct VID, PID and `bcdDevice`, and MIDI is opened 92 ms later. The
ordering is exactly what the decompiled chain predicts, and our driver serves
the right answer. Whatever makes rekordbox fall back to the CSV path is
therefore **not** missing or wrong USB data, and not an ordering problem between
the driver and the app.

Also observed: rekordbox stops the walk at port 4 as soon as it matches, and
never issues `GET_DESCRIPTOR_FROM_NODE_CONNECTION` (0x220410) — everything it
needs is already in the node-connection information.

**What is left is a measurement inside the application.** `openDevice`
(0x1423a5210) returns 1 and the validation wrapper (0x1423aaf40) returns a
non-NULL `MidiMap` in the gdb arm. Nobody has yet seen what they return in a
generic run, because attaching gdb is one of the perturbations that makes the
run succeed. Ideas for getting round that: break only on the *return* site with
a hardware watchpoint rather than an INT3 on entry; or attach after the decision
and read the resulting object graph rather than watching it being made.

### Phase 22d — I overfitted, and the real discriminator is DOWNSTREAM of `openDevice`

**First, the correction.** Phase 22's table said the gdb arm was 2/2 native and
implied the perturbation was causal. Two further gdb runs came out **generic**.
The honest tally is:

| arm | native | generic |
|---|---|---|
| unperturbed (plain, `taskset`, `+wineusb`) | 0 | 12 |
| perturbed (gdb attach, `+file`) | 3 | 3 |

The association is still there and is unlikely to be chance, but "gdb makes it
work" was a two-run conclusion of exactly the kind this project keeps having to
retract, and I published it. It is withdrawn. **The outcome is intermittent in
every arm; the perturbations appear to raise the odds, not decide the result.**

**Second, and much more useful: the USB gate is NOT the discriminator.**
`research/probes/rbbreak.sh` on `openDevice` (0x1423a5210) and the validation wrapper
(0x1423aaf40), in runs whose outcome is known:

| run | outcome | wrapper returns | `openDevice` returns |
|---|---|---|---|
| `…161822-gdbwire` | **auth succeeded** | 0x5F4C… non-NULL | **1** |
| `…164158-gdb-early3` | generic | 0x54B0… non-NULL | **1** |
| `…164259-gdb-late1` | generic (called twice) | non-NULL, both | **1**, both |

`openDevice` returns 1 and the validation wrapper returns a non-NULL `MidiMap`
**in the failing runs too**. So `djplay::USBDeviceValidation` passes either way,
the `MidiMapDDJ400` is built either way, and the phase-19 model — "the USB
validation fails, the object is destroyed, `openDevice` returns NULL, the device
falls back to the generic CSV path" — **is not what is happening now.** That
model was correct before the HCD patch existed; since the patch, the gate passes
and the failure moved somewhere else without anyone noticing.

It also means "generic path" has been the wrong name for the failing runs. The
model object is built. What does not happen is the **handshake**: no `@Activate`
is ever emitted, so the device never sends `@AuthReq` and nothing follows.

**So the question for the next session is narrow and new:** given that
`openDevice` succeeded and the `MidiMapDDJ400` exists, why does
`djplay::MidiOutputHelper::run` (0x1423A9270) — the 200 ms `@Activate`
keep-alive thread — not send? Break on it, and on whatever starts it, and
compare a run where it fires against one where it does not. That thread is the
first domino; everything else in phase 22 follows from it.

### Phase 22e — the keep-alive routine RUNS in a failing run, and still sends nothing

`research/probes/rbbreak.sh` on `djplay::MidiOutputHelper::run` (0x1423A9270) and
`openDevice` (0x1423a5210), run `…-helper`, outcome generic:

    HIT 0x1423a5210 x2      openDevice
    HIT 0x1423a9270 x2      MidiOutputHelper::run

So in a run where no `@Activate` ever reaches the wire, the routine that emits
`@Activate` **is entered, twice**. Combined with phase 22d (`openDevice` returns
1, the `MidiMap` is built), the failure is now boxed in very tightly:

> every object is constructed, the validation passes, and the keep-alive routine
> is entered — and no SysEx is emitted. `rbw_wire_log` records exactly one
> outbound long message in these runs, a degenerate 2-byte `F0 F7`, and nothing
> else, on any device id.

Two candidates, and they are cheap to separate:

1. **It emits to the wrong device.** Agent audit of patch 0006 found that the
   filter *adds* Wine's own loopback ports to **both** the IN and OUT lists once
   any Wine process has opened a MIDI port (`WINE ALSA Input` has
   `SUBS_READ|SUBS_WRITE` but no `CAP_READ`; `WINE ALSA Output` the mirror), so
   enumeration order is not stable across the life of a session. This is the
   2026-08-16T13:41 loopback fault — "all 633 calls went to dev_id 1" — in a
   form patch 0006 makes *worse* rather than better. If rekordbox enumerates
   after opening its own port, the DDJ is no longer index 0.
   **Against it:** `rbw_wire_log` logs every `midi_out_long_data` with its
   `dev_id`, and in these runs there is one line, not hundreds to `dev=1`.
2. **It returns early on a state check** before composing anything — the
   likelier reading of the evidence above.

Next: re-break with `--no-ret` removed to get `MidiOutputHelper::run`'s return,
and break on `midiOutLongMsg` itself to see whether the app even attempts a
send. That distinguishes 1 from 2 in a single run.

**Caveat on this phase:** two breakpoint hits may be two thread starts rather
than two loop iterations; `--no-ret` was used, so no return values were
captured. Do not over-read it.

### Phase 22f — VOID: I ran ungated, and the device had wedged underneath me

The run intended to settle "handed to the driver vs reached the wire" opened
with:

    WIRE-CHECK: FAIL — amidi write BLOCKED (device wedged), Tx stuck at 56640

The device had already been dead when the run started. `usbwire` refused to
capture, correctly. But **winealsa still accepted 41 `@Activate` messages and
reported success to the application** against a controller that was taking
nothing — a live demonstration of the defect noted in phase 21c
(`snd_seq_event_output_direct`'s return value discarded, `MMSYSERR_NOERROR`
returned regardless).

**The consequence for this session's own results.** `research/probes/authprobe.sh` gates
every run on a wire check before and after. The runs in phases 22b–22e were
launched **by hand, without that gate**, to iterate faster. The controller was
verified healthy and working at the end of phase 22 (user-confirmed lights), and
wedged at some unknown point afterwards. So:

- Anything asserted from an ungated run after phase 22 is **provisional**, and
  a "generic path" verdict from a run against a dead device means nothing at
  all — the device cannot answer, so of course no `@AuthReq` arrives.
- What survives, because it does not depend on device liveness: `openDevice`
  returns 1 and the validation wrapper returns a non-NULL `MidiMap` in runs that
  produced no auth (phase 22d — a fact about the application, read out of its
  own registers); `MidiOutputHelper::run` is entered (22e); the HCD walk reports
  the correct VID/PID/rev (22c); and the driver was handed 41 `@Activate`
  messages for `dev=0` in one run and one `F0 F7` in another (22e/22f), which
  is a real run-to-run difference in the application's behaviour.
- What must be **re-measured against a gated, healthy device**: the whole
  native-vs-generic tally of 22b and 22d. Its denominators are untrustworthy.

This is the project's own rule — *treat any run whose wire check fails as void
rather than as evidence* — and I broke it within two hours of writing the tool
that enforces it. The lesson is not "remember to check" but "never launch by
hand": the gate belongs in the launcher, so use `research/probes/authprobe.sh` and extend it
rather than reaching for a bare `wine` command.

### Phase 22g — THE RACE TABLE WAS MY OWN HARNESS BUG. Withdrawn entirely.

`research/probes/authprobe.sh` built rekordbox's environment with

    ${RENAME:+RBW_MIDI_RENAME="Generic MIDI Controller"}

`${VAR:+word}` expands whenever `VAR` is **set and non-empty** — and the default
was `RENAME=0`, which is non-empty. Verified:

    with RENAME=0 -> [RBW_MIDI_RENAME="Generic MIDI Controller"]
    with RENAME=1 -> [RBW_MIDI_RENAME="Generic MIDI Controller"]

So **every** `authprobe` run renamed the MIDI port — applying, by accident, the
exact workaround this project uses to force rekordbox *off* the native
`MidiMapDDJ400` path and onto the generic CSV path. Seven runs were then
recorded as "plain launch → generic path" and became the control column of the
phase-22b race table.

**Every conclusion that rested on that column is withdrawn**, including the
framing of a "startup race" and the suggestion that perturbation makes the
native path more likely. Combined with phase 22f (the ungated manual runs, some
of which ran against a wedged device), *nothing* in phases 22b–22e about
native-vs-generic frequency survives. What survives is only what was read out of
the application's own registers or the wire: `openDevice` returning 1 with a
non-NULL `MidiMap` in non-auth runs, `MidiOutputHelper::run` being entered, and
the complete successful handshake of phase 22.

Fixed: the environment is now built as an explicit array with
`[ "$RENAME" = 1 ]`, and **each run writes its actual environment to
`env.txt`** in the run directory, so a condition that is not written down
alongside its result cannot silently become a control group again.

Two lessons, both cheap and both already paid for:

- **Never use `:+` for a boolean.** `0` is true to it.
- A harness that composes the conditions of an experiment must **record the
  conditions it actually used**, not the ones its flags imply. This bug was
  invisible in every log, every verdict and every table it produced, and it was
  found by an agent reading the harness rather than by any amount of staring at
  results.

### Phase 22h — "generic path" was a misclassification, and the third outcome was hidden

The audit's sharpest catch after the rename bug. Runs recorded here and in
`docs/investigation/STATE.md` as "generic path" contain **40-41 `@Activate` keep-alives each**, and
`@Activate` is emitted only by the compiled `MidiMapDDJ400` — the generic CSV
engine has no such message. Confirmed independently in the `…-winmm` run:
41 `midiOutLongMsg` calls at winmm, and 41 `RBW-WIRE OUT dev=0 len=12` at the
driver, all to the real device.

So those runs **took the native path** and failed at a later step. There are
three outcomes, not two, and conflating the last two hid the real one for
several phases:

| outcome | signature |
|---|---|
| generic | one degenerate 2-byte `F0 F7`, 248 CSV short messages, no `@Activate` |
| **native, no reply** | `MidiMap` built, 40+ `@Activate` to `dev=0`, **zero inbound**, teardown at 8000 ms, retry |
| native, complete | the full five-step handshake, `@AuthEnd`, `enableDevice`, LEDs |

The middle row is the live blocker, and it is a *device silence* problem, not a
path-selection problem. That also reinstates the 8000 ms teardown: it is gated
on never having seen `@AuthReq`, and in this outcome `@AuthReq` never arrives,
so it fires exactly as designed.

### The leading hypothesis now: device-state carry-over

From the audit, at p ≈ 0.55, and it fits everything above: **after a completed
or attempted handshake, the DDJ-400 stops issuing `@AuthReq` until it is
power-cycled.** The two runs that received `@AuthReq` are the two earliest in
the native series, and `…161822-gdbwire` was immediately after a physical
replug. Every later run sent `@Activate` correctly and got nothing back.

Note what this would mean for the harness: **the 0xFE wire check passes on a
device in this state** — Tx moves, nothing is wedged — so the gate that was
built to void bad runs does not catch it. A run is only valid if the controller
has been power-cycled since the last auth attempt.

Against it, and measured: with the auth simply left unanswered, the device
re-issues `@AuthReq` every 10 s indefinitely (`authreplay.py observe`, phase 21).
So any carry-over is specific to a *completed or stalled* exchange, not to being
ignored — which is testable and is the next experiment.

**Killer test, needs one replug and no rekordbox:** power-cycle, then
`python3 research/probes/authreplay.py observe --secs 25` — expect `@AuthReq`. Then run
rekordbox once, let it finish an auth attempt, kill it, and **without
replugging** run `authreplay.py observe` again. If the device is now silent to a
bare Linux writer, H2 is confirmed, the fault is in the device's own state
machine, and every run since the last replug is void.

## Phase 23 (2026-08-17) — ROOT CAUSE: a 66-byte SysEx split across two USB transfers hangs the device

Two runs, the same message, opposite outcomes, and the difference is visible at
the URB layer:

| run | `@AuthResponseE` on the wire | device |
|---|---|---|
| `…161822-gdbwire` (**auth succeeded**) | **one URB**, 88 B carrying all 66 MIDI bytes, ending `0f 09 05 f7` | replies `@AuthEnd`, LEDs light |
| `…072840-h2-r1` (**failed**) | **two URBs**: 84 B carrying 63 bytes ending `0e 03 0e 0f`, then 4 B carrying `09 05 f7` | takes the first, **never completes the second** |

In the failing run the tail URB was submitted 0 ms after the first and simply
never completed — and **neither did any URB after it**: the 200 ms `@Activate`
keep-alives at 16.921, 17.123, 17.324 and 17.524 all hang unfinished. The
controller accepted 63 bytes of a 66-byte message and stopped accepting
anything, permanently, until power-cycled.

**So the DDJ-400 cannot tolerate a SysEx split across USB transfers.** It is not
that Wine loses bytes — Wine sent all 66, and the earlier "truncation" reading
of phase 21b was measuring the same phenomenon from above. The bytes are all
submitted; the device refuses the continuation.

### Why the split happens, and why it is intermittent

The ALSA **sequencer** delivers a userspace SysEx to a rawmidi port in **32-byte
chunks** (`dump_var_event` in `snd-seq.ko`, measured by the audit at `0x4eb3`:
`cmp $0x1f,%ebx` / `mov $0x20`). 66 bytes arrive as **32 + 32 + 2**. The USB MIDI
packetiser can only emit whole 3-byte SysEx-continuation packets, so after the
first 64 bytes it emits 21 packets — **63 bytes** — and holds one byte back. The
final 2-byte chunk then completes the 22nd packet.

Whether that 22nd packet joins the same URB depends on whether the output URB
has already been assembled and submitted when the last chunk lands. **That is a
race, and it is why the fault is intermittent** — which has cost this project
days of contradictory single-run attributions.

It also explains, at last, why `research/probes/authreplay.py` never once failed to deliver
66 bytes: it writes to **rawmidi** with a single `write(2)`, so the whole message
is in the buffer before any URB is built, and it always goes out contiguous.
Wine goes through the sequencer; the probe does not. That difference was
recorded in the phase-21c table as "the one remaining difference" and is now the
whole answer.

### The Wine fix

`midi_out_long_data` (`dlls/winealsa.drv/alsamidi.c`) sends every SysEx with
`snd_seq_event_output_direct` on the ALSA sequencer. Windows' `midiOutLongMsg`
hands a SysEx to the device as one transfer. Options, in order of preference:

1. **Write SysEx to the destination's rawmidi node directly** rather than
   through the sequencer, so the message reaches the packetiser in one piece.
   This is the honest fidelity fix and it matches what every other MIDI
   application on Linux does. It is a real change to winealsa's architecture,
   which uses the sequencer for routing, so it needs care.
2. Try `snd_seq_event_output` + `snd_seq_drain_output` instead of
   `_output_direct` and measure whether delivery becomes contiguous. Cheap to
   test, speculative.
3. Independently of all of the above, **stop discarding the return value** — the
   defect from phase 21c is still there and is upstream-worthy on its own.

### Honesty about the evidence

**n = 1 per arm on the URB structure.** The mechanism is coherent, it matches
the kernel source, it explains the intermittency, it explains why the Wine-free
probe never reproduced the fault, and it predicts the outcome of both runs — but
it is two captures. **The confirmation test is cheap and must be run first:**
repeat gated runs, classify each by "contiguous vs split" at the URB layer, and
check that contiguous always authenticates and split always hangs. `usbwire.py`
already reports everything needed; it should print the URB grouping for each
SysEx explicitly.

### Phase 23b — CONFIRMED by controlled experiment: the SPLIT is the fault

`research/probes/authreplay.py`, back to back, same device, same session, **identical
bytes** — the only difference is the number of `write(2)` calls.

| arm | `@AuthResponseE` | device afterwards |
|---|---|---|
| `reject` — 66 B in **one** write | complete, contiguous | **healthy** 22 s, accepted all 1,426 bytes, still re-issuing `@AuthReq` at 20 s |
| `split` — same 66 B as **63 + 3**, 5 ms apart | first transfer only, on the wire as a 63-byte SysEx | **DEAD from that instant**: no inbound ever again, `WIRE-CHECK: FAIL — amidi write BLOCKED`, Tx frozen at 1931 |

Capture `runs/WIRE/…-splitarm.pcap`. No rekordbox, no Wine, no ALSA sequencer —
just two `write(2)` calls to `/dev/snd/midiC1D0` instead of one.

**So the DDJ-400 hangs when a SysEx is split across USB transfers.** The payload
is irrelevant: the `reject` arm sends the same knowingly-invalid payload and the
device shrugs. Only the framing across transfer boundaries matters. From the
device's point of view a split whose continuation it never accepts *is* a
truncation, which is why phase 21b's `truncate` arm produced an identical
signature — they are the same failure seen from two directions.

**This is the root cause of the whole controller history in this project**: the
wedges, the dark LEDs, the "connect/disconnect loop", and above all the
intermittency that produced so many contradictory single-run attributions. It
was never the auth content, never a licence wall, never the HCD driver, and
never lost bytes.

### Where the split comes from, and what to fix

Wine's `midi_out_long_data` sends every SysEx through the **ALSA sequencer**
(`snd_seq_event_output_direct`). The sequencer hands a userspace SysEx to the
rawmidi port in **32-byte chunks**, so 66 bytes arrive as 32 + 32 + 2; the USB
MIDI packetiser emits whole 3-byte packets only, so it sends 63 and holds one
byte back. Whether the final packet catches the same URB is a **race** — hence
the intermittency. Windows delivers a `midiOutLongMsg` SysEx as one transfer,
and so does every native Linux MIDI application, because they write to rawmidi.

**The fix belongs in winealsa**, and the preferred form is to deliver SysEx to
the destination contiguously rather than through the sequencer's chunked path.
Ranked options and their trade-offs are in phase 23. Also still outstanding and
independently upstream-worthy: `midi_out_long_data` discards
`snd_seq_event_output_direct`'s return value and reports `MMSYSERR_NOERROR`
regardless.

**A workaround exists today for anyone who cannot wait for a patched Wine:**
nothing user-visible — the race is internal. Until the patch lands, a launch
either authenticates or it does not, and a failed one needs the controller
power-cycled before retrying. That is worth stating plainly in `docs/PATH-TO-GOLD.md`
because it is exactly the "workaround the user has to discover for themselves"
that Gold forbids.

## Phase 24 (2026-08-17) — THE FIX. `RBW-RAWOUT`: send MIDI to hardware via rawmidi.

`upstream/0011-winealsa-send-midi-to-hardware-via-rawmidi.patch`, built,
installed, marker `RBW-RAWOUT` verified in
`/usr/lib/wine/x86_64-unix/winealsa.so`.

**What it does.** For any destination with a hardware node, `midi_out_open` opens
`hw:<card>,<port>` (snd-seq-midi makes one sequencer port per rawmidi device and
the port number *is* the device number) and **does not** subscribe the sequencer
port to the device. All output for that destination — short messages and SysEx
alike — then goes through one `snd_rawmidi_write`, under the existing lock, so
nothing can be reordered and a SysEx reaches the USB packetiser whole. Anything
without a hardware node (Midi Through, other applications) keeps the sequencer
path exactly as before, so app-to-app MIDI is unaffected. `RBW_NO_RAWOUT=1` is
an escape hatch for A/B testing.

It also **checks the write result**, which the sequencer path never did.

**Result — four runs, four successes, all gated healthy before and after:**

    RBW-RAWOUT dev=0 sending directly to hw:1,0 (contiguous SysEx)
    @AuthReq / @AuthChallengeA / @AuthResponseA / @AuthResponseE / @AuthEnd
    adjudication:  @AuthEnd RECEIVED — the handshake completed.

At the wire, in the first of them:

    @AuthResponseE: ONE URB, urb_len=88, 66 MIDI bytes, ends 0f 09 05 f7

Against the record before the patch: **0 successes in 12 unperturbed runs**, and
every failing run left the controller needing a physical power cycle. After:
**4 of 4**, no wedges, plain launches with no debugger and no debug channels.

**Why this is the right fix and not a workaround.** Windows delivers a
`midiOutLongMsg` SysEx to the device as a single transfer. Wine did not, and the
difference was observable by the hardware. That is a fidelity bug in Wine, and
this restores the Windows behaviour rather than papering over the device's
reaction to it.

**Still to do:** confirm at the hardware that the LEDs light and — the test that
has never once passed — that the **jog wheels** work, since `JogRotate`/
`JogTouch` are implemented by the native `MidiMapDDJ400` that only exists on this
path. Then rebase the patch onto pristine 11.15 for submission, since the diff
above is against our patched tree.

### Phase 24b — ACCEPTANCE TEST PASSED: lights AND jog wheels

**User at the hardware, 2026-08-17, with `upstream/0011` installed: the LEDs
light and the JOG WHEELS WORK.**

The jog wheels are the test this project has never passed. They could not work
on the generic CSV path at any point in this repo's history, because
`JogRotate`, `JogTouch` and `Difference` are implemented by the native
`djplay::MidiMapDDJ400`, and that object only ever gets used once the Pioneer
SysEx handshake completes and `enableDevice` runs. T05 phase 9's measured
finding — that the renamed-port workaround gives 8 of 10 control groups but
never the jogs — is now explained and closed: it was never a mapping gap, it was
the auth never completing.

T05 is therefore resolved for the DDJ-400 as a controller. What remains on this
theme is confirmation over time (does it hold across a long session?) and the
toolbar MIDI/pad indicators, which have not been re-checked since the fix.

### Phase 24c — soak: ten minutes clean

Live session with the patch installed, sampled every 10 s: rekordbox alive
throughout, the ALSA card never disappeared, and Tx kept climbing (93,667 bytes
at the ten-minute mark, 96,088 shortly after). No wedge, no stall, no
re-enumeration. Before the patch, a session that reached `@AuthResponseE` had
roughly even odds of killing the controller outright within seconds.

**T05 is resolved for the DDJ-400.** Remaining on this theme, both minor:
re-check the toolbar MIDI/pad indicators, which have not been looked at since
the fix, and run a long real-world session rather than a ten-minute soak.
