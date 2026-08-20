# mmdevapi: widening an exclusive-mode buffer is visible to the application

**Status: evidence note, 2026-08-19. Written against wine-11.15 and this
project's `0002-mmdevapi-exclusive-event-streams.patch`. Relevant to anyone
touching `adjust_timing()` in `dlls/mmdevapi/client.c`.**

## The claim being corrected

`0002` makes event-driven exclusive-mode streams usable, and to do so it widens
the client's buffer:

    if (*duration != *period)
        return AUDCLNT_E_BUFDURATION_PERIOD_NOT_EQUAL;   /* the Windows rule */
    ...
    if (*duration < 4 * *period)
        *duration = 4 * *period;

with the justification, in the patch's own comment:

> *GetBufferSize reports the real size, so a client that sizes itself from that
> stays correct.*

**A client that sizes itself from `GetBufferSize()` does not stay correct — it
changes its callback rate by the same factor.** That is not a hypothetical:
rekordbox 7.2.18 does exactly this, and the consequence is a complete failure of
its two-output mode.

## The measurement

rekordbox opens two render streams: a DDJ-400 in exclusive mode and the PC
speakers shared. It asks for `duration == period == 256 frames` on the exclusive
one — it has to, or the check above would reject it. With the widening in place
`GetBufferSize()` returns 1024, and rekordbox uses that as its per-device audio
block:

    shared PC endpoint    172 callbacks/s   = 44100/256   (what it asked for)
    exclusive DDJ-400      43 callbacks/s   = 44100/1024  (four times too slow)

Confirmed by sweeping the client's own buffer setting: at 1024 frames the two
rates become 43 and 10.8 = 44100/4096, i.e. the exclusive block tracks
`GetBufferSize()` exactly. Confirmed again by an `RBW_EXCL_PERIODS` knob added
to `adjust_timing()`: setting it to 1 halves the ratio to 2:1 immediately.

Downstream, inside the application: its engine will not emit any audio until
every output device has completed three seconds' worth of callbacks (14 s
instead of 3.5 at the reduced rate), and it keeps every device's queue within
three buffers of the shallowest, tearing both streams down after 100
corrections. At a 4:1 callback ratio it reaches that threshold in under a second
and rebuilds its entire audio subsystem every 15.9 s. Playback runs at **0.05x
of real time**.

## What this means for the patch

The widening is still needed *somewhere* — with `duration == period` the
mmdevapi buffer is one period long and `get_render_buffer` refuses a full-period
request whenever any frames are still held, which is the starvation `0002` was
written to fix (reproduced here: ALSA XRUNs and 0.12x).

But it should not be **the client's** buffer that grows. The slack belongs below
mmdevapi, in the driver's own ring — `winealsa` already runs
`alsa_bufsize_frames = mmdev_period_frames * 4` (`alsa.c:920`), which is exactly
the right amount in exactly the right place. The correct shape is:

* honour `duration == period` in what `GetBufferSize()` reports, as Windows does;
* let `get_render_buffer` accept a new period as soon as the previous one has
  been handed to the backend, rather than requiring the client's buffer to drain.

Until that is done, the knob makes the trade-off explicit and measurable:

    RBW_EXCL_PERIODS   default 4   exclusive+event buffer, in periods
    RBW_SHARED_PERIODS default 3   shared buffer, in periods

Both defaults reproduce the shipping behaviour byte for byte.

## A second, independent gap found alongside it

`AvSetMmThreadCharacteristics` is a stub, so **no** thread of a Wine audio
application ever gets real-time scheduling. Measured on rekordbox: 185 threads
`SCHED_OTHER`, 9 `SCHED_BATCH`, **zero** `SCHED_FIFO`/`SCHED_RR`, while on
Windows its render threads run under MMCSS "Pro Audio". The resulting jitter is
what still costs one stream rebuild every three minutes at a 256-frame buffer,
and it is presumably what costs every Wine audio application its low-latency
headroom. RTKit (`org.freedesktop.RealtimeKit1`) is present on any desktop
running PipeWire and is the obvious mechanism.
