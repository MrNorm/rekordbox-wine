#!/usr/bin/env python3
"""pecslock — every place the code locks a CRITICAL_SECTION at a given object offset.

The render path skips producing audio when
`TryEnterCriticalSection(&engine + 0x2d8)` fails (T10 phase 34), so the question
"who holds that lock" is a static one: find every
`lea <off>(%reg),%rcx ; call *[Enter|TryEnter|Leave]CriticalSection` in .text.

Scans the raw .text bytes -- objdump over a 100 MB PE takes minutes and Ghidra
takes hours.

Usage: bin/pecslock.py <exe> <hex offset> [window=48]
"""
import sys, struct, subprocess

exe = sys.argv[1]
target_off = int(sys.argv[2], 16)
WIN = int(sys.argv[3]) if len(sys.argv) > 3 else 48

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

CS = {0x1433747c8: 'TryEnter', 0x1433747f0: 'Enter', 0x143374820: 'Leave',
      0x143374830: 'Init', 0x143374a10: 'InitSpin', 0x143374aa8: 'InitEx',
      0x143374918: 'Delete'}

# every `call *disp32(%rip)` whose target is one of those thunks
calls = {}
i = 0
while True:
    i = text.find(b'\xff\x15', i)
    if i < 0: break
    rel = struct.unpack_from('<i', text, i+2)[0]
    tgt = BASE + tva + i + 6 + rel
    if tgt in CS:
        calls[BASE + tva + i] = CS[tgt]
    i += 1

# every `lea disp32(%reg),%rcx`  (REX.W 8d 8x xx xx xx xx) with disp == target_off
leas = []
pat = struct.pack('<i', target_off)
i = 0
while True:
    i = text.find(pat, i)
    if i < 0: break
    # look back for  48 8d <modrm>  where modrm has mod=10 (disp32)
    for back in (2, 3):          # no SIB / with SIB
        j = i - back
        if j < 1: continue
        if text[j-1] in (0x48, 0x49, 0x4c, 0x4d) and text[j] == 0x8d and (text[j+1] >> 6) == 2:
            leas.append(BASE + tva + j - 1)
            break
    i += 1

hits = []
for lea in leas:
    for va, kind in calls.items():
        if 0 <= va - lea <= WIN:
            hits.append((lea, va, kind))
print(f"{len(leas)} `lea +0x{target_off:x}` sites, {len(calls)} CS calls, {len(hits)} pairings")
import collections
byfn = collections.defaultdict(list)
for lea, va, kind in sorted(hits):
    byfn[va].append((lea, kind))
for lea, va, kind in sorted(hits):
    print(f"  lea 0x{lea:x}  ->  {kind:9s} at 0x{va:x}")
