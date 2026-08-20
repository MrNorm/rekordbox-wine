#!/usr/bin/env python3
"""peimports — name every IAT slot of a PE, by VA.

objdump -x prints hint numbers rather than names for this binary, so every
`call *0x143374568(%rip)` in a disassembly is anonymous. This parses the import
directory directly and prints  VA  dll  symbol  for each thunk, which turns the
engine disassembly into readable code.

Usage: bin/peimports.py <exe> [hexVA ...]     no VA = dump all
"""
import sys, struct

path = sys.argv[1]
want = {int(a, 16) for a in sys.argv[2:]}
d = open(path, 'rb').read()
pe = struct.unpack_from('<I', d, 0x3c)[0]
assert d[pe:pe+4] == b'PE\0\0'
nsec = struct.unpack_from('<H', d, pe+6)[0]
optoff = pe + 24
magic = struct.unpack_from('<H', d, optoff)[0]
assert magic == 0x20b, "not PE32+"
base = struct.unpack_from('<Q', d, optoff+24)[0]
nrva = struct.unpack_from('<I', d, optoff+108)[0]
imp_rva, imp_size = struct.unpack_from('<II', d, optoff+112)
secs = []
so = optoff + struct.unpack_from('<H', d, pe+20)[0]
for i in range(nsec):
    o = so + i*40
    name = d[o:o+8].rstrip(b'\0').decode('latin1')
    vsize, vaddr, rsize, raddr = struct.unpack_from('<IIII', d, o+8)
    secs.append((name, vaddr, vsize, raddr, rsize))

def off(rva):
    for name, va, vs, ra, rs in secs:
        if va <= rva < va + max(vs, rs):
            return ra + (rva - va)
    return None

def cstr(rva):
    o = off(rva)
    e = d.index(b'\0', o)
    return d[o:e].decode('latin1')

out = []
p = off(imp_rva)
while True:
    oft, tds, fwd, name_rva, first = struct.unpack_from('<IIIII', d, p)
    if oft == 0 and name_rva == 0 and first == 0:
        break
    dll = cstr(name_rva)
    lut = oft or first
    lo, fo = off(lut), first
    i = 0
    while True:
        e = struct.unpack_from('<Q', d, lo + i*8)[0]
        if e == 0:
            break
        if e & (1 << 63):
            sym = f"#{e & 0xffff}"
        else:
            sym = cstr((e & 0x7fffffff) + 2)
        out.append((base + first + i*8, dll, sym))
        i += 1
    p += 20

if want:
    m = {va: (dll, sym) for va, dll, sym in out}
    for va in sorted(want):
        dll, sym = m.get(va, ('?', '?'))
        print(f"0x{va:x}  {dll}  {sym}")
else:
    for va, dll, sym in out:
        print(f"0x{va:x}  {dll}  {sym}")
