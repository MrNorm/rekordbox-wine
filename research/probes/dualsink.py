#!/usr/bin/env python3
"""dualsink — is the PC stream carrying music while the DDJ stream carries silence?

WHY THIS EXISTS. Phase 23 measured rekordbox writing digital silence into BOTH
WASAPI clients for ~14 s of every 16 s cycle. But an earlier 60 s recording of
the laptop sink monitor was continuous, clean music. Both cannot be true of the
same moment, and the contradiction has been sitting in T03 unresolved
("Open inconsistency to resolve next").

The only honest way to settle it is to sample both endpoints ON ONE CLOCK, in
one process, in one run -- which is exactly how meterscope.py settled the
master-level flash. Two tools, two clocks and a cross-correlation afterwards is
how you get a 1 s alignment error and an argument.

WHAT IT MEASURES, every 250 ms:
  * the DDJ's exclusive substream   -- state, appl_ptr, hw_ptr from /proc/asound
    (this is Wine's own writing into the hardware ring)
  * the PC master out               -- RMS of the laptop sink's MONITOR, i.e.
    the audio PipeWire is actually being handed
  * whether the Wine PipeWire client is still connected (sink-input id), so a
    stream that is torn down is distinguishable from one that goes quiet

The recording is one continuous parec capture, bucketed afterwards, so the PC
side has a uniform sample rate that does not depend on the polling loop.

LIVENESS CONTROLS, because a silent system and a broken probe look identical:
  * refuses to run if the DDJ substream is closed at the start
  * reports the peak RMS seen, so "all zero" can be told from "recorded nothing"
  * reports the number of PCM state transitions, so a run where the fault did
    not reproduce is reported as such rather than averaged into the numbers

Usage: research/probes/dualsink.py [seconds]        (default 60)
"""
import os, re, subprocess, sys, time, wave, array, math, json

SECS = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
OUT = "runs/DUALSINK"
os.makedirs(OUT, exist_ok=True)
STAMP = time.strftime("%Y%m%dT%H%M%S")
RAW = f"{OUT}/{STAMP}.raw"
LOG = f"{OUT}/{STAMP}.log"

DDJ_STATUS = None
for c in range(0, 8):
    u = f"/proc/asound/card{c}/usbid"
    if os.path.exists(u) and open(u).read().strip() == "2b73:0026":
        DDJ_STATUS = f"/proc/asound/card{c}/pcm0p/sub0/status"
if DDJ_STATUS is None:
    sys.exit("FAULT: DDJ-400 not present in /proc/asound")


def pcm():
    """state, appl_ptr, hw_ptr of the DDJ playback substream."""
    try:
        txt = open(DDJ_STATUS).read()
    except OSError:
        return ("closed", 0, 0)
    if "state:" not in txt:
        return ("closed", 0, 0)
    st = re.search(r"state:\s*(\S+)", txt)
    ap = re.search(r"appl_ptr\s*:\s*(\d+)", txt)
    hp = re.search(r"hw_ptr\s*:\s*(\d+)", txt)
    return (st.group(1) if st else "?",
            int(ap.group(1)) if ap else 0,
            int(hp.group(1)) if hp else 0)


def sink_inputs():
    """ids of PipeWire/pulse playback clients, to see if the PC stream is torn down."""
    try:
        out = subprocess.run(["pactl", "list", "short", "sink-inputs"],
                             capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return []
    return [l.split("\t")[0] for l in out.splitlines() if l.strip()]


def default_monitor():
    s = subprocess.run(["pactl", "get-default-sink"], capture_output=True,
                       text=True, timeout=5).stdout.strip()
    return s + ".monitor" if s else None


MON = default_monitor()
if not MON:
    sys.exit("FAULT: no default sink — the desktop has no audio device "
             "(see docs/investigation/THEMES/T09; try: systemctl --user restart wireplumber)")

st0, _, _ = pcm()
if st0 == "closed":
    print(f"VOID: the DDJ substream is closed — rekordbox is not streaming to it.")
    print(f"      Load a track and press play first; a run against a closed")
    print(f"      device measures nothing and looks exactly like silence.")
    sys.exit(2)

log = open(LOG, "w")


def say(*a):
    s = " ".join(str(x) for x in a)
    print(s)
    log.write(s + "\n")
    log.flush()


say(f"== dualsink {STAMP}  ({SECS:.0f}s) ==")
say(f"   DDJ substream : {DDJ_STATUS}  (state {st0})")
say(f"   PC monitor    : {MON}")

RATE, CH, WIDTH = 44100, 2, 2
rec = subprocess.Popen(
    ["parec", f"--device={MON}", "--format=s16le", f"--rate={RATE}",
     f"--channels={CH}", "--raw", "--latency-msec=50"],
    stdout=open(RAW, "wb"), stderr=subprocess.DEVNULL)
t0 = time.monotonic()          # parec is live from about here; +-0.2 s

samples = []
pa, ph = None, None
while time.monotonic() - t0 < SECS:
    t = time.monotonic() - t0
    st, ap, hp = pcm()
    d_ap = (ap - pa) if (pa is not None and ap >= pa) else 0
    pa, ph = ap, hp
    samples.append((t, st, d_ap, len(sink_inputs())))
    time.sleep(0.25)

rec.terminate()
try:
    rec.wait(timeout=5)
except Exception:
    rec.kill()

# ---- bucket the recording into 250 ms RMS values --------------------------
data = open(RAW, "rb").read()
frame = WIDTH * CH
n = len(data) // frame
say(f"   recorded      : {n} frames = {n/RATE:.1f} s of monitor audio")
if n < RATE:                    # under a second: the recorder never really ran
    say("   FAULT: the monitor recording is too short to mean anything.")
    say("          Reporting nothing rather than reporting silence.")
    sys.exit(2)

pcm16 = array.array("h")
pcm16.frombytes(data[: n * frame])
BUCKET = int(RATE * 0.25)
rms = []
for i in range(0, n - BUCKET, BUCKET):
    seg = pcm16[i * CH:(i + BUCKET) * CH]
    acc = 0
    for v in seg:
        acc += v * v
    rms.append(math.sqrt(acc / len(seg)))

peak = max(rms) if rms else 0.0
say(f"   peak RMS      : {peak:.0f}   (0 means the monitor carried nothing at all)")

# ---- merge onto one timeline ----------------------------------------------
say("")
say("   t      DDJ state      appl+     PC RMS   clients")
transitions = 0
prev_state = None
audible = 0
ddj_open = 0
for (t, st, d_ap, nsi) in samples:
    i = int(t / 0.25)
    r = rms[i] if i < len(rms) else float("nan")
    if prev_state is not None and st != prev_state:
        transitions += 1
        say(f"  ------------------------------------------- {prev_state} -> {st}")
    prev_state = st
    if not math.isnan(r) and r > 30:
        audible += 1
    if st != "closed":
        ddj_open += 1
    say(f"  {t:6.2f}  {st:<12s} {d_ap:8d}  {r:9.0f}   {nsi}")

say("")
say("== RESULT ==")
say(f"   samples                       : {len(samples)}")
say(f"   DDJ substream open            : {ddj_open}/{len(samples)}")
say(f"   PCM state transitions         : {transitions}"
    + ("   <- the rebuild cycle is present" if transitions >= 2
       else "   <- FAULT DID NOT REPRODUCE in this window; treat as no-data"))
say(f"   buckets with audible PC audio : {audible}/{len(samples)}"
    f"  ({100.0*audible/max(1,len(samples)):.0f}%)")
say("")
if peak == 0:
    say("   The monitor carried NOTHING. Either the PC master out is off, or")
    say("   the recording failed. Not evidence of the application being silent.")
elif audible > 0.9 * len(samples):
    say("   The PC stream is CONTINUOUS music while the DDJ stream cycles.")
    say("   -> the application is rendering; only the exclusive client starves.")
elif audible < 0.2 * len(samples):
    say("   The PC stream is silent too -> the application is silencing")
    say("   everything, and the fault is above the device layer.")
else:
    say("   The PC stream is intermittent. Compare its gaps against the DDJ")
    say("   state column above -- if they coincide, one cause drives both.")
say("")
say(f"   log: {LOG}   raw: {RAW}")
