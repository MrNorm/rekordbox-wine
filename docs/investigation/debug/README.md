# Debug-only instrumentation — NOT part of the package

Everything here is for investigation and is deliberately excluded from the
shipping patch series in `upstream/` (see `docs/PACKAGE.md`).

## `mmdevapi-render-probe.c.txt`

The `dlls/mmdevapi/client.c` used to answer "is rekordbox writing silence, or is
Wine losing the data?". It counts, once per second per audio client:
ReleaseBuffer calls, frames, `AUDCLNT_BUFFERFLAGS_SILENT` flags, and whether the
buffer the application just wrote contained any non-zero byte.

A `+mmdevapi` trace cannot answer that question — rekordbox polls the interface
tens of thousands of times a second, so the channel changes the timing of the
thing being measured. Counting does not.

**Two faults were found in this probe before it could be trusted, both of the
"probe that cannot fire" class this project keeps hitting:**

1. The helper that records the buffer pointer was defined *after* its caller, so
   the first build failed; harmless, caught by the compiler.
2. **The stats table had four fixed slots.** rekordbox destroys and recreates its
   audio clients every ~15 s, so the table filled with dead pointers and the
   probe went permanently silent *exactly when the interesting behaviour
   started*. It reported `nonzero=0` for a window in which the USB wire proved
   real audio was flowing. Fixed with LRU recycling over 32 slots.

The lesson, again: before trusting silence, prove the probe can speak.
