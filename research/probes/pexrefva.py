#!/usr/bin/env python3
"""pexrefva — every RIP-relative reference from .text into a VA range.

Used to go from "this global holds the WasapiPolling setting" to "here is every
place the code reads it". The value may live at an offset inside the object, so
a range is scanned rather than a single address.

Usage: research/probes/pexrefva.py <exe> <hex VA> [span=0x40]
"""
import sys, re, subprocess, numpy as np

exe  = sys.argv[1]
base = int(sys.argv[2], 16)
span = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x40

out = subprocess.run(['objdump','-h',exe], capture_output=True, text=True).stdout
secs=[]
for m in re.finditer(r'^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)', out, re.M):
    secs.append((m.group(1), int(m.group(2),16), int(m.group(3),16), int(m.group(4),16)))
data = open(exe,'rb').read()
tname, tsize, tvma, toff = next(s for s in secs if s[0]=='.text')
buf = np.frombuffer(data[toff:toff+tsize], dtype=np.uint8)

hits = {}
for shift in range(4):
    arr = buf[shift:]
    n = (len(arr)//4)*4
    d = np.frombuffer(arr[:n].tobytes(), dtype=np.int32)
    idx = np.arange(len(d), dtype=np.int64)*4 + shift
    tgt = tvma + idx + 4 + d.astype(np.int64)
    sel = np.nonzero((tgt >= base) & (tgt < base+span))[0]
    for k in sel:
        hits[int(idx[k])] = int(tgt[k])

print(f"references into 0x{base:x}..0x{base+span:x}: {len(hits)}")
for off in sorted(hits):
    va = tvma + off
    ctx = data[toff+off-3: toff+off+4]
    print(f"  insn ~0x{va-3:x}  -> 0x{hits[off]:x}  (+0x{hits[off]-base:x})  bytes {ctx.hex()}")
