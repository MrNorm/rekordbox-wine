#!/usr/bin/env python3
"""timerscope — every live JUCE timer in rekordbox: its period, and WHOSE it is.

WHY THIS EXISTS. THEMES/T10 phase 11 measured the audio fault's trigger to a
precision that leaves no room for argument: from each teardown to the next
disruption is 14.99, 14.97, 15.01, 14.99 s. That is a 15.000-second timer, not
drift and not accumulation.

Finding it statically was unreliable. A search for the literal 15000 immediate
next to a startTimer call found exactly one site -- `browse::BrowseBasicView`
timer id 4 -- and neutering that callback in the live process (writing 0xC3 over
its first byte) changed nothing at all: the fault continued at the identical
rate. The reason is that timers are also armed through a wrapper,
`FUN_14100f010(owner, id, ms, lambda, flag)`, which passes the period as an
ordinary argument, so the literal can sit far from the call.

So enumerate them at runtime instead. `FUN_142a0e1b0(timer, ms)` stores the
period at `timer+0x10`, and `FUN_142a0add0` builds the 0x28-byte entry with the
owner at `+0x18` and the timer id at `+0x20`. Every entry begins with the same
vtable pointer, so scanning writable memory for it finds all of them.

For each timer this prints the period, the id, and the owner's C++ class name,
decoded from the owner's own RTTI Complete Object Locator in the image. That
turns "something fires every 15 s" into a list of named suspects, each of which
can then be neutered individually and scored with bin/queuescope.py.

Usage: bin/timerscope.py <pid> [--period MS]
"""
import sys, struct, re, subprocess

TIMER_VTABLE = 0x145531008   # rekordbox 7.2.18: the juce timer entry's vtable
OFF_PERIOD   = 0x10
OFF_OWNER    = 0x18
OFF_ID       = 0x20
EXE = ("prefixes/rb7/drive_c/Program Files/rekordbox/"
       "rekordbox 7.2.18/rekordbox.exe")
BASE = 0x140000000

class Img:
    """The on-disk image, for turning a vtable pointer into a class name."""
    def __init__(self, path):
        self.data = open(path, "rb").read()
        out = subprocess.run(["objdump", "-h", path], capture_output=True, text=True).stdout
        self.secs = []
        for m in re.finditer(r'^\s*\d+\s+(\S+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+[0-9a-f]+\s+([0-9a-f]+)',
                             out, re.M):
            self.secs.append((m.group(1), int(m.group(2), 16),
                              int(m.group(3), 16), int(m.group(4), 16)))
    def off(self, va):
        for _, sz, vma, fo in self.secs:
            if fo and vma <= va < vma + sz:
                return fo + (va - vma)
        return None
    def classname(self, vtable):
        """MSVC RTTI: the Complete Object Locator sits one slot before the vtable."""
        o = self.off(vtable)
        if o is None or o < 8:
            return None
        col = struct.unpack_from("<Q", self.data, o - 8)[0]
        co = self.off(col)
        if co is None:
            return None
        try:
            sig, offs, cd, ptd, pcd, pself = struct.unpack_from("<IIIIII", self.data, co)
        except struct.error:
            return None
        if sig != 1 or BASE + pself != col:
            return None
        to = self.off(BASE + ptd)
        if to is None:
            return None
        raw = self.data[to + 16:to + 220].split(b"\x00")[0]
        return raw.decode("latin1", "replace")

def regions(pid):
    out = []
    for line in open(f"/proc/{pid}/maps"):
        p = line.split()
        rng, perms = p[0], p[1]
        path = p[5] if len(p) > 5 else ""
        if "w" not in perms or "s" in perms:
            continue
        if path and not path.startswith("["):
            continue
        a, b = (int(x, 16) for x in rng.split("-"))
        if b - a > (1 << 30):
            continue
        out.append((a, b))
    return out

def main():
    import numpy as np
    pid = int(sys.argv[1])
    want = None
    if "--period" in sys.argv:
        want = int(sys.argv[sys.argv.index("--period") + 1])

    mem = open(f"/proc/{pid}/mem", "rb", 0)
    def rd(a, n):
        try:
            mem.seek(a); return mem.read(n)
        except (OSError, ValueError, OverflowError):
            return None
    def u64(a):
        b = rd(a, 8); return struct.unpack("<Q", b)[0] if b and len(b) == 8 else None
    def u32(a):
        b = rd(a, 4); return struct.unpack("<I", b)[0] if b and len(b) == 4 else None

    img = Img(EXE)
    needle = np.uint64(TIMER_VTABLE)
    found = []
    for a, b in regions(pid):
        blob = rd(a, b - a)
        if not blob or len(blob) < 8:
            continue
        n = (len(blob) // 8) * 8
        arr = np.frombuffer(blob[:n], dtype=np.uint64)
        for idx in np.nonzero(arr == needle)[0]:
            found.append(a + int(idx) * 8)

    rows = []
    for t in found:
        period = u32(t + OFF_PERIOD)
        owner  = u64(t + OFF_OWNER)
        tid    = u32(t + OFF_ID)
        if period is None or owner is None or tid is None:
            continue
        if period == 0 or period > 3600000 or tid > 4096:
            continue
        ovt = u64(owner) if owner else None
        cls = img.classname(ovt) if ovt else None
        rows.append((period, tid, t, owner, ovt, cls))

    rows.sort(key=lambda r: -r[0])
    shown = [r for r in rows if want is None or r[0] == want]
    print(f"== timerscope: pid {pid}, {len(found)} timer entr(ies), "
          f"{len(rows)} plausible, showing {len(shown)}"
          + (f" with period == {want} ms" if want else ""))
    print(f"\n{'period ms':>9}  {'id':>4}  {'entry':>12}  {'owner':>12}  class")
    print("  " + "-" * 86)
    for period, tid, t, owner, ovt, cls in shown:
        name = cls if cls else (f"(vtable 0x{ovt:x})" if ovt else "(no vtable)")
        print(f"{period:>9}  {tid:>4}  0x{t:010x}  0x{owner:010x}  {name}")
    if want is not None and not shown:
        print("   none -- the period may be set from a variable, or the timer is not running")

if __name__ == "__main__":
    main()
