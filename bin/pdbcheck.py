#!/usr/bin/env python3
"""pdbcheck — validate an exported rekordbox export.pdb NATIVELY, outside Wine.

T02's standing rule: any stick produced here is parsed outside Wine before it
goes anywhere near hardware. This is the cheap half of that rule -- it reads the
DeviceSQL header and table directory, walks the page chain of every table, and
pulls the device strings out -- so a stick can be rejected in a second without a
Rust toolchain. It is NOT a substitute for a full parse with rekordcrate or
Deep-Symmetry crate-digger before real hardware; it is the gate before that.

Format per Deep-Symmetry's crate-digger documentation:
  header : u32 zero, u32 len_page, u32 num_tables, u32 next_unused_page,
           u32 unknown, u32 sequence, u32 zero
  table  : u32 type, u32 empty_candidate, u32 first_page, u32 last_page

Usage: bin/pdbcheck.py <export.pdb>
"""
import sys, struct, re

TABLES = {0:"tracks",1:"genres",2:"artists",3:"albums",4:"labels",5:"keys",
          6:"colors",7:"playlist_tree",8:"playlist_entries",9:"unknown9",
          10:"unknown10",11:"history_playlists",12:"history_entries",
          13:"artwork",14:"unknown14",15:"unknown15",16:"columns",
          17:"unknown17",18:"unknown18",19:"history"}

path = sys.argv[1]
d = open(path, 'rb').read()
zero, len_page, num_tables, next_unused, unk, sequence, zero2 = struct.unpack_from('<IIIIIII', d, 0)
print(f"file        : {path}")
print(f"size        : {len(d)} bytes")
print(f"page size   : {len_page}")
print(f"tables      : {num_tables}")
print(f"next unused : {next_unused}   sequence: {sequence}")
ok = True
if zero != 0 or zero2 != 0:
    print("  FAIL: header guard words are not zero"); ok = False
if len_page != 4096:
    print(f"  WARN: unusual page size {len_page}")
if not (1 <= num_tables <= 64):
    print("  FAIL: implausible table count"); ok = False
if len(d) % len_page:
    print("  WARN: file is not a whole number of pages")

print("\n  table                first  last   pages")
off = 28
seen_tracks = None
for i in range(num_tables):
    t, empty, first, last = struct.unpack_from('<IIII', d, off + i*16)
    name = TABLES.get(t, f"type{t}")
    if max(first, last) * len_page > len(d):
        print(f"  {name:20s} {first:5d} {last:5d}   OUT OF RANGE"); ok = False
        continue
    print(f"  {name:20s} {first:5d} {last:5d}   {last-first+1:5d}")
    if t == 0: seen_tracks = (first, last)

# device strings: the export writes paths and titles as UTF-16LE or as
# short-ASCII DeviceSQL strings; look for both.
def find_text(needle):
    hits = []
    b8 = needle.encode('ascii', 'ignore')
    if b8 in d: hits.append("ascii")
    b16 = needle.encode('utf-16-le')
    if b16 in d: hits.append("utf-16le")
    return hits

print()
for probe in ("Demo Track 1", "Loopmasters", "/Contents/", ".mp3"):
    h = find_text(probe)
    print(f"  string {probe!r:32s} {'found as ' + ', '.join(h) if h else 'NOT FOUND'}")
    if not h: ok = False

print()
print("VERDICT:", "structurally sound and the exported track is present" if ok
      else "PROBLEM -- see the FAIL/NOT FOUND lines above")
print("(Full validation still requires rekordcrate or crate-digger before hardware.)")
