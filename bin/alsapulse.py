#!/usr/bin/env python3
"""alsapulse — is the DDJ's ALSA stream itself hiccuping, or only rekordbox's queue?

WHY THIS EXISTS. THEMES/T10 phase 11: every 15.85 s the DDJ's output queue
inside rekordbox jumps by ~2 buffers (~46 ms of audio) and the watchdog tears
both streams down. Something blocks the hand-off for tens of milliseconds. This
says WHICH LAYER:

  * if the ALSA substream underruns or leaves RUNNING at that instant, the
    disruption is in the audio path (Wine, the driver, the device);
  * if ALSA sails through it perfectly while rekordbox's queue jumps, the audio
    path is innocent and something above it stalled the application thread.

Those are different bugs with different owners, and one 60-second run separates
them.

It samples /proc/asound/cardN/pcmXp/sub0/status, which is free to read and
requires no permissions, and stamps every sample with the same wall clock that
`bin/queuescope.py --trace` writes in its header.

Add --trace <file.tsv> to log EVERY sample rather than only state changes. The
event-only mode answers "did the stream break"; the trace answers "is the amount
of audio queued ahead of the hardware dipping periodically", which is how a
hand-off stall shows up when the application-side queues cannot be read -- with
PC MASTER OUT off rekordbox does not create the queue objects at all.

Usage: bin/alsapulse.py <card> [seconds] [pcm] [--trace f.tsv]
"""
import sys, time, os

def read_status(path):
    try:
        with open(path) as f:
            txt = f.read()
    except OSError:
        return None
    d = {}
    for line in txt.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            d[k.strip()] = v.strip()
    return d

def main():
    argv = sys.argv[1:]
    trace = None
    if "--trace" in argv:
        i = argv.index("--trace")
        trace = open(argv[i + 1], "w")
        argv = argv[:i] + argv[i + 2:]
    card = argv[0]
    secs = float(argv[1]) if len(argv) > 1 else 60.0
    pcm  = argv[2] if len(argv) > 2 else "0"
    path = f"/proc/asound/card{card}/pcm{pcm}p/sub0/status"
    if not os.path.exists(path):
        print(f"alsapulse: no such substream: {path}")
        sys.exit(1)

    t0 = time.time()
    if trace:
        trace.write(f"# t0_epoch={t0:.4f}\n")
        trace.write("t\tstate\thw_ptr\tappl_ptr\tavail\tdelay\n")
    print(f"# t0_epoch={t0:.4f}  path={path}")
    print("t_rel\tepoch\tstate\thw_ptr\tappl_ptr\tavail\tnote")

    prev_state = None
    prev_hw = None
    prev_t = None
    stalls = 0
    nonrunning = 0
    n = 0
    while time.time() - t0 < secs:
        d = read_status(path)
        now = time.time()
        if not d:
            time.sleep(0.02); continue
        state = d.get("state", "closed")
        try:
            hw = int(d.get("hw_ptr", -1)); ap = int(d.get("appl_ptr", -1))
        except ValueError:
            hw = ap = -1
        avail = d.get("avail", "-")
        if trace:
            trace.write(f"{now-t0:.4f}\t{state}\t{hw}\t{ap}\t{avail}\t{d.get('delay','-')}\n")
        note = ""
        if state != prev_state:
            note += f"STATE {prev_state}->{state} "
            if prev_state is not None and state != "RUNNING":
                nonrunning += 1
        # a stall: the hardware pointer did not move across >=40 ms of wall clock
        if prev_hw is not None and prev_t is not None:
            dt = now - prev_t
            if dt >= 0.040 and hw == prev_hw and state == "RUNNING":
                stalls += 1
                note += f"HW_PTR FROZEN for {dt*1000:.0f} ms "
        if note:
            print(f"{now-t0:7.2f}\t{now:.3f}\t{state}\t{hw}\t{ap}\t{avail}\t{note}", flush=True)
        prev_state, prev_hw, prev_t = state, hw, now
        n += 1
        time.sleep(0.02)
    if trace:
        trace.close()
    print(f"# {n} samples, {stalls} hw_ptr stall(s), {nonrunning} departure(s) from RUNNING")

if __name__ == "__main__":
    main()
