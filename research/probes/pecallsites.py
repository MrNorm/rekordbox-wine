#!/usr/bin/env python3
"""pecallsites — every `call *IAT(%rip)` in .text that targets a given import.

The question "which function walks the drive letters" is answered by finding
every call to GetDriveTypeW and GetLogicalDriveStringsW and asking what function
each one is in. objdump over a 100 MB PE takes minutes; this scans the raw bytes
and is instant.

Usage: research/probes/pecallsites.py <exe> <hex IAT VA> [<hex IAT VA> ...]
       (get the VAs from research/probes/peimports.py)
"""
import sys, struct, subprocess, re

exe = sys.argv[1]
targets = {int(a, 16) for a in sys.argv[2:]}
d = open(exe, 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
optoff = pe + 24
nsec = struct.unpack_from('<H', d, pe+6)[0]
so = optoff + struct.unpack_from('<H', d, pe+20)[0]
sec = {}
for i in range(nsec):
    o = so + i*40
    nm = d[o:o+8].rstrip(b'\0').decode('latin1')
    vs, va, rs, ra = struct.unpack_from('<IIII', d, o+8)
    sec[nm] = (va, vs, ra, rs)
BASE = 0x140000000
tva, tvs, tra, trs = sec['.text']
text = d[tra:tra+trs]

hits = []
i = 0
while True:
    i = text.find(b'\xff\x15', i)
    if i < 0: break
    rel = struct.unpack_from('<i', text, i+2)[0]
    tgt = BASE + tva + i + 6 + rel
    if tgt in targets:
        hits.append((BASE + tva + i, tgt))
    i += 1
# also the jmp form used by thunks
i = 0
while True:
    i = text.find(b'\xff\x25', i)
    if i < 0: break
    rel = struct.unpack_from('<i', text, i+2)[0]
    tgt = BASE + tva + i + 6 + rel
    if tgt in targets:
        hits.append((BASE + tva + i, tgt))
    i += 1

# function bounds from .pdata
pva, pvs, pra, prs = sec['.pdata']
n = prs // 12
def func_of(va):
    rva = va - BASE
    lo, hi = 0, n-1
    while lo <= hi:
        mid = (lo+hi)//2
        b, e, u = struct.unpack_from('<III', d, pra + mid*12)
        if rva < b: hi = mid-1
        elif rva >= e: lo = mid+1
        else: return BASE+b, BASE+e
    return None, None

print(f"{len(hits)} call site(s)")
for site, tgt in sorted(hits):
    fb, fe = func_of(site)
    fn = f"0x{fb:x}..0x{fe:x} ({fe-fb} bytes)" if fb else "no .pdata entry"
    print(f"  call at 0x{site:x} -> IAT 0x{tgt:x}   in function {fn}")
