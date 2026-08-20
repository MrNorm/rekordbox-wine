#!/usr/bin/env python3
"""pexref — find what references a string inside a large PE, without a disassembler.

WHY. rekordbox.exe is 100 MB with no symbols, and Ghidra's analysis pass takes
hours. But the anchors we care about are its own setting names — WasapiPolling,
WasapiTimeoutCount, MasterOutMode — and finding the code that reads them does not
need a full analysis: an x86-64 reference to a string is either

  * RIP-relative:  lea reg,[rip+disp32]   -> target = addr_of_next_insn + disp32
  * or an absolute 8-byte pointer sitting in a table in .rdata/.data

so both are findable with an arithmetic sweep. numpy makes a 54 MB .text a
fraction of a second per pattern instead of minutes.

Usage: bin/pexref.py <exe> <string> [more strings...]
"""
import sys, numpy as np, subprocess, re

def sections(exe):
    out = subprocess.run(['objdump', '-h', exe], capture_output=True, text=True).stdout
    secs = []
    for m in re.finditer(r'^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)',
                         out, re.M):
        name, size, vma, off = m.group(1), int(m.group(2), 16), int(m.group(3), 16), int(m.group(4), 16)
        secs.append((name, vma, off, size))
    return secs

def main():
    exe = sys.argv[1]
    needles = sys.argv[2:]
    data = open(exe, 'rb').read()
    secs = sections(exe)
    def off2va(off):
        for n, vma, o, sz in secs:
            if o <= off < o + sz: return vma + (off - o)
        return None
    def va2off(va):
        for n, vma, o, sz in secs:
            if vma <= va < vma + sz: return o + (va - vma)
        return None
    def secof(va):
        for n, vma, o, sz in secs:
            if vma <= va < vma + sz: return n
        return '?'

    text = next(s for s in secs if s[0] == '.text')
    tname, tvma, toff, tsize = text
    buf = np.frombuffer(data[toff:toff + tsize], dtype=np.uint8)

    for needle in needles:
        nb = needle.encode()
        print(f"\n=== {needle}")
        starts = []
        i = data.find(nb)
        while i >= 0 and len(starts) < 8:
            # a string literal starts after a NUL (or at a section start)
            if i == 0 or data[i-1] == 0:
                starts.append(i)
            i = data.find(nb, i + 1)
        for off in starts:
            va = off2va(off)
            if va is None: continue
            print(f"  string at file 0x{off:x} -> VA 0x{va:x} ({secof(va)})")

            # 1. RIP-relative references from .text
            hits = []
            for shift in range(4):
                arr = buf[shift:]
                n = (len(arr) // 4) * 4
                d = arr[:n].view(np.int32) if shift == 0 else np.frombuffer(arr[:n].tobytes(), dtype=np.int32)
                idx = np.arange(len(d), dtype=np.int64) * 4 + shift
                tgt = tvma + idx + 4 + d.astype(np.int64)
                m = np.nonzero(tgt == va)[0]
                for k in m[:20]:
                    hits.append(int(idx[k]))
            for h in sorted(hits)[:10]:
                ins = data[toff + h - 3: toff + h + 4]
                print(f"    RIP-ref from .text VA 0x{tvma + h - 3:x}   bytes {ins.hex()}")

            # 2. absolute 64-bit pointers anywhere (tables)
            pat = va.to_bytes(8, 'little')
            j = data.find(pat); ptrs = 0
            while j >= 0 and ptrs < 6:
                pva = off2va(j)
                if pva is not None:
                    print(f"    pointer at VA 0x{pva:x} ({secof(pva)})")
                    ptrs += 1
                j = data.find(pat, j + 1)
            if not hits and not ptrs:
                print("    no direct reference found (may be built at run time)")

main()
