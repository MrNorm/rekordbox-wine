#!/usr/bin/env python3
"""Decode a usbmon pcap into a MIDI-aware, URB-status-aware transcript.

Why this exists: every MIDI instrument in this project so far has measured a
*software* layer -- Wine's own logs, ALSA's byte counters, aseqdump on the
sequencer.  All three report success for a byte that the device never accepted:
the kernel's Tx counter increments when the rawmidi layer takes the byte, not
when the URB completes.  This decoder reads the URB completion status straight
off the wire, so "rekordbox sent it" and "the device took it" become two
separate, separately-visible facts.

It parses the Linux USB pseudo-header itself (DLT 220/249, 64-byte header) so
the decode does not depend on tshark's dissector version.

Usage:  usbwire.py <capture.pcap> [--dev N] [--all]
"""

import struct
import sys

# Pioneer DDJ SysEx: F0 00 40 05 00 00 02 06 00 <cmd> ... F7
# Command byte sits at offset 9; names from the decompilation recorded in
# docs/investigation/THEMES/T05-controller.md (djplay::MidiMap::find indexes a 256-entry table by
# data[9]).
PIONEER_CMD = {
    0x11: "@AuthReq        (device -> host, starts auth)",
    0x12: "@AuthChallengeA (host -> device)",
    0x13: "@AuthResponseA  (device -> host)",
    0x14: "@AuthResponseE  (host -> device, final proof)",
    0x15: "@AuthEnd        (device -> host, SUCCESS -> enableDevice/LEDs)",
    0x50: "@Activate       (host -> device, 200ms keep-alive)",
}

XFER = {0: "iso", 1: "int", 2: "ctrl", 3: "bulk"}

# usb_submit_urb returns -EINPROGRESS (-115) on a submission record; that is
# normal and is not an error.
SUBMIT_PENDING = -115

ERRNO = {
    -32: "EPIPE (endpoint stalled)",
    -71: "EPROTO (bus protocol error)",
    -75: "EOVERFLOW (babble)",
    -84: "EILSEQ (CRC error)",
    -108: "ESHUTDOWN (device disabled)",
    -110: "ETIMEDOUT (no response -- THE WEDGE)",
    -19: "ENODEV (device gone)",
    -2: "ENOENT (urb killed)",
    -104: "ECONNRESET (urb unlinked)",
}


def read_pcap(path):
    """Yield (ts, raw_bytes) for each packet. Handles pcap and pcapng."""
    with open(path, "rb") as fh:
        blob = fh.read()
    magic = blob[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        endian, nano = "<", magic == b"\x4d\x3c\xb2\xa1"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        endian, nano = ">", magic == b"\xa1\xb2\x3c\x4d"
    else:
        sys.exit(f"{path}: not a classic pcap (pcapng not supported; "
                 f"capture with 'tshark -F pcap' or dumpcap default)")
    off = 24
    while off + 16 <= len(blob):
        tss, tsu, caplen, _orig = struct.unpack(endian + "IIII", blob[off:off + 16])
        off += 16
        pkt = blob[off:off + caplen]
        off += caplen
        yield tss + tsu / (1e9 if nano else 1e6), pkt


def parse_urb(pkt):
    if len(pkt) < 64:
        return None
    (urb_id, ev, xtype, epnum, devnum, busnum, setup_f, data_f,
     ts_sec, ts_usec, status, length, len_cap) = struct.unpack(
        "<Q c B B B H c c q i i i i", pkt[:40])
    return {
        "id": urb_id,
        "event": ev.decode("latin1"),
        "xfer": XFER.get(xtype, str(xtype)),
        "ep": epnum & 0x7F,
        "dir": "IN " if epnum & 0x80 else "OUT",
        "dev": devnum,
        "bus": busnum,
        "status": status,
        "length": length,
        "data": pkt[64:64 + max(len_cap, 0)],
    }


def usb_midi_to_stream(data):
    """USB-MIDI 1.0: 4-byte packets, first nibble is the cable, second the CIN.
    CIN 0x0 and 0x1 are reserved; 0x5 is a 1-byte SysEx end, 0x6 two, 0x7 three;
    everything else carries its own length. Returns the raw MIDI byte stream."""
    out = bytearray()
    for i in range(0, len(data) - 3, 4):
        cin = data[i] & 0x0F
        payload = data[i + 1:i + 4]
        if cin in (0x5, 0xF):
            out += payload[:1]
        elif cin in (0x2, 0x6, 0xC, 0xD):
            out += payload[:2]
        elif cin in (0x0, 0x1):
            continue  # reserved / misuse
        else:
            out += payload[:3]
    return bytes(out)


def name_midi(stream):
    if not stream:
        return ""
    if stream[0] == 0xF0:
        if len(stream) > 9 and stream[1:4] == b"\x00\x40\x05":
            cmd = stream[9]
            return f"Pioneer SysEx {len(stream)}B  cmd=0x{cmd:02x}  " \
                   f"{PIONEER_CMD.get(cmd, 'UNKNOWN COMMAND')}"
        return f"SysEx {len(stream)}B (non-Pioneer)"
    st = stream[0] & 0xF0
    names = {0x80: "NoteOff", 0x90: "NoteOn", 0xA0: "Aftertouch",
             0xB0: "ControlChange", 0xC0: "ProgramChange",
             0xD0: "ChanPressure", 0xE0: "PitchBend"}
    if stream[0] == 0xFE:
        return "ActiveSensing"
    if st in names:
        return f"{names[st]} ch{stream[0] & 0x0F} " \
               f"{' '.join(f'{b:02x}' for b in stream[1:3])}"
    return ""


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if not args:
        sys.exit(__doc__)
    path = args[0]
    want_dev = None
    if "--dev" in sys.argv:
        want_dev = int(sys.argv[sys.argv.index("--dev") + 1])

    t0 = None
    submits = {}
    errors = []
    last_ok_out = None
    counts = {"out": 0, "in": 0, "out_bytes": 0, "in_bytes": 0}

    print(f"{'time':>9}  {'dir':3} {'ep':>3} {'st':>5}  message")
    print("-" * 96)

    for ts, pkt in read_pcap(path):
        u = parse_urb(pkt)
        if not u:
            continue
        if want_dev is not None and u["dev"] != want_dev:
            continue
        if u["xfer"] not in ("bulk", "int") and "--all" not in flags:
            continue
        if t0 is None:
            t0 = ts
        rel = ts - t0

        if u["event"] == "S":
            submits[u["id"]] = (rel, u["data"])
            if u["data"]:
                stream = usb_midi_to_stream(u["data"])
                if stream:
                    counts["out"] += 1
                    counts["out_bytes"] += len(stream)
                    print(f"{rel:9.3f}  {u['dir']} {u['ep']:3d} {'':>5}  "
                          f"{name_midi(stream)}")
                    print(f"{'':9}  {'':3} {'':3} {'':>5}    "
                          f"{' '.join(f'{b:02x}' for b in stream)}")
            continue

        # completion
        st = u["status"]
        submitted = submits.pop(u["id"], None)
        if st not in (0, SUBMIT_PENDING):
            errors.append((rel, u, st))
            print(f"{rel:9.3f}  {u['dir']} {u['ep']:3d} {st:5d}  "
                  f"*** URB ERROR: {ERRNO.get(st, 'errno ' + str(st))} ***")
            continue
        if u["dir"] == "OUT" and st == 0:
            last_ok_out = rel
        if u["dir"] == "IN " and u["data"]:
            stream = usb_midi_to_stream(u["data"])
            if stream:
                counts["in"] += 1
                counts["in_bytes"] += len(stream)
                print(f"{rel:9.3f}  {u['dir']} {u['ep']:3d} {st:5d}  "
                      f"{name_midi(stream)}")
                print(f"{'':9}  {'':3} {'':3} {'':>5}    "
                      f"{' '.join(f'{b:02x}' for b in stream)}")

    print("-" * 96)
    print(f"OUT messages {counts['out']:5d}  ({counts['out_bytes']} MIDI bytes)")
    print(f"IN  messages {counts['in']:5d}  ({counts['in_bytes']} MIDI bytes)")
    print(f"last OUT URB that completed cleanly: "
          f"{('%.3f s' % last_ok_out) if last_ok_out is not None else 'NONE'}")
    if errors:
        print(f"\n{len(errors)} URB error(s). First at {errors[0][0]:.3f}s: "
              f"{ERRNO.get(errors[0][2], errors[0][2])}")
    else:
        print("\nNo URB errors. If output stopped anyway, the device accepted "
              "every byte and chose not to reply -- that is a device-side "
              "decision, not a transport fault.")
    if submits:
        print(f"{len(submits)} URB(s) submitted and NEVER COMPLETED "
              f"(earliest {min(v[0] for v in submits.values()):.3f}s) -- "
              f"a hung URB is the signature of the wedge.")


if __name__ == "__main__":
    main()
