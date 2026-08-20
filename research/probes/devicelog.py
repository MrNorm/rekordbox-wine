#!/usr/bin/env python3
"""devicelog — receive rekordbox's own device log.

rekordbox has an internal device-logging channel that is off by default. With
DeviceLogEnable=1 in rekordbox3.settings it opens a TCP connection to
127.0.0.1:10001 and streams its controller-layer log to whatever is listening
(the transport is at rekordbox.exe 0x1422b7e40: 'DeviceLogEnable',
'DeviceLog.conf', '127.0.0.1', port 0x2711 = 10001).

This matters because that log answers, in rekordbox's own words, the question we
have been inferring at from the outside:

    ### HID:Other:[%s] open wait for start midi.
    ### MIDI:%s.midi.csv is not found.
    MIDI input is not found
    @@@ Auth is Enabled : startMidiDevice
    @@@ MIDI Disconnect by AuthReq

The last two are the discriminator for whether device authentication is even
being attempted for this controller -- which is the difference between a Wine
transport bug and a scope wall.

Usage: research/probes/devicelog.py [outfile]      (Ctrl-C to stop)
"""
import socket
import sys
import threading
import datetime

OUT = sys.argv[1] if len(sys.argv) > 1 else "devicelog.txt"


def serve(conn, addr, out):
    with conn:
        while True:
            try:
                data = conn.recv(4096)
            except OSError:
                return
            if not data:
                return
            text = data.decode("utf-8", errors="replace")
            out.write(text)
            out.flush()
            sys.stdout.write(text)
            sys.stdout.flush()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 10001))
    srv.listen(8)
    stamp = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    with open(OUT, "a", buffering=1) as out:
        out.write(f"\n===== devicelog listening {stamp} =====\n")
        print(f"listening on 127.0.0.1:10001 -> {OUT}", flush=True)
        while True:
            try:
                conn, addr = srv.accept()
            except KeyboardInterrupt:
                return
            threading.Thread(target=serve, args=(conn, addr, out), daemon=True).start()


if __name__ == "__main__":
    main()
