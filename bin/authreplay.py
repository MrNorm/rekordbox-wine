#!/usr/bin/env python3
"""Drive the DDJ-400 Pioneer auth handshake from pure Linux — no Wine, no rekordbox.

WHY. The investigation has been trying to explain a stall at step 4 of 5 while
looking only at runs that involve the whole stack: rekordbox, winmm, winealsa,
the ALSA sequencer, the kernel and the device. That is five layers to blame for
one symptom. This talks to the rawmidi node directly, so the device's own
behaviour can be characterised with nothing else in the path.

It answers questions that no full-stack run can:

  observe    Does the device start the auth on its own, and how long does it
             keep talking if the host never answers? (the control — establishes
             whether the device has its own timeout, which would mean the
             8000 ms deadline is not the only clock)
  reject     Send a syntactically perfect @AuthResponseE whose payload is
             deliberately wrong. If the device then stops accepting output, the
             observed "wedge" is just what this device DOES when it rejects an
             auth, and the real problem is the content of rekordbox's response.
             If it keeps accepting, a rejection alone cannot explain the wedge.
  truncate   Send the same message with the terminating F7 removed. If that
             reproduces the symptom exactly, then dropping the tail of a
             66-byte SysEx is a sufficient explanation.
  split      Send the same COMPLETE, well-formed message, but in two write(2)
             calls -- 63 bytes then the final 3 -- with a short gap, so the
             kernel packs them into two separate USB transfers. This is the
             decisive test of phase 23: under Wine the auth succeeds when the
             66 bytes go out as one URB and hangs the device when they are
             split 63 + 3, and the difference is a race inside the ALSA
             sequencer path. If splitting kills the device here, with no Wine
             in the picture and a payload identical to the `reject` arm which
             does NOT kill it, then the split itself is the fault and the fix
             belongs in winealsa.

SCOPE. This sends host-generated challenge data and a KNOWN-INVALID response.
It does not forge, replay or compute a valid authentication, and it cannot
authenticate the controller — the challenge is a fresh nonce each session, so
there is nothing here to replay. The purpose is to characterise a failure mode,
which is diagnosis, not circumvention.

Usage: authreplay.py [observe|reject|truncate] [--secs N] [--dev /dev/snd/midiC1D0]
"""

import errno
import os
import select
import sys
import time

HDR = bytes([0xF0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x02, 0x06, 0x00])
NAMES = {0x11: "@AuthReq", 0x12: "@AuthChallengeA", 0x13: "@AuthResponseA",
         0x14: "@AuthResponseE", 0x15: "@AuthEnd", 0x50: "@Activate"}


def tlv(tag, data):
    """Pioneer TLV: the length byte counts the tag and the length byte itself."""
    return bytes([tag, len(data) + 2]) + data


def msg(cmd, body):
    return HDR + bytes([cmd, len(body) + 2]) + body + b"\xf7"


def activate():
    """F0 00 40 05 00 00 02 06 00 50 01 F7 — captured verbatim from rekordbox.
    Note the byte after the command is 0x01, not a TLV length, so @Activate is
    built literally rather than through msg()."""
    return bytes([0xF0, 0x00, 0x40, 0x05, 0x00, 0x00, 0x02, 0x06,
                  0x00, 0x50, 0x01, 0xF7])


def challenge_a(nonce):
    return msg(0x12, tlv(1, b"PioneerDJ") + tlv(2, b"rekordbox") + tlv(3, nonce))


def response_e(payload4, payload5):
    return msg(0x14, tlv(1, b"PioneerDJ") + tlv(2, b"rekordbox")
               + tlv(4, payload4) + tlv(5, payload5))


def hexs(b):
    return " ".join(f"{x:02x}" for x in b)


def describe(m):
    if len(m) > 9 and m[:4] == HDR[:4]:
        cmd = m[9]
        return f"{NAMES.get(cmd, 'cmd 0x%02x' % cmd):16s} {len(m):3d}B"
    return f"{'(non-Pioneer)':16s} {len(m):3d}B"


def decode_tlv(m):
    """Body starts after the 9-byte header, command byte and length byte."""
    out, i = [], 11
    end = len(m) - 1
    while i + 1 < end:
        tag, ln = m[i], m[i + 1]
        if ln < 2 or i + ln > end:
            out.append(f"  tag {tag:02x} len {ln} <malformed>")
            break
        data = m[i + 2:i + ln]
        ascii_ = "".join(chr(c) if 32 <= c < 127 else "." for c in data)
        printable = all(32 <= c < 127 for c in data) and len(data) > 2
        out.append(f"  tag {tag:02x}  {len(data):2d}B  "
                   + (f'"{ascii_}"' if printable else hexs(data)))
        i += ln
    return "\n".join(out)


class Wire:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
        self.buf = bytearray()
        self.blocked_at = None
        self.sent = 0

    def send(self, data, t0):
        """Non-blocking write. A short write or EAGAIN is the device refusing to
        take bytes — the precise, timestamped signature of the wedge."""
        try:
            n = os.write(self.fd, data)
        except OSError as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                if self.blocked_at is None:
                    self.blocked_at = time.time() - t0
                print(f"  {time.time() - t0:7.3f}  *** WRITE REFUSED (EAGAIN) "
                      f"after {self.sent} bytes — the device has stopped "
                      f"accepting output ***")
                return 0
            raise
        self.sent += n
        if n != len(data):
            print(f"  {time.time() - t0:7.3f}  *** SHORT WRITE {n}/{len(data)} ***")
        return n

    def poll(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return []
        try:
            self.buf += os.read(self.fd, 4096)
        except OSError as e:
            if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                raise
            return []
        return self._extract()

    def _extract(self):
        msgs = []
        while True:
            try:
                s = self.buf.index(0xF0)
            except ValueError:
                self.buf.clear()
                break
            try:
                e = self.buf.index(0xF7, s)
            except ValueError:
                del self.buf[:s]
                break
            msgs.append(bytes(self.buf[s:e + 1]))
            del self.buf[:e + 1]
        return msgs


def main():
    mode = "observe"
    secs = 20.0
    dev = "/dev/snd/midiC1D0"
    argv = sys.argv[1:]
    if argv and not argv[0].startswith("-"):
        mode = argv[0]
    if "--secs" in argv:
        secs = float(argv[argv.index("--secs") + 1])
    if "--dev" in argv:
        dev = argv[argv.index("--dev") + 1]
    if mode not in ("observe", "reject", "truncate", "split"):
        sys.exit(__doc__)

    print(f"mode={mode}  device={dev}  duration={secs}s")
    print("Sending @Activate every 200 ms, exactly as rekordbox does.\n")
    print(f"{'time':>9}  dir  message")
    print("-" * 78)

    w = Wire(dev)
    t0 = time.time()
    next_ka = 0.0
    state = "waiting for @AuthReq"
    responded = False
    seen = {}
    last_in = None

    while time.time() - t0 < secs:
        now = time.time() - t0
        if now >= next_ka:
            w.send(activate(), t0)
            next_ka = now + 0.2

        for m in w.poll(0.05):
            now = time.time() - t0
            last_in = now
            cmd = m[9] if len(m) > 9 else -1
            seen[cmd] = seen.get(cmd, 0) + 1
            print(f"{now:9.3f}  IN   {describe(m)}")
            print(f"{'':9}       {hexs(m)}")
            body = decode_tlv(m)
            if body:
                print(body)

            if cmd == 0x11 and not responded:
                # Host-generated nonce, same shape as rekordbox's: 16 nibbles.
                nonce = bytes([(i * 7 + 3) & 0x0F for i in range(16)])
                out = challenge_a(nonce)
                print(f"{time.time() - t0:9.3f}  OUT  {describe(out)}  "
                      f"(host nonce)")
                w.send(out, t0)
                state = "waiting for @AuthResponseA"
                responded = True

            elif cmd == 0x13:
                state = "got @AuthResponseA"
                if mode == "observe":
                    print(f"{'':9}       [observe] not answering — watching how "
                          f"long the device keeps talking")
                    continue
                # A syntactically perfect message with a payload that is known
                # to be wrong. This cannot authenticate anything; it asks the
                # device what it does when the proof does not check out.
                out = response_e(bytes(8), bytes(20))
                if mode == "split":
                    # Identical bytes to the `reject` arm -- only the number of
                    # write(2) calls differs. 63 is where the USB MIDI
                    # packetiser lands when the sequencer feeds it 32+32+2:
                    # 21 whole 3-byte packets, one byte held back.
                    head, tail = out[:63], out[63:]
                    print(f"{time.time() - t0:9.3f}  OUT  @AuthResponseE   "
                          f"{len(out)}B *** SPLIT {len(head)} + {len(tail)} "
                          f"across two writes ***")
                    w.send(head, t0)
                    time.sleep(0.005)
                    w.send(tail, t0)
                    state = "sent split response"
                    continue
                if mode == "truncate":
                    out = out[:-1]  # drop the F7 — the hypothesis under test
                    print(f"{time.time() - t0:9.3f}  OUT  @AuthResponseE   "
                          f"{len(out)}B *** WITHOUT the F7 terminator ***")
                else:
                    print(f"{time.time() - t0:9.3f}  OUT  {describe(out)}  "
                          f"(deliberately invalid payload)")
                w.send(out, t0)
                state = f"sent {mode} response"

    print("-" * 78)
    print(f"final state: {state}")
    print("messages received: " + (", ".join(
        f"0x{c:02x} {NAMES.get(c, '?')} x{n}" for c, n in sorted(seen.items()))
        or "NONE"))
    print(f"bytes written: {w.sent}")
    if w.blocked_at is not None:
        print(f"*** output stopped being accepted at {w.blocked_at:.3f}s ***")
    else:
        print("the device accepted every byte we wrote, for the whole run")
    if last_in is not None:
        print(f"last inbound message at {last_in:.3f}s "
              f"(run ended at {secs:.1f}s)")


if __name__ == "__main__":
    main()
