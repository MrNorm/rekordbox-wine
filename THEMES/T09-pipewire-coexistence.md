# T09 — Wine's exclusive ALSA opens vs PipeWire: the desktop loses its audio nodes, permanently

**Opened 2026-08-17 (evening, immediately after the previous session ended at 16:48).** Found while checking machine health at the start of the
session, *before* running anything. Status: **OPEN, mechanism logged by the
system itself, repair and control runs pending.**

## The symptom, found live on this machine

    $ pactl list short sinks
    186481  auto_null  PipeWire  float32le 2ch 48000Hz  SUSPENDED

**There were no audio sinks on the machine at all** — not the laptop speakers,
not HDMI, not the DDJ-400 — only PipeWire's dummy fallback. Both cards were
present as *devices* with active profiles (`HiFi (…Speaker)` on the ThinkPad's
`sof-hda-dsp`, `pro-audio` on the DDJ), but no node had survived.

That state had been in place since **2026-08-17 15:26**, i.e. for the whole
second half of the previous session.

## The mechanism, straight out of the system journal

    15:25:58 spa.alsa: '_ucm0001.hw:sofhdadsp': playback open failed: Device or resource busy   (x3)
    15:25:58 pw.node: (alsa_output.…skl_hda_dsp_generic.HiFi__Speaker__sink-53)
                      suspended -> error (Start error: Device or resource busy)
    15:25:59 spa.alsa: 'hw:1,0': playback open failed: Device or resource busy                  (x3)
    15:25:59 pw.node: (alsa_output.usb-Pioneer_DJ_Corporation_DDJ-400…pro-output-0-130)
                      suspended -> error (Start error: Device or resource busy)
    15:26:00 …the same for _ucm0002..0007 (hw:sofhdadsp,3 / ,4 / ,5 / ,6)
    15:26:00 wireplumber: wplua: [string "alsa.lua"]:425: attempt to concatenate a nil value  (x14)

Two separate faults, one after the other:

1. **Something held every ALSA playback device open**, so PipeWire's own opens
   returned `EBUSY` and each node went `suspended -> error`. The only thing on
   this machine that opens `hw:` devices directly and exclusively is **Wine's
   `winealsa` in WASAPI exclusive mode** — which is precisely what rekordbox
   asks for, on the DDJ (`hw:1,0`) and, when the PC output is the
   `Speakers (Out: sof-hda-dsp - )` endpoint rather than `default`, on the
   laptop card as well. Both entries exist in rekordbox's settings.

2. **WirePlumber's error handler then crashed on its own error message.**
   `/usr/share/wireplumber/scripts/monitors/alsa.lua:425` is inside the
   `node:activate` failure branch:

       log:warning ("Failed to create ALSA node " ..
           n:get_property ("node.name") .. ": " .. tostring(err))

   For a node that failed to bind, `node.name` is nil, so the concatenation
   throws before the warning is ever printed. The Lua handler dies, the node is
   never stored and **never retried**. The device stays gone until wireplumber
   is restarted.

So the failure is not "Wine and PipeWire fight over a card for a moment" — it is
"Wine takes a card for a moment, and PipeWire loses it until the next login".

## Why this matters to this project, in three ways

1. **Every run made after 15:26 yesterday was made on a machine whose PC audio
   endpoint was a null sink.** That includes the runs that concluded RBW-RING
   "broke WASAPI — no tracks would load" and the settings pane threw device
   errors. That attribution is now **suspect and must be re-tested**; the patch
   may or may not be guilty, but a machine with no working sinks is an
   alternative explanation that was not on the table at the time.
   *(Not a claim that the patch is innocent. It is a claim that the experiment
   was not clean.)*
2. **It is a candidate for the user's own reported symptoms** — a PC MASTER OUT
   path that produces nothing, and a settings pane that reports device errors,
   are exactly what a machine with no sinks produces.
3. **It is a packaging deliverable.** A Gold-level package cannot leave the
   user's desktop audio dead after a DJ set. The fix belongs in the launcher or
   in a shipped WirePlumber rule (see "Candidate fixes").

## Candidate fixes, none yet tested

- **Take the DDJ away from PipeWire entirely.** A WirePlumber rule setting the
  Pioneer card's profile to `off` (or `api.alsa.disable`/monitor exclusion)
  means PipeWire never opens `hw:1,0`, so there is nothing to fight over and
  nothing to lose. Shippable with the package.
- **Point rekordbox's PC output at `default`, never at the raw card.** Going
  through PipeWire for the PC master out is cooperative; grabbing `hw:0`
  exclusively is not.
- **Report the WirePlumber crash upstream.** `alsa.lua:425` dereferences
  `node.name` on a node that failed to bind. It converts a recoverable `EBUSY`
  into a permanent loss of the device, for any application that ever opens an
  ALSA device exclusively. That is a real upstream bug independent of Wine.

## Hypothesis worth a controlled run — it may touch the main audio fault

PipeWire holding/opening `hw:1,0` on the DDJ while rekordbox tears its exclusive
stream down and rebuilds it every ~15.8 s is two servers reaching for the same
exclusive PCM on a 16 s cadence. **Control:** set the DDJ card profile to `off`
in PipeWire and re-run `bin/meterscope.py`, which scores the rebuild cycle
unattended. One variable, no track, no human.

## Repair procedure (for the runbook)

    systemctl --user restart wireplumber     # nodes are recreated
    pactl list short sinks                   # verify a real sink is back

## Run log

### `20260817T165505-pwclash` — REPRODUCED, Wine-free, in 30 seconds

`bin/pwclash.sh`. One variable: an ordinary `aplay -D hw:1,0` holds the DDJ's
PCM while PipeWire is asked to play to its own node on the same device. No
Wine, no rekordbox, no exclusive-mode API — just two processes wanting one PCM.

    pre    : DDJ sink present, hw:1,0 closed          <- liveness control
    hold   : hw:1,0 state RUNNING                     <- the hold is CONFIRMED, not assumed
    during : pipewire  'hw:1,0': playback open failed: Device or resource busy  (x3)
             pw.node   (…DDJ-400…pro-output-0-41) suspended -> error
             wireplumber  alsa.lua:425 attempt to concatenate a nil value
    release: hw:1,0 closed again
    +3 s   : DDJ sink GONE
    retry  : DDJ sink GONE            <- a second play attempt does not revive it
    repair : systemctl --user restart wireplumber -> sink back

**Verdict: one exclusive open costs PipeWire the device permanently.** The
contention itself is ordinary and unavoidable; the permanence is the bug, and it
is WirePlumber's, not Wine's — the `EBUSY` is recoverable, but the error handler
throws before it can record anything and the node is never retried.

The probe caught one of its own faults on the first attempt: `/proc/asound`
prints `state: RUNNING`, not `RUNNING`, so the hold-confirmation guard fired and
aborted rather than reporting a result. That is the guard working — without it
the run would have gone on to test nothing and report "PipeWire coped fine".

### What this makes true, and what it does not

**True:** any application that opens an ALSA PCM directly while PipeWire wants
the same one can silently delete that device from the desktop for the rest of
the session. rekordbox under Wine does exactly this, by design, on every
exclusive-mode stream — and it does it on a **15.8 s cycle**.

**Not established yet:** that this *causes* the rekordbox audio dropouts. The
node loss is a consequence of contention, and losing PipeWire's node does not by
itself stop Wine writing to `hw:1,0`. What it does establish is that the machine
these measurements were taken on has been in a degraded state since 15:26.
