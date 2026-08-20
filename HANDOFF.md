# Handoff prompt — 2026-08-17 (late evening)

Paste the block below into a fresh session. Everything else it needs is on disk.

---

You are an expert debugger specialising in Wine and hardware support, working in
`~/projects/rekordbox-wine`. Read `CLAUDE.md` first — it is the
session protocol and the mission, and it overrides your defaults. Then
`STATE.md`, the last three entries of `JOURNAL.md`, and
`THEMES/T03-audio-device.md` from phase 25 onward.

## Where this stands

The controller is **done** (`upstream/0004-winealsa-midi.patch`; a SysEx split
across two USB transfers hangs the DDJ-400, and the fix is rawmidi output). Do
not reopen it without new evidence.

**The audio fault now has a number, a switch and an oracle.** With PC MASTER OUT
off — the daily configuration — the playback engine runs at **1.00x** real time
with zero stream rebuilds. Switch PC MASTER OUT on and it runs at **0.05x** and
the streams are rebuilt every 15.8 s.

    ./bin/loadplay.sh        # get a track playing, and PROVE it is playing
    ./bin/enginerate.sh 40   # 1.00x = fixed, 0.05x = broken, 0.00x = refused

`enginerate` reads the playing track's file offset from `/proc/<pid>/fdinfo` and
compares it with the file's own bitrate. It refuses a paused deck and a track
that ends mid-window rather than reporting a number for them. Score every
candidate fix with it — 40 seconds, no human, no screenshots.

## Settled by measurement this session — do not re-derive

- **The transport is stopped, not the data path.** In the broken arm the track
  file is read **only during the teardown**: 48 KiB (~1.2 s of audio) per cycle.
- **The engine completes a fixed ~9 buffers per second whatever their size**
  (256 → 0.05x, 512 → 0.11x, 1024 → 0.22x, 2048 → 0.40x, exactly proportional).
  Something counts buffers and fills up; only a stream rebuild empties it. A
  bigger buffer is not a workaround.
- **Wine is exonerated for the two-client case.** `upstream/dualclient.c` opens
  an exclusive client on the DDJ and a shared one on the PC endpoint, both
  event-driven. Six arms — including the minimum period, a 44100-forced shared
  client with AUTOCONVERTPCM, and asking for the whole buffer every event — and
  every client wrote **100% of real time**, zero timeouts, zero refusals.
- **Both clients are served identically in both arms** (RBW-CLIENTS per-client
  probe, `debug/mmdevapi-clients-probe.diff.txt`): 44,032 and 44,453 frames per
  second against 44,100. The only difference between working and broken is
  whether those frames contain **signal or zeros**. No buffer change can fix
  that, so the whole buffer-accounting line of work — phase 23's four arms,
  RBW-RING, the deeper ring — is closed.
- **The ~160,000 `AUDCLNT_E_BUFFER_TOO_LARGE` refusals a second are real, are
  Wine's, and are NOT this fault**: they happen in the healthy arm too, where
  playback is perfect. Worth fixing on efficiency grounds (about a core of
  wasted work, and 320,000 `GetCurrentPadding` calls a second), not on this one.
- **The user's track-load delay is the same fault**: 0.9 s with PC MASTER OUT
  off, 2.9-7.9 s with it on (`bin/loadtime.sh`). Not the DDJ being selected —
  the second output stream.
- **Dead ends, recorded so they are not re-chased**: PipeWire is not the trigger
  (repointing PC MASTER OUT at the raw laptop card via
  `pcmasterout_device_v2.txt` still gives 0.04x); `QueryThreadCycleTime` is a
  Wine stub but only Chromium in the tray agent calls it; CPU contention from
  the GL renderer is not it (minimising the window frees ~90% of a core and
  moves the engine 0.03x → 0.05x).

## Where to go next on the audio

The stall is inside rekordbox's two-output path, above WASAPI. What is left to
instrument is what the app is told **outside** the render path:
`IAudioSessionControl::RegisterAudioSessionNotification` is a Wine stub and
rekordbox calls it twice per cycle; `AvSetMmThreadCharacteristics("Pro Audio")`
and `AvSetMmThreadPriority` are stubs. Log every `GetService` IID and every stub
hit in **both** arms and diff them: the call that appears only with two devices
is the lead. A cheaper one first: make winealsa give the shared client the same
period and buffer as the exclusive one and score it with `enginerate`.

## Also open

- **T09, new: one exclusive `hw:` open can delete a device from PipeWire for the
  rest of the session**, because WirePlumber's error handler throws on its own
  error message (`alsa.lua:425`). Reproduced Wine-free in 30 s by
  `bin/pwclash.sh`. This machine had **no audio sinks at all** for the second
  half of the previous session because of it, which voids the runs that
  concluded RBW-RING "broke WASAPI". Report drafted:
  `upstream/wireplumber-alsa-node-error-handler.md`. The launcher now detects
  and repairs it.
- **T08: the GPU leak is real and the renderer is a genuine trade-off.** With a
  track kept playing for ten minutes: GL renderer 58 → 39 fps while GPU memory
  goes 281 → 854 MB; software renderer (`DisableOpenGL=1`) 41.4 → 41.9 fps with
  GPU memory flat at 94 MB. Naming the leaking GL call needs Mesa debug symbols.
- **T02, USB export: untouched and blocked on hardware.** The prefix maps `E:`
  to `/run/media/<user>/REKORDBOX`; no stick is currently attached. **Ask the
  user to plug in the FAT32 stick** — this is the biggest untested feature.

## The instruments

`bin/enginerate.sh` (engine rate), `bin/loadplay.sh` (get a track playing, with
proof), `bin/loadtime.sh` (track-load timing), `bin/playkeep.sh` (keep a deck
playing through a soak), `bin/dualsink.py` (DDJ substream + PC monitor on one
clock), `bin/threaddiff.py` (per-thread CPU/wchan, comparable across arms),
`bin/pwclash.sh` (the PipeWire coexistence reproducer), `bin/snddev.sh` (which
sound devices the prefix opens), `bin/apitally.py` (Wine debug-channel tallies —
and read its warning about perturbation), plus the older `usbwire.sh`,
`meterscope.py`, `threadscope.py`, `authprobe.sh`, `authreplay.py`.

## Instrument faults this project has already paid for

Check for every one of these in anything you build:

- **`spectacle -a` is not a screen capture.** It grabs the active window *plus
  its drop shadow* (2050x1164 for a 1920x1006 window), so coordinates taken from
  one are ~65 px off in X and every click derived from them misses. Use
  `spectacle -f`, which is 1:1. This cost an hour today.
- **A per-thread CPU probe that computes end-minus-start reports 0% for every
  thread born mid-window** — which here is every audio thread, since they are
  recreated every 15.8 s. It produced a confident "no thread does any audio
  work", refuted minutes later by an `strace` showing 36,000 ioctls a second.
- **A probe whose own cost changes the measurement.** `WINEDEBUG=+mmdevapi`
  emits 200,000 lines a second (797 MB in 45 s) and throttles the application
  through pipe backpressure. Instrument inside Wine and count; do not log.
- **A rate measured across the end of its input.** `enginerate` scored 0.19x on a
  healthy engine because the track ended mid-window.
- **A liveness signal that expires.** The track file's offset stops advancing
  once a small file has been read to the end, while the deck plays on from
  memory — `playkeep` v1 "detected a stall" every 13 s and toggled play/pause on
  a healthy deck for a whole soak.
- **`grep` on a Wine log without `-a`** reports "binary file matches" and a
  capture pipeline built on it yields an empty file that reads as "the probe
  never fired".
- **A stat slot that stores a pointer into an object that is freed.** The
  per-client probe labelled every line after the first stream rebuild with freed
  memory.
- And the older ones: a probe that cannot fire; a probe that truncates; a probe
  that reads before the call it is timing; `strings | grep -q` under `pipefail`;
  `${VAR:+…}` expanding for `0`; measuring the wrong object; and **a dead device
  looks exactly like a fixed one** — always keep a liveness control.

## Standing rules

The user's daily configuration is **PC MASTER OUT off**, and it works — verified
at the end of this session at 0.98-1.01x with zero rebuilds, buffer size 256,
shipping `mmdevapi` restored. **Install nothing into that path that has not been
measured in that configuration.** One variable per run, cite run ids, write
findings to disk as you get them, and ask the user only for what genuinely needs
hands on hardware.
