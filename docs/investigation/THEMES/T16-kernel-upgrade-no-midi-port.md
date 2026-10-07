# T16 — Kernel upgraded without reboot: controller has no MIDI port

**Status:** OPEN (diagnosed; cure is a reboot, verification pending) · **Opened:** 2026-10-07

## Symptom
User, 2026-10-07, with rekordbox 7.2.18 up on wine-staging 11.18 (T15 build):
*"OK - we have regression. No controller detected"*.

All launcher checks were `ok`, including "Pioneer device present and its HID node
is readable". `verifyloaded.sh` was green (winealsa.so and winex11.so both from the private tree).

## Evidence (2026-10-07, live)
- `lsusb`: `2b73:0026 Pioneer DJ Corporation DDJ-400`. `/proc/asound/cards`: card 1 DDJ400.
- `amidi -l`: `IO hw:1,0,0 DDJ-400 MIDI 1`, so the **rawmidi device exists**.
- `aconnect -l` / `/proc/asound/seq/clients`: only System, PipeWire-System and
  PipeWire-RT-Event. **No DDJ-400 sequencer client.** (Recorded working state
  had `client 20: 'DDJ-400'`.)
- `lsmod`: no `snd_seq_midi`. `modinfo snd_seq_midi`: `Module snd_seq_midi not found`.
- `uname -r` = `7.2.4-arch1-2`; booted 2026-09-13 17:16. `/usr/lib/modules/`
  holds only `6.18.54-1-lts` and `7.2.7-arch1-1`.
  `pacman.log`: `[2026-09-28T08:54:00] upgraded linux (7.2.4.arch1-2 -> 7.2.7.arch1-1)`.
- Kernel log: the DDJ-400 was replugged today at 16:10 and 16:41.

## Root cause (diagnosed; confirmation is the post-reboot check below)
Arch removes the running kernel's module tree when `linux` is upgraded. On
replug the kernel requests `snd_seq_midi` to make the sequencer port, and that
cannot load. Wine's winealsa enumerates MIDI through the **sequencer**, so the
controller is invisible to rekordbox. **Not Wine, not the 11.18 build, not the patches.**

Unresolved detail: whether the 11.16 → 11.18 move or the replug came first does
not matter. Any replug after 2026-09-28 without a reboot reproduces this.

## Fix
- **Cure:** reboot into 7.2.7. User action.
- **Launcher** (`bin/rekordbox-wine`, Controller section): if a Pioneer device is
  on USB but no `DDJ|Pioneer` client is in `/proc/asound/seq/clients`, it reports FAIL.
  With `/lib/modules/$(uname -r)` missing it says "Reboot". Otherwise it says
  `sudo modprobe snd_seq_midi` and replug. Verified on the live failing state:
  `FAIL the controller has no MIDI port: kernel 7.2.4-arch1-2 is running but its modules were removed by an upgrade`.
- **Launcher** `desktop_tell()`: `notify-send` when there is no tty. The menu
  entry is `Terminal=false`, so every FAIL and T14's whole "Not launching"
  refusal had been printed to nowhere.
- Packaging idea, not done: Arch's `kernel-modules-hook` keeps the running
  kernel's modules across upgrades. Possible optdepend.

## Next
After reboot: `aconnect -l | grep DDJ`, then the launcher's
`ok controller has an ALSA sequencer port` (positive branch not yet observed),
then rekordbox detects the DDJ-400. That is the first DDJ-400 measurement on
any Wine after 11.15 (see STATE: never re-measured on 11.16).
