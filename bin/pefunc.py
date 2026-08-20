#!/usr/bin/env python3
"""pefunc — exact function bounds from a PE's .pdata, without any analysis pass.

x86-64 PE files carry a RUNTIME_FUNCTION table (.pdata): 12 bytes per function,
begin/end/unwind as RVAs. That is the authoritative function boundary list, and
it is available instantly on a 100 MB binary that Ghidra takes hours to analyse.

Usage: bin/pefunc.py <exe> <hex VA>        which function contains this address
       bin/pefunc.py <exe> --list <hex VA> <hex VA2>   bounds for several
"""
import sys, re, subprocess, struct

exe = sys.argv[1]
args = [a for a in sys.argv[2:] if not a.startswith('--')]
out = subprocess.run(['objdump','-h',exe], capture_output=True, text=True).stdout
secs = []
for m in re.finditer(r'^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)', out, re.M):
    secs.append((m.group(1), int(m.group(2),16), int(m.group(3),16), int(m.group(4),16)))
data = open(exe,'rb').read()
base = 0x140000000
pd = next(s for s in secs if s[0]=='.pdata')
_, psize, pvma, poff = pd
n = psize // 12
for a in args:
    va = int(a, 16)
    rva = va - base
    lo, hi = 0, n-1
    found = None
    while lo <= hi:
        mid = (lo+hi)//2
        b,e,u = struct.unpack_from('<III', data, poff + mid*12)
        if rva < b: hi = mid-1
        elif rva >= e: lo = mid+1
        else: found = (b,e,u); break
    if found:
        b,e,u = found
        print(f"0x{va:x} is in function 0x{base+b:x} .. 0x{base+e:x}  ({e-b} bytes)")
    else:
        print(f"0x{va:x}: no .pdata entry (leaf or data)")
