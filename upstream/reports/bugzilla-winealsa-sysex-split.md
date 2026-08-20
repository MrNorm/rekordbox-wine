# WineHQ Bugzilla draft — winealsa splits SysEx across USB transfers

**Component:** winealsa.drv
**Version:** 11.15 (reproduced on wine-staging 11.15; the code is unchanged in master)
**Severity:** normal — data corruption as the device sees it; can leave USB MIDI
hardware unusable until it is physically power-cycled.

## Summary

`midi_out_long_data()` sends every System Exclusive message through the ALSA
**sequencer**. The sequencer delivers a userspace SysEx to a rawmidi port in
32-byte chunks (`dump_var_event`), so a 66-byte message arrives at the USB MIDI
packetiser as 32 + 32 + 2. That packetiser emits whole 3-byte
SysEx-continuation packets only, so after the first 64 bytes it emits 21
packets — 63 bytes — and holds one byte back until the last chunk arrives.
**Whether the final packet joins the same URB is a race.**

Windows delivers a `midiOutLongMsg()` SysEx to the device as a single transfer.
Native Linux MIDI applications do the same, because they write to rawmidi.

## Impact

Devices that do not tolerate a SysEx split across two USB transfers hang. A
Pioneer DDJ-400 (2b73:0026) stops accepting output **permanently** from that
moment — the remainder of the SysEx and every subsequent message go
unacknowledged — and only a physical power cycle recovers it.

Because it is a race, the failure is intermittent, which makes it very hard to
attribute from the application's side: `midiOutLongMsg` returns
`MMSYSERR_NOERROR`, the driver logs nothing, and the ALSA byte counters move.

## How to reproduce without Wine

Write a well-formed 66-byte SysEx to `/dev/snd/midiC<card>D0`, once with a
single `write(2)` and once as two writes of 63 and 3 bytes a few milliseconds
apart. On a DDJ-400 the first leaves the device healthy and responsive; the
second kills it until it is unplugged. The bytes are identical in both cases.

## Evidence with Wine (usbmon capture)

Same application, same message, two runs:

    @AuthResponseE as ONE URB   (88 B, 66 MIDI bytes)  -> device replies, handshake completes
    @AuthResponseE as TWO URBs  (84 B + 4 B)           -> device hangs, no URB after it ever completes

## Secondary defect in the same function

The return value of `snd_seq_event_output_direct()` is discarded and
`MMSYSERR_NOERROR` is returned unconditionally. A message that never reached the
device is therefore indistinguishable from one that did. Observed live: the
driver accepted 41 messages against a device that was taking nothing.

## Proposed fix

`0011-winealsa-send-midi-to-hardware-via-rawmidi.patch` — for destinations that
are backed by a card, open `hw:<card>,<port>` and send all output for that
destination through `snd_rawmidi_write()`, without also subscribing the
sequencer port (one route, so short and long messages cannot be reordered).
Destinations with no card keep the sequencer path, so application-to-application
MIDI is unchanged. The write result is checked.

Tested on a DDJ-400 with rekordbox 7.2.17: **0 successful device handshakes in
12 runs before, 4 of 4 after**, with no hangs.

## Notes for the reviewer

- `snd-seq-midi` creates one sequencer port per rawmidi device and the port
  number *is* the device number, so `hw:<card>,<port>` addresses the same
  endpoint the sequencer would have routed to.
- Opening the rawmidi node while the sequencer bridge also holds it would fail
  with `-EBUSY`; skipping `snd_seq_connect_to()` avoids that and is also what
  keeps message ordering single-routed.
