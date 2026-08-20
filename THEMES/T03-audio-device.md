# T03 — DDJ-400: empty sample-rate list, and tracks not loading

**Status:** **REGRESSED 2026-08-14 — the rate list is EMPTY again.** See the
section at the very end of this file. The 2026-08-13 "rate list works" result
below is historically accurate but no longer describes the prefix.
**Opened:** 2026-08-13 · Was the declared critical path.

## Symptom

Reported by hand after plugging in the DDJ-400:

1. Tracks no longer load into a deck — *"unable to load track"*.
2. The DDJ-400 **is** listed as an audio device, but the sample-rate field is
   empty — and, on retest, so is every other device's.

## Root cause

rekordbox builds its sample-rate list by probing
`IAudioClient::IsFormatSupported` in **AUDCLNT_SHAREMODE_EXCLUSIVE**. That is
the correct thing for a DJ application to do — exclusive mode is what gives it
the device at its native rate with no resampler in the path — and it is exactly
what the API is for.

Wine's PulseAudio driver does not implement exclusive mode at all:

    dlls/winepulse.drv/pulse.c, pulse_is_format_supported()
        /* This driver does not support exclusive mode. */
        if (params->share == AUDCLNT_SHAREMODE_EXCLUSIVE)
            params->result = AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED;
        else
            params->result = S_OK;

Wine's default driver order puts pulse first, so every rate probe on every
device fails, and the list is empty — for all devices, which is precisely what
was observed. The ALSA driver does a real hardware check
(`dlls/winealsa.drv/alsa.c`, `alsa_is_format_supported()`).

## Fix, part 1 of 2 (necessary, not sufficient — see the REOPENED section at the end)

    wine reg add 'HKCU\Software\Wine\Drivers' /v Audio /d alsa /f

Prefix-scoped, so no other Wine application is affected. Ordinary playback still
reaches PipeWire, because winealsa's `default` endpoint is ALSA's default PCM.

## Evidence — one variable, both directions

`upstream/wasapitest.c`, a freestanding WASAPI probe built the same way as
`vblanktest.c`. Transcripts kept verbatim at
`upstream/wasapitest-output-pulse.txt` and `upstream/wasapitest-output-alsa.txt`.

| driver | exclusive `IsFormatSupported`, 6 rates × 2 channel counts × 4 depths | exclusive `Initialize` 44100/4ch on the DDJ-400 |
|---|---|---|
| pulse (Wine default) | 48/48 `AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED` (0x8889000e) | `AUDCLNT_E_EXCLUSIVE_MODE_NOT_ALLOWED` |
| **alsa** | **48/48 `S_OK`** | **`S_OK`; stream started, 66150 frames written, 3528-frame buffer** |

The `play` mode exists because "IsFormatSupported says yes" and "a stream
actually runs" are different claims, and a driver swap could easily satisfy the
first without the second. It opens the stream and pushes 1.5 s of a 440 Hz
square wave, so the claim is end-to-end.

## Two corrections to my own earlier reasoning in this file

Both were wrong, and both were wrong in ways that pointed away from the answer:

1. **"These are one bug."** Disproven by the user: a track loads and plays on the
   PulseAudio output with no sample rate shown. The empty list does not block
   loading, and the list is empty for every device, so it is not
   controller-specific either.

2. **"It is shared mode, so the exclusive theory is dead."** This came from
   reading `client_IsFormatSupported (...)->(0, ...)` in a `+mmdevapi` trace and
   taking mode `0` at face value across the whole log. Parsing the trace
   properly splits it cleanly:

   | mode | calls | format |
   |---|---|---|
   | 0 = SHARED | 51 | all 48000/2ch/32 — ordinary playback on the default sink |
   | 0 = SHARED | 1 | 44100/4ch |
   | **1 = EXCLUSIVE** | **47** | **4 channels, sweeping 44100 → 768000** |

   The rate sweep — the thing that populates the dropdown — was exclusive all
   along, on 4 channels (master + headphone cue). I had looked at the most
   common line rather than the relevant one.

   **Lesson:** a `grep -c` over a trace answers "what is most frequent", not
   "what is happening". The 47 exclusive calls were a third of the log and were
   the entire finding.

## Related facts established while chasing this

- **The DDJ-400 hardware is 44100-only** (`/proc/asound/card1/stream0`: altset 1
  S16_LE, altset 2 S24_3LE, rates 44100). Under winepulse the mix format was
  48000, which looked like a promising 44100-vs-48000 mismatch story. It was a
  red herring — the failure happens before any rate is considered.
- **winealsa's answers are optimistic.** It opens `plughw:` (ALSA's conversion
  layer), so it returns `S_OK` for 192000 on a 44100-only device. Streams work
  because ALSA converts, but the rate list is not a true hardware capability
  list. Noted in `PATH-TO-GOLD.md` as a known wrinkle.
- **MIDI needs no fix.** `upstream/miditest.c` shows
  `[3] DDJ-400 - DDJ-400 MIDI 1` on both winmm MIDI IN and OUT
  (`upstream/miditest-output.txt`). Whether rekordbox *binds* the controller is
  a separate, untested question.
- The PipeWire `pro-audio` card profile set in the previous session was
  **not** required: the exclusive stream opened with PipeWire still holding the
  card. Keep `pactl set-card-profile ... off` as a fallback for contention, not
  as a step.

## Still to confirm with the application itself (superseded — see REOPENED below)

The probe proves the Wine layer. What has not been watched by a human is
rekordbox's own preferences pane: that the rate list now populates, and that a
track loads with the DDJ-400 selected as output. That is symptom **B**, which
was never independently explained — the working hypothesis is that it was
downstream of the same failed negotiation, but that is inference, not evidence.

## Upstream

`upstream/wasapitest.c` is a reproducer needing no proprietary software. Worth
filing: with Wine's default configuration, any application that builds a format
list from exclusive-mode probes sees nothing at all, and the failure is
indistinguishable from "your hardware is unsupported".

---

## REOPENED and then resolved further, 2026-08-13 — the driver was not the whole story

**The user tested it and the rate list was still empty.** So the ALSA switch,
though correct and necessary, was not sufficient, and this file's "RESOLVED"
above was premature. What follows is the rest of it.

### Driving the real application, not the probe

Opened Preferences → Audio under the ALSA driver and looked:

- the device list **is** winealsa's (`Speakers (Out: default)`,
  `Speakers (Out: sof-hda-dsp - HDMI 1)` …), so the driver switch took effect;
- the selected device is **`DDJ-400 WASAPI`** — rekordbox's own name for a
  recognised Pioneer controller, and it re-selects it on every restart;
- Sample Rate: empty, and the dropdown opens to an **empty popup**;
- clicking Sample Rate fires **no** `IsFormatSupported` calls, so the list is
  built earlier, at device-selection time, not on demand.

### The actual blocker

`+mmdevapi` on the real application shows that after the rate probes rekordbox
calls:

    IAudioClient::Initialize(EXCLUSIVE, AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                             duration = period = 58050, float32)

immediately followed in the trace by `client_Stop` and `client_Release` — it
failed. `dlls/mmdevapi/client.c`, `adjust_timing()`:

    else if (flags & AUDCLNT_STREAMFLAGS_EVENTCALLBACK) {
        if (*duration != *period)
            return AUDCLNT_E_BUFDURATION_PERIOD_NOT_EQUAL;
        FIXME("EXCLUSIVE mode with EVENTCALLBACK\n");
        return AUDCLNT_E_DEVICE_IN_USE;
    }

Wine refuses event-driven exclusive mode outright, and reports it as
`AUDCLNT_E_DEVICE_IN_USE` on an idle device. This is in the **common layer**,
above the driver, which is exactly why swapping pulse for alsa changed nothing
the user could see. Event-driven exclusive mode is *the* standard low-latency
pattern for professional audio on Windows.

### Patch and result

`upstream/0002-mmdevapi-allow-event-driven-exclusive-streams.patch` drops the
refusal. The machinery below it already exists: the backends signal the client
event from their timer loops with no reference to share mode, and winealsa
already runs a 4-period ALSA ring (`mmdev_period_frames * 4`) regardless of the
mmdevapi-visible buffer size, so a one-period buffer does not mean a one-period
ring.

| mmdevapi | `Initialize(EXCLUSIVE\|EVENTCALLBACK)` | rekordbox rate list |
|---|---|---|
| stock | `AUDCLNT_E_DEVICE_IN_USE` | empty |
| **patched** | **`S_OK`**, 256-frame buffer = one period | **populated, 44100 Hz selected** |

Transcript: `upstream/wasapitest-output-event.txt`. Rate list confirmed by
screenshot with the DDJ-400 selected.

### Still incomplete — do not call this finished

The stream opens and the event fires, but `GetBuffer` for a full period returns
`AUDCLNT_E_BUFFER_TOO_LARGE` with padding stuck at the whole buffer, so the
probe services one period and stops. Wine's padding accounting does not free a
period per event the way the Windows contract requires. rekordbox gets far
enough to build its rate list; **whether it can sustain playback through the
controller is unconfirmed** and is the next thing to establish.

Note the instrument caught its own error here: the first version of the event
test printed "the event never arrived" for what was actually a failing
`GetBuffer`, because it broke out of the loop without reporting why. It now
prints the HRESULT and the padding.

### Not a driver-installation problem

rekordbox ships 50 driver installers in `drivers/` and **none is for the
DDJ-400** — it is USB Audio Class compliant and uses the inbox Windows driver.
They are InstallShield packages wrapping WDM kernel drivers, which Wine cannot
load regardless. That avenue is closed, not untried.


---

## REGRESSED 2026-08-14 — and it is now checked automatically

`bin/audiotest.sh` drives the real Preferences → Audio pane and reports
**FAIL, exit 1: the Sample Rate dropdown is empty.** Evidence
`runs/AUDIOTEST/20260814T045744-audio.png`.

    Audio Device combo   "DDJ-400 WASAPI"   peak=1.000 sd=0.367   (populated)
    Sample Rate combo    (nothing)          peak=0.000 sd=0.000   (pure black)

The device combo is the in-shot positive control: same widget, same skin, same
font, measured with the same code in the same screenshot. So this is a real
absence, not a dead measurement. The claim in STATE.md phase 5 that "the Sample
Rate dropdown populates and 44100 Hz is selected" no longer holds.

**What has NOT been re-established:** why. The 2026-08-13 fix was the alsa
driver plus the `mmdevapi` `adjust_timing()` patch. Whether one of those has
been lost from the prefix, or whether the cause is new, is untested — no
one-variable run has been done since the regression was found. That is the
next action for this theme.

### A headless probe cannot catch this — do not substitute one

`upstream/wasapitest.exe` reports **48/48 exclusive formats accepted right
now**, while the dropdown is blank. rekordbox builds the rate list at
device-selection time through a path wasapitest does not exercise, so the
API-level probe is a false negative generator and agrees with a broken UI. Only
the widget is an honest oracle. That is the entire reason `bin/audiotest.sh`
drives the UI instead.

### Regression check

    bin/audiotest.sh              # 0 populated, 1 empty, 2 harness fault
    bin/audiotest.sh --self-test  # proves the detector answers both ways

Regions and the reasoning behind every coordinate are in
`scenarios/regions.json` under `audio_prefs`.

---

## REGRESSED — 2026-08-14. And it is NOT a stale device selection.

The Sample Rate dropdown is empty again. Now automated:
`bin/audiotest.sh` → exit 1, reproduced across 8 runs.

    audio_device_value   active  peak=1.000 sd=0.367     <- "DDJ-400 WASAPI"
    sample_rate_value    absent  peak=0.000 sd=0.000     <- pure black, no glyphs

The positive control sits in the same screenshot, same widget class, same font,
so the absence is real and not a dead measurement.

### What is ruled out

- **Not a busy device.** `/proc/asound/card1/pcm0p/sub0` reads `closed`; no
  stray wineserver or rekordbox processes.
- **Not the Wine WASAPI layer.** `upstream/wasapitest.exe` reports
  **48/48 exclusive formats accepted on all 7 endpoints**, DDJ-400 included,
  *while the dropdown is blank*. Recorded here as the standing warning it is:
  **wasapitest passing is not evidence that this feature works.**
- **Not `cfgmgr32=native` or `winmm=native`.** Both overrides removed; symptom
  unchanged.
- **Not a stale selection that never probes.** This was the leading hypothesis
  and it is dead. `WINEDEBUG=+mmdevapi`, run `runs/MMDEV-TRACE.log` (24661
  lines), navigating to Preferences → Audio:

      client_IsFormatSupported  97 calls total
          share mode 1 (EXCLUSIVE)  45
          share mode 0 (SHARED)     52
      client_Initialize          4 calls

  rekordbox is probing exclusive formats, 45 times, with well-formed requests
  (`WAVE_FORMAT_EXTENSIBLE, 2ch, 48000, 32-bit, mask 0x3` on the first). For
  comparison the working phase-5 state recorded 47 exclusive probes. So the
  device IS selected, the probe IS issued, and the list is STILL empty.

- **Not the buffer/settings path.** The same pane shows
  `Buffer size: 256 samples (5.3 ms)` populated.

### The one variable never bisected

The system `/usr/lib/wine/x86_64-unix/winealsa.so` still carries patches
0006+0007. Its *audio* half (`alsa.c`, patch 0003) is byte-identical to the
working state — only `alsamidi.c` changed — which is why it was deprioritised.
Revert points are preserved and ready:

    artifacts/winedll/winealsa-0003.so              417384  RBW-EVENT
    artifacts/winedll/winealsa-0003+0004.so         418792  RBW-EVENT
    artifacts/winedll/winealsa-0003+0004+0006+0007.so 435208  all three

(`--revert` in install-system-wine-patches.sh restores the STOCK backup, which
drops 0003 and changes audio behaviour on its own. Do not use it for the
bisect; pass `RBW_WINEALSA=` explicitly.)

### Next action — get the RETURN values of those 45 exclusive probes

The trace shows the calls and their formats but not the HRESULTs. Establish what
Wine answers:

    grep -n "client_IsFormatSupported ([0-9A-F]*)->(1," runs/MMDEV-TRACE.log

then read forward past each `dump_fmt` block to the return. If they return S_OK
the failure is downstream in rekordbox and the rate list is being discarded, not
never built. If they fail, compare the *exact* format requested against what
wasapitest asks for — wasapitest sweeps 6 rates x 2 channel counts x 4 depths
and gets 48/48, so a format rekordbox asks for and wasapitest does not is the
discriminator.

### ROOT CAUSE FOUND — 2026-08-14. Wine promises exclusive formats the hardware cannot do.

Run `runs/ALSA-TRACE.log` (`WINEDEBUG=+mmdevapi,+alsa`, 10166 lines), navigating
to Preferences → Audio. The complete chain, every step measured:

    client_IsFormatSupported (1, ...)   x15 per client, 3 clients   -> S_OK
    client_Initialize (1, 40000, d055, d055, ... IEEE_FLOAT)
      dump_fmt  2 ch, 48000 Hz, 32 bit, dwChannelMask 0x3
      adjust_timing Requested duration 53333 and period 53333
      adjust_timing RBW-MMDEV exclusive mode with event callback    <- patch 0002
      adjust_timing Adjusted duration 53333 and period 53333
    alsa_create_stream RBW-EVENT build...                           <- patch 0003
    warn:alsa:alsa_create_stream Unable to set hw params: -22 (Invalid argument)
    client_Stop / client_Release  Refcount now 0                    <- rekordbox gives up

No `GetBufferSize`, no `GetService`, no `Start`. `Initialize` fails inside the
driver and rekordbox discards the device, so the rate list is empty.

**Why `hw_params` returns EINVAL.** `/proc/asound/card1/stream0` — the DDJ-400's
actual playback capability, the whole of it:

    Altset 1  Format: S16_LE    Channels: 4  Rates: 44100
    Altset 2  Format: S24_3LE   Channels: 4  Rates: 44100

Four channels only. 44100 only. S16_LE or S24_3LE only. rekordbox asks for
**2 channels, 48000 Hz, 32-bit float** — every single parameter is one the
hardware cannot do.

**Why rekordbox asks for that.** It starts from the mix format Wine advertises,
and Wine advertises `48000 Hz, 2 ch, 32 bit` for this device:

    dlls/winealsa.drv/alsa.c:2027
        if(max_rate >= 48000) fmt->Format.nSamplesPerSec = 48000;
        else if(max_rate >= 44100) ...

**The defect.** winealsa opens devices as `plughw:%d,%d`
(`alsa.c:359`). The `plug` layer resamples, converts formats and remaps
channels, so it advertises an enormous capability range regardless of the
hardware behind it. Both `alsa_get_mix_format` **and**
`alsa_is_format_supported` query that converted view — which is correct for
SHARED mode, and wrong for EXCLUSIVE mode, where the whole point is that there
is no conversion layer between the app and the hardware.

So Wine tells an application that a 44100-only 4-channel S16 device supports
2-channel 192000 Hz float in exclusive mode, and only discovers otherwise when
`snd_pcm_hw_params()` refuses the combination.

**This is why `upstream/wasapitest.exe` reports 48/48 and the dropdown is still
empty.** The probe asks `IsFormatSupported`, which is the call that lies. Its
`play` mode succeeded only because it happens to use **44100 Hz, 4 channels** —
the one combination the hardware actually supports. Recorded transcript:
`Initialize excl : S_OK (44100 Hz, 4 ch, 32f)`. That was luck, not coverage.

**Not a regression from patches 0006/0007.** Those touch `alsamidi.c` only. The
audio path reached its current state the moment rekordbox started asking for
48000 rather than 44100 — the mix-format default — and patch 0002 is what lets
the request travel far enough to fail in the driver instead of being refused in
mmdevapi.

### FIXED 2026-08-14 by patch 0008 — see below. Original proposal kept for the record:

### Proposed fix — validate exclusive formats against the raw device

In `alsa_is_format_supported`, when `params->share == AUDCLNT_SHAREMODE_EXCLUSIVE`,
query `hw:<card>,<dev>` rather than `plughw:<card>,<dev>`. Exclusive mode means
"no conversion", so the honest answer is the hardware's own capability mask.
`alsa_get_mix_format` should arguably do the same, but the mix format is a
shared-mode concept and changing it is riskier.

With that, rekordbox's probe of 48000/2ch/float correctly returns
`AUDCLNT_E_UNSUPPORTED_FORMAT`, its probe of 44100/4ch/S16 returns `S_OK`, and
the rate list is built from formats that will actually open.

**UNIMPLEMENTED AND UNTESTED.** This is a diagnosis, not a fix.

### Regression test this implies

`wasapitest` must stop being cited as coverage until it cross-checks
`IsFormatSupported` against an actual `Initialize` for the same format. A probe
that only asks the lying call cannot detect the lie. Extend it to attempt
`Initialize` for every format it reports as supported, and flag any format that
passes the probe and fails to open — on this device that should be 47 of 48.

---

## RESOLVED — 2026-08-14, patch 0008. Verified by automated gate.

`bin/audiotest.sh` → **PASS**, and confirmed visually: the Sample Rate combo
reads **44100 Hz**. Screenshot `runs/AUDIOTEST/20260814T081247-audio.png`.

The fix took three parts, because the plug-layer error was in three places:

| call | was queried against | now |
|---|---|---|
| `alsa_is_format_supported` | `plughw:` | `hw:` when share == EXCLUSIVE |
| `alsa_get_mix_format` | `plughw:` | `hw:` always — a mix format describes an endpoint |
| `map_channels` | positional remap always | pass-through when share == EXCLUSIVE |

The third was the one that nearly hid the fix. After correcting the first two,
the DDJ-400 went from 48/48 accepted to **0**/48 — over-rejection — because the
positional remap inflates the channel *count*: a 4-channel request carrying
`dwChannelMask FL|FR|FC|LFE` maps FC to ALSA index 4 and LFE to index 5, giving
`alsa_channels = 6`, which then failed `> max` against a hardware maximum of 4.
Diagnostic that caught it:

    RBW-DIAG device "hw:1,0": chans req 4 mapped 6, hw [4,4] -> S_FALSE

Measured before/after on the same hardware:

    mix format   48000 Hz, 2 ch, 32 bit  ->  44100 Hz, 4 ch, 16 bit
    exclusive    48 of 48 accepted       ->  2 of 48  (44100/4ch S16_LE + S24_3LE)

which is exactly what `/proc/asound/card1/stream0` reports. Other endpoints
stayed sensible (HDMI/analogue 48/48 → 1–2; `default` still 48/48, correctly,
because it really does convert).

### Side effects observed, both positive

- A new **blue audio-device icon** appeared in the toolbar.
- A new preference appeared: *"Output audio from the computer's built-in
  speakers and your DJ equipment"*.
- **MIX and LEVEL went live** — the headphone icon is white, the MIX knob has an
  indicator and the LEVEL knob shows a blue arc. `uiassert` scores both `active`
  where they were `greyed`. Two of the three tells the user named.

### A false pass this caused, and the lesson

The new toolbar icon shifted `PAD`/`MIDI` leftwards, and the `midi_indicator`
region drifted onto the bright white ⓘ glyph, scoring `active` with `peak=1.000`.
`uiassert --expect milestone` reported the MIDI milestone as MET. **It was not.**
Caught by cropping the region and looking at it.

Regions anchored by fraction survive a *resize*; they do not survive a *relayout*.
Any region sitting in a row of variable-length controls needs re-verifying by eye
whenever the UI changes, and a region whose neighbour is far brighter than its
subject is a false-pass waiting to happen. Recalibrated; both now read `greyed`,
matching the screen.

## Patch 0009 — relax patch 0003's event gating. It was starving the client.

Patch 0003 signalled the client event only when a FULL period was free:

    if(stream->event &&
       stream->bufsize_frames - stream->held_frames >= stream->mmdev_period_frames)

That removed the GetBuffer refusals it was written for (343 -> 0), and on a
real workload it starved the client instead. Measured with a track loaded:

    PCM:  RUNNING -> XRUN -> closed -> XRUN -> ...   continuously
    MIDI: Tx climbing ~19 bytes/sec with NOTHING being touched
          Rx completely flat at 13581

The climbing Tx was rekordbox rebuilding the audio stream over and over, each
rebuild re-sending the controller's LED initialisation — which the user saw as a
beat-loop LED flashing rapidly. One fault presenting as two.

Relaxed to signal whenever ANY space is free:

    if(stream->event && stream->held_frames < stream->bufsize_frames)

A client that then asks for more than is available still gets
BUFFER_TOO_LARGE and can retry, which is survivable. Being left unsignalled is
not.

**Result: the rebuild loop stopped.** Tx delta over 6 s went from ~114 bytes to
**0**, and the PCM holds RUNNING instead of XRUNning immediately.

### Correction — the idle XRUN is NOT a fault, and I initially read it as one

The negotiated stream is correct and healthy:

    format S24_3LE · channels 4 · rate 44100    <- exactly what the hardware offers
    period_size 1024 · buffer_size 4096         <- 93 ms
    start_threshold 1 · stop_threshold 4096

With `start_threshold 1` and `stop_threshold 4096`, an open stream that nobody
is writing to will reach stop_threshold and report XRUN **by design**. Sampling
`state:` while no track is playing therefore shows XRUN and means nothing.

The citable evidence for 0009 is the **Tx delta**, which is a measurement of
rekordbox's own behaviour rather than of an idle ALSA stream. Do not cite the
XRUN sampling as evidence for or against this patch.

### Untested

Whether a track now plays through to the end. That needs a human to press play;
no automated gate covers sustained playback yet, and `bin/audiotest.sh` only
checks that the rate list populates.

## Phase 12 — playback root cause: GetCurrentPadding never reports free space

`bin/playtest.sh` (new) closes the loop: it drags a track onto deck 1, clicks
play, and samples `appl_ptr` / `hw_ptr` from
`/proc/asound/card1/pcm0p/sub0/status` twice a second alongside the controller's
MIDI Tx counter. No human needed.

    appl_ptr advancing, hw_ptr advancing  -> audio genuinely flowing
    appl_ptr STALLED,   hw_ptr advancing  -> the CLIENT is being starved
    both stalled, state XRUN              -> the stream collapsed

Result with a track loaded and play pressed (`runs/PLAYTEST/20260814T123805.tsv`):

    app wrote data in 1 of 30 samples
    MIDI Tx +342 bytes during the test, Rx 0

### The measurement that explains it

`WINEDEBUG=+mmdevapi` over one play attempt:

    client_GetCurrentPadding   6,963,363 calls     <- busy-wait
    client_GetBuffer                  20
    client_Initialize                 20           <- 20 stream rebuilds
    client_Start                      20
    client_Stop                       73

Sampled diagnostic inside `alsa_get_current_padding`:

    RBW-PAD: padding(held)=1024 bufsize=1024 period=1024 in_alsa=1024 started=1
    RBW-PAD: padding(held)=1024 bufsize=1024 period=1024 in_alsa=0    started=1

**`held_frames` is pinned at 1024, which is both the buffer size and the
period.** In exclusive mode Wine makes the mmdevapi buffer exactly one period
(`duration == period`), so a client needs padding to fall to 0 before it can
write another full period. It never does. rekordbox polls ~70,000 times a
second, never gets space, never writes, ALSA drains, the stream collapses, and
rekordbox rebuilds it — 20 times in ~100 s.

Each rebuild re-sends the controller's LED initialisation. **That is the
flashing LED the user reports: an audio fault, not a MIDI one.** Rx is flat at 0
throughout, so the controller is not sending anything and is not causing the
stop.

Inside `alsa_write_data` the picture is a two-stream one (rekordbox runs master
and headphone streams) and one of them goes bad:

    avail=470  in_alsa=267 played=470  held=1323 started=1 max_copy=586
    avail=4096 in_alsa=0   played=0    held=1024 started=1 max_copy=1024

`held=1323` **exceeds** the 1024-frame buffer, which should not be reachable.

### Things tried that did NOT fix it

- **Buffer size 256 -> 1024** (`AudioBufferSize`). No change; left at 1024 as
  harmless headroom. Not the cause.
- **Patch 0009**, relaxing 0003's event gate. It did stop the rebuild loop while
  idle (Tx delta 114 -> 0) but not under load.
- **WASAPI shared mode** (`WasapiExclusive=0`). *Worse*: the DDJ-400's PCM is
  never opened at all — `state: closed` for the whole test, `appl_ptr` never
  moves. Reverted to 1.

### Harness faults found and fixed on the way

- playtest first reported "no audio was written at all" because **every restart
  empties the decks** and it was pressing play on an empty one. A harness fault
  presenting as a finding.
- A double-click only *selects* a library row — verified by screenshot, both
  decks still read `Not Loaded`. Loading needs a drag onto the deck, stepped
  rather than a single jump.
- Diagnostics were left at `ERR` level in a **system-wide** winealsa, which
  shows at default debug level and would spam every Wine app on the machine.
  Demoted to `TRACE`.

### Next

The fix has to make padding fall below a period in exclusive mode. Options, in
order of preference:
1. Understand how `held_frames` reaches 1323 (> bufsize) — that is an accounting
   bug and may be the whole story.
2. Give exclusive+eventcallback streams an mmdevapi buffer of several periods
   while still reporting `GetBufferSize` as one period, so the client always has
   somewhere to write.

## RESOLVED — 2026-08-14, patch 0010. Sustained playback, measured.

The trap was in `alsa_get_render_buffer`:

    if (stream->held_frames + frames > stream->bufsize_frames)
        return AUDCLNT_E_BUFFER_TOO_LARGE;

With `duration == period` the mmdevapi buffer is exactly one period, so a client
asking for a full period fails this whenever ANY frames are still held — which,
since `held_frames` only falls as ALSA consumes, is essentially always.

**My own patch 0002 caused this.** It allowed `EXCLUSIVE|EVENTCALLBACK` through
`adjust_timing` and left `duration == period`, on the stated assumption that
"the backends already run a multi-period ring underneath". They do not:
`duration` *is* the buffer. The non-event exclusive path a few lines below had
been widening to 8 periods for exactly this reason the whole time.

Patch 0010 widens the event-driven case to 4 periods.

### Before / after, same hardware, `bin/playtest.sh`

| | before | after |
|---|---|---|
| samples where the app fed audio | 1 of 30 | **28 of 30** |
| `appl_ptr` advance per 0.5 s | 0 | **~22000 frames (44100 Hz — real time)** |
| PCM state | XRUN / closed / rebuild | **RUNNING sustained** |
| stream rebuilds in ~100 s | 20 | 0 |
| MIDI Tx with nothing touched | ~19 bytes/sec | **0** |

`GetCurrentPadding` had been called **6,963,363** times against 20 `GetBuffer`
calls — a busy-wait for space that could never appear.

### This also killed the flashing LED

Each stream rebuild re-sent the controller's LED initialisation. With rebuilds
at zero the retransmission stops, which is why `Tx` goes flat. The symptom the
user reported as "the beat loop icon is flashing rapidly, something is looping
or miscommunicating" was **an audio buffer bug**, not a MIDI one. `Rx` was flat
at 0 throughout, so the controller was never sending and never caused the stop.

### State at this point

    audio    sustained playback at 44100 Hz, 4ch, S24_3LE exclusive  ✓
    MIDI     bound, Tx 15822 / Rx 16740, ALSA subscription both ways ✓
    UI       mix_control and level_control active                     ✓
             midi_indicator and pad_indicator still greyed            ✗

The remaining gap is the Pioneer-path recognition (T05 phase 9): MIDI is bound
via the renamed generic path, so rekordbox does not light its controller
indicator. Audio is no longer implicated in that.

## Phase 13 — PC MASTER OUT was the periodic dropout. Clean 60 s playback.

Patch 0010 got playback running but the user reported it "keeps stopping and
starting a few seconds later". A 60 s `bin/playtest.sh` run showed why — the
verdict line said SUSTAINED (114/120) and **hid the pattern**:

    stalls at t = 15.0, 15.5 · 31.0, 31.5 · 46.5, 47.0

A one-second dropout every ~15.5 s. Not jitter: `appl_ptr` reset to 0 each
time, always after ~650,000 frames ≈ 14.8 s. The stream was being **torn down
and reopened**, not starved.

Cause: **PC MASTER OUT** — "Output audio from the computer's built-in speakers
and your DJ equipment" — was enabled, routed to `Speakers (Out: default)`
(`pcmasterout_device_v2.txt`). That opens a SECOND audio client alongside the
DDJ-400's exclusive stream. The `+mmdevapi` trace shows it plainly: the format
dumped at the repeated `client_Stop` is 2-channel 16-bit, mask 0x3 — not the
4-channel S24_3LE DDJ stream.

A shared-mode PipeWire stream and an exclusive-mode hardware stream running
together is what the engine could not sustain.

Toggled off in Preferences → Audio. Same track, same 60 s test:

| | PC MASTER OUT on | off |
|---|---|---|
| samples that fed audio | 114 of 120 | **120 of 120** |
| stalls | 6, in 3 regular pairs | **0** |
| stream teardowns | 3 (~every 15.5 s) | **0** |

### Caveats, both important

- **The setting does not persist through `pkill`.** `MasterOutMode` stays `2`
  in `rekordbox3.settings` and the toggle is back on at next launch. `pkill`
  denies rekordbox its chance to save. Either close it from its own UI or
  re-toggle after each launch. The key backing this toggle has not been
  identified; `MasterOutMode` is NOT it.
- **The UI click needs care.** The toggle sits at prefs-window (235,160) and a
  click at (235,163) silently missed once. Verify by screenshot rather than
  assuming; a missed click looks exactly like a setting that did not help.

### Still unverified

Whether audio is actually AUDIBLE. `appl_ptr` advancing proves frames are being
written, not that they contain signal — the user reported no movement on
rekordbox's volume meter. That is the next thing to check and it needs either a
human or a loopback capture.

## Phase 14 — UI lag: rekordbox polls GetCurrentPadding ~90,000 times a second

New tool `bin/uilag.sh`, written because "the UI is extremely laggy" was a real
regression that nothing measured — and it is exactly the symptom a badly tuned
audio event produces, so without a number it is impossible to tell a Wine patch
that helped playback from one that wrecked the app.

It samples rekordbox CPU, **wineserver CPU** (the key signal — wineserver
arbitrates every cross-process call, so high usage means excessive round-trips)
and a coarse click-to-repaint latency.

### Measured

    wineserver, rekordbox running : 42-47%
    wineserver, rekordbox closed  : 0.3%     <- rekordbox is the cause
    mmdevapi calls, 10 s window   : 899,255  <- ~90,000/sec
    dominant call                 : client_GetCurrentPadding

**While idle. No track playing.** rekordbox busy-polls `GetCurrentPadding`
rather than waiting on the event it registered. On Windows that is a cheap
in-process read of shared state; under Wine every call is a unix-side
transition, so the same loop costs ~45% of a CPU and starves the UI.

### Patch 0009 reverted (now EVENT3)

0009 had relaxed 0003's event gate to "signal whenever ANY space is free",
because the client was being starved. That starvation was really patch 0002
leaving the mmdevapi buffer one period long — fixed properly by 0010 — and the
relaxed gate then signalled on every timer tick.

With 0010 in place the tight gate is restored. Verified it costs nothing:

| | 0009 (any space) | 0003 gate restored |
|---|---|---|
| playback, 60 s | 120/120, 0 resets | **120/120, 0 resets** |
| wineserver CPU | 46.6% | 43.5% |

So the relaxation was unnecessary. The remaining wineserver load is the polling,
not the signalling — changing the gate barely moves it.

### What this means

The lag is **rekordbox's polling design meeting Wine's call cost**, not a
regression from patches 0008/0010. It would have been present at any point
audio actually ran; before 0010 the stream collapsed too quickly to notice.

Not yet attempted, in order of promise:
1. A cheaper `GetCurrentPadding` — Wine has shared-memory fast paths for some
   audio calls; if padding can be published to a page the client reads directly,
   90k calls/sec becomes nearly free.
2. Check whether the poll rate depends on buffer depth (0010 currently uses 4
   periods; 8, as the non-event path uses, may change the client's behaviour).

### Still unverified

Whether the audio contains signal. `appl_ptr` advancing proves frames are
written, not that they are non-zero, and the user reports rekordbox's own volume
meter not moving. Nothing plugged into the controller's outputs at time of
writing, so this cannot be settled by ear yet either.

## Phase 15 — the padding cache was built on a wrong premise and has been reverted

I implemented a time-bounded cache for `GetCurrentPadding` on the theory that
its ~90,000 calls/sec were driving wineserver to 43%. **That premise was wrong**,
and the flaw was one I could have caught before writing a line:
`wine_unix_call` does NOT go through wineserver. It is a direct transition into
the unix side of the same process. So the padding calls, however numerous, were
never the server's cost.

Measured, same sequence (playtest then uilag) both times:

| | rekordbox CPU | wineserver CPU |
|---|---|---|
| no cache (EVENT3) | 70.5% | 43.5% |
| **with cache** | **138.0%** | 46.0% |

No benefit, plausibly harm. Reverted. Keeping an unjustified patch is precisely
the mistake made with 0009, and it does not get made twice.

The caching *reasoning* about safety still holds and is worth recording for
whoever tries again: `held_frames` is only updated inside `alsa_write_data`,
which runs once per period, so between callbacks the value provably cannot
change. A cache is safe. It simply does not address this bottleneck.

### Where the wineserver load actually is: still unknown

`rekordbox.exe` and `wineserver` are the only two processes with load (107% and
43%). Thread-level sampling inside rekordbox shows no runaway worker. `strace`
is not installed, so the syscall mix has not been profiled. The most likely
remaining explanation is a `WaitForSingleObject`-style call inside the same poll
loop — those DO reach wineserver — but that is inference, not measurement.

**Next step for this, and it needs a tool that is not installed:** `pacman -S
strace` (or `perf`), then `strace -c -f -p <rekordbox pid>` for five seconds.
That names the syscall in one command and ends the guessing.

## Verified final state, 2026-08-14

    playback   60/60 samples fed, 0 stalls, 0 resets over 30 s   PASS
    MIDI       Tx 93817 / Rx 23232, controller confirmed working  PASS
    audio      44100 Hz, 4ch, S24_3LE exclusive, sustained        PASS
    UI         wineserver ~46%, visibly laggy                     OPEN
    meter      no signal shown; frames written but content
               unverified (appl_ptr cannot distinguish silence)   OPEN

## Phase 16 — the lag profiled properly (strace), and a decision NOT to patch

`strace` installed with the user's permission. Note `kernel.yama.ptrace_scope=1`,
so attaching needs `sudo`.

### rekordbox.exe, ~6 s

    84.53%  futex          27,466  (19,476 timeouts)
     8.81%  read           85,766
     0.22%  rt_sigprocmask 159,680
     0.15%  getrusage      113,246   ~19,000/sec
     0.10%  writev          63,726   ~10,600/sec  <- wineserver requests
     0.08%  sched_yield     56,623   ~9,400/sec
                            536,745 total  (~89,000/sec)

### wineserver, ~11 s

    67.46%  write        532,786
    20.87%  read         326,442   ~30,000 requests/sec
    10.78%  epoll_pwait2 144,832

### A real Wine inefficiency, found and deliberately NOT patched

`getrusage` is exactly 2x `sched_yield` because `NtYieldExecution`
(`dlls/ntdll/unix/sync.c:2394`) costs **three** syscalls:

    getrusage( RUSAGE_THREAD, &u1 );
    sched_yield();
    getrusage( RUSAGE_THREAD, &u2 );
    if (u1.ru_nvcsw == u2.ru_nvcsw && ...) return STATUS_NO_YIELD_PERFORMED;

Two of them exist only to decide the return value. rekordbox calls
`SwitchToThread()` ~9,400 times a second, so Wine turns that into ~28,000
syscalls.

**Not patched, on purpose.** It is worth ~2-4% CPU, not the 65%. Removing the
rusage pair means always returning `STATUS_SUCCESS`, and an application looping
`while (SwitchToThread())` would then spin forever. That is a real regression
risk for a small win — and this theme has already had two patches (0009, and the
GetCurrentPadding cache) built on plausible stories and reverted. A third is not
justified by a 2-4% saving. Recorded here as genuine upstream material for
someone who can test it against a corpus of applications.

### Where the load actually is, stated honestly

rekordbox runs **194 threads**, most parked in `futex` or `read`. wineserver
handles ~30,000 requests/sec, of which rekordbox's own `writev` accounts for
~10,600/sec; the rest is spread across those threads. There is no single hot
loop to remove. This is a heavyweight application meeting Wine's
cross-process-call cost, not a specific defect I can point at.

**The honest conclusion: the lag is characterised but NOT fixed, and I do not
have a candidate fix I believe in.** Anyone continuing should start from the
`futex` figure — 19,476 of 27,466 waits timed out, which suggests contention
worth understanding before touching anything.

## Phase 17 — TWO results: ntsync fixes the lag; and my playback claim was WRONG

### 1. ntsync — the UI lag is FIXED, and it was never a Wine patch

`/dev/ntsync` (kernel 7.1.8 ships `ntsync.ko`) was simply **not loaded**. Without
it every Windows synchronisation primitive is a wineserver round-trip. The hot
thread was doing, 6,400 times a second:

    writev + read   -> REQ_select (request 29) = WaitForSingleObject
    sched_yield + 2x getrusage -> NtYieldExecution (SwitchToThread)
    2x rt_sigprocmask

i.e. 8 syscalls per spin, ~50,000 syscalls/sec from one thread.

    sudo modprobe ntsync
    echo ntsync | sudo tee /etc/modules-load.d/rekordbox-wine.conf

| | before | after |
|---|---|---|
| wineserver CPU | 43-65% | **1.5-1.9%** |
| rekordbox CPU | 70-138% | **~0%** |
| wineserver ntsync fds | 0 | 2688 |

**Critical operational detail:** wineserver opens `/dev/ntsync` ONCE and caches
the result (`server/inproc_sync.c`, `static int fd = -2`). Loading the module
while wineserver is running does nothing — wineserver must be killed and
restarted. That cost one wasted measurement cycle.

`bin/rekordbox-wine --check` now verifies both the device and the boot-time
config.

### 2. CORRECTION: "playback SUSTAINED" was measuring silence

**The claim in phases 10-13 that playback works is WRONG and is withdrawn.**

`appl_ptr` advances at real-time rate whether rekordbox is playing a track or
writing silence into an idle open stream. It cannot distinguish them. Measured
now with the deck's own elapsed-time readout:

    deck time readout: FROZEN (692391b667 -> 692391b667)
    VERDICT: MISLEADING PASS. The app fed audio in 24 of 24 samples, but the
             deck time readout did NOT advance.

The track sits at 00:00.0 (earlier 00:00.6 — it plays a fraction of a second and
stops). The user reported exactly this and I mis-attributed it to buffer
behaviour that the pointer counters made look healthy.

**What phases 10-13 DID establish, and still stands:** the audio *stream* is
healthy — it negotiates 44100/4ch/S24_3LE exclusive, sustains without XRUN or
teardown, and PC MASTER OUT genuinely did cause a 15.5-second teardown cycle.
The stream is fine. **Playback is not running through it.**

### Harness faults fixed here

- `playtest.sh` verdict now REQUIRES the deck time readout to advance. Without
  that it reported 120/120 against a frozen deck.
- `timehash()` silently returned the md5 of empty input when `spectacle` failed,
  which compares unequal to everything and reads as "advancing". Now returns
  `CAPTURE_FAILED`/`CROP_FAILED` and the verdict says UNKNOWN.
- An ad-hoc `spectacle -a` captured the **operator's terminal** instead of
  rekordbox, because `-a` grabs the active window and nothing had activated
  rekordbox first. Any capture must activate the window.

### Next

Why does play engage for ~0.6 s and stop? The click is confirmed on the button
(capture (779,472) -> screen (714,447), verified against a zoomed crop). The
audio stream stays RUNNING throughout, so it is not an audio dropout.

## Phase 18 — playback DOES work. The harness was pausing it.

Holding CUE showed the transport button change to a **pause icon**, proving the
deck plays. A manual play click then produced three different deck-time hashes
in three consecutive samples:

    c6b9faaf -> 9b00f0a5 -> 6af56891

**The track plays.** Phase 17's "FROZEN" verdict was the harness's own fault:
`playtest.sh` clicks the play button unconditionally, and that button is a
TOGGLE. On a deck left playing by a previous run, the click *pauses* it, and the
deck-time check then correctly reports FROZEN — a true reading of a state the
harness itself created.

**Correction to the correction:** phase 17 withdrew the claim that playback
works. That withdrawal was too broad. What is true:

- the audio stream is healthy (44100/4ch/S24_3LE exclusive, no XRUN, no teardown)
- the deck DOES play and the time readout DOES advance
- `appl_ptr` still cannot distinguish playing from silence, so the deck-time
  check remains necessary
- what is NOT established is whether playback SUSTAINS, because every automated
  attempt so far has been confounded by the toggle

**playtest.sh must read the button state before clicking** — pause icon means
already playing, play icon means click it — and re-check afterwards. It does not
do this yet, and until it does its verdict cannot be trusted in either
direction.

## Phase 19 (2026-08-17) — the PC MASTER OUT stall is AUDIO, measured across all layers at once

New instrument `bin/stallscope.sh`: MIDI wire counters, both PCM substreams,
rekordbox's thread wait-channels and X DAMAGE repaints, sampled at ~1.3 Hz
against one clock, so "audio paused and MIDI kept flowing" is a fact rather than
an impression. Run `runs/STALL/20260817T090837-pcmo2`, 90 s, PC MASTER OUT on,
track playing, controller bound.

**The DDJ's playback substream is torn down and reopened every ~15.8 s:**

    closed at t = 9.2, 25.5, 41.1, 56.8, 73.2, 88.9   (intervals 16.3 15.6 15.7 16.4 15.7)
    appl_ptr 626670 -> closed -> 27648 -> 61440 ...   (RESET, so destroyed and recreated)

A starving stream keeps its pointer; this one restarts from zero. Meanwhile
`card0` (the PC output, owner pid 1974 = PipeWire) stays `RUNNING` continuously
for the whole 90 s. This reproduces T03 phase 13's ~15.5 s figure exactly, on a
different day and a different instrument.

**MIDI is not involved, and this closes the question the user asked:**

| during the 15 samples where the DDJ stream was not advancing | |
|---|---|
| MIDI Tx still moving | **15 of 15** (48-81 bytes/sample — the 200 ms keep-alives, uninterrupted) |
| PC audio still moving | 15 of 15 |
| UI still repainting | 13 of 15 |

**And the UI does NOT freeze at the teardown.** Repaints per sample: **41.9
during the DDJ gap versus 40.5 while playing** — statistically flat. The
thread wait-channel is `futex_do_wait` throughout, in both states; nothing is
blocked in an ALSA ioctl or on the GPU.

Corroboration from the session log: **82 `control_RegisterAudioSessionNotification`
and 80 `Unregister`** in one session — about two per teardown, i.e. a fresh audio
client each cycle, which is what a destroy/recreate looks like from above.

### What this does and does not explain

It explains a ~1.5 s dropout every ~16 s. **It does not match "long pauses with
brief playing"** — the measured duty cycle is the opposite way round (≈14 s of
audio to ≈1.5 s of gap) — **and it does not reproduce the UI lock-up at all.**
Either the user's worse symptom needs conditions this capture did not have, or
there is a second fault. That must be settled before any fix is designed, and it
is the next question to the user rather than something to guess at.

### The mechanism to test next

Two unsynchronised clocks are running: the DDJ's exclusive hardware stream and
PipeWire's shared stream. On Windows the Pioneer driver clocks both. A drift
detector resyncing every ~16 s would look exactly like this. The Wine-side
suspicion worth testing is whether `IAudioClock::GetPosition` /
`GetCurrentPadding` report a position for the DDJ stream that drifts from real
time — if Wine's clock is wrong, rekordbox is right to resync, and the bug is
ours. Patches 0002, 0003, 0010 and the unversioned EVENT3 all live in exactly
that path.

### Phase 19b — listening at the wire: the DDJ is sent ONE SECOND of audio per 16 s cycle

The user's report was "audio is less than 1s and the gaps are 15s", which is the
inverse of the duty cycle phase 19 measured from `appl_ptr`. Both are true, and
the difference is the thing phase 13 warned about and nobody had yet measured:
**`appl_ptr` advancing proves frames are being written, not that they contain
signal.**

Captured the DDJ's isochronous audio endpoint directly (usbmon, iso OUT ep 1,
S24_3LE 4ch) and computed the RMS envelope of what the hardware actually
receives, 45 s:

    t=  0.0s  -####   ----------------------------------------------------
    t= 15.0s  ----####    ------------------------------------------------
    t= 30.0s  --------####   ---------------------------------------------

    AUDIBLE in 12/180 buckets = 3.0 s of 45.0 s
    silent stretches: 14.75 s, 15.0 s, 12.0 s

`#` is signal, `-` is **digital silence being actively transmitted** — the
isochronous stream never stops and the frames keep flowing at 44.1 kHz. So the
controller is sent one second of music and then fifteen seconds of zeros, in
lockstep with the 15.8 s teardown/reopen cycle.

**And the PC output is fine.** Recording the laptop sink's monitor for 60 s:
continuous music, mean RMS 3146, one 0.14 s dip at the recording start and
nothing else. 100% audible.

So with PC MASTER OUT enabled, rekordbox plays perfectly to the computer and
sends the controller a second of audio per cycle. That is precisely what the
user hears, and it also explains the master-out icon flickering — the stream
really is being lost and reacquired.

**An instrument correction, and it matters.** Phase 19's "PC audio moving 15/15"
was measuring `card0/pcm0p`, which is owned by PipeWire (pid 1974) and advances
continuously whether or not any application feeds it. It said nothing about
rekordbox. `bin/stallscope.sh` now samples rekordbox's own PipeWire node
(`alsa_playback.wine-preloader`) instead, and that node vanishes and returns at
exactly the timestamps the DDJ substream closes — 11.2, 27.3, 43.3, 59.5, 75.6,
91.0, 107.1 s.

### The discriminator to run next

rekordbox is writing frames at the correct rate and they contain zeros. Two
readings, and one call separates them:

- **the application is deliberately writing silence** — it would set
  `AUDCLNT_BUFFERFLAGS_SILENT` on `ReleaseBuffer`, and Wine is innocent;
- **Wine is losing the data** — the app writes real frames and something between
  `GetBuffer` and the hardware zeroes or discards them, which would be ours.

A `+mmdevapi` trace of the DDJ stream shows `ReleaseBuffer`'s flags directly.
Run that before designing any fix.

### Phase 19c — UNATTENDED REPRODUCTION, and the rate mismatch is refuted

**The 15.7 s destroy/recreate cycle happens with no track playing and nobody at
the machine.** Launch rekordbox, leave it idle, and both output streams vanish
and return on a fixed cadence:

    t=  0.0s  none        (rekordbox's PipeWire node)
    t=  1.5s  46=running
    t= 16.3s  none
    t= 17.0s  46=running
    t= 31.8s  none
    t= 33.3s  46=running
    t= 47.4s  none
    t= 49.0s  46=running

Six distinct mmdevapi render clients in 100 s idle. This is the unlock for the
next session: **the fault needs no human, no playback and no controller
interaction**, so it can be bisected freely.

### Refuted with one variable: the sample-rate mismatch

PipeWire runs its graph at **48000 Hz**; the DDJ-400 supports **44100 Hz only**
(`/proc/asound/card1/stream0`: `Rates: 44100`). Two devices at disagreeing rates
was the obvious candidate. Forced them to agree:

    pw-metadata -n settings 0 clock.force-rate 44100     (revert with ... 0)

Measured at the DDJ's isochronous endpoint with a track playing: **identical** —
2.0 s audible out of 35 s, the same 1-second burst per ~16 s cycle as at 48 kHz.
The rate mismatch is not the cause. Reverted.

### What the render probe established, and where it misled me

`debug/mmdevapi-render-probe.c.txt` counts, per audio client per second,
ReleaseBuffer calls, frames, `AUDCLNT_BUFFERFLAGS_SILENT` and whether the
application's buffer held any non-zero byte.

- **rekordbox never sets `AUDCLNT_BUFFERFLAGS_SILENT`** — `silent=0` on every
  line, on both clients, always.
- Both clients are written at full rate: ~263 calls/s and ~44,500 frames/s for
  the DDJ (exclusive, ~170-frame buffers) and ~43 calls/s for the PC stream
  (shared, ~1024-frame buffers).
- **The non-zero scan is NOT yet trustworthy** and its result must not be
  quoted. It reported `nonzero=0` across a window in which the USB wire proved
  real audio reached the controller. The cause was a four-slot stats table
  filling with dead client pointers — rekordbox recreates its clients every
  ~15 s — so the probe went silent exactly when the behaviour began. Fixed with
  LRU recycling, but **not yet re-run to a conclusion**.

So the question this phase set out to answer — *is the application writing
zeros, or is Wine losing the data?* — is **still open**, and the fixed probe
plus the unattended repro are what the next session should use to close it.

### Next, in order, all unattended

1. Re-run the fixed probe against the idle repro and read `nonzero` honestly.
2. Bisect the audio patches against the cycle: the escape hatch already exists
   for MIDI (`RBW_NO_RAWOUT`); add equivalents, or A/B by installing stock
   `winealsa.so` from `.rbw-backup`.
3. Establish whether the cycle needs two output devices at all, by removing one.

## Phase 20 (2026-08-17) — ROOT CAUSE OF THE CYCLE: the client is never given the buffer it was promised

Instrumented `mmdevapi`'s lifecycle and `winealsa`'s refusal path (both debug
only, `debug/`). Idle, no track, unattended:

    GetBuffer  hr=88890006  <== FAILED (157013 suppressed)   ... every second
    ... 15 seconds of that ...
    Stop client=A / Stop client=B / Initialize A / Start A / Initialize B / Start B
    ... repeat forever

`0x88890006` is **AUDCLNT_E_BUFFER_TOO_LARGE**, on the EXCLUSIVE client
(44100/4ch — the DDJ), at **~158,000 refusals per second**. After ~15 s of never
being served, rekordbox tears both streams down and rebuilds them. **That is the
15.7 s cycle**, and the one-second-of-audio-per-cycle is the brief window right
after `Start` before the refusals begin.

The refusal condition, with the numbers that decide it:

    asked=1024  held=759  bufsize=1024  alsa_period=256  mmdev_period=256  in_alsa=759

rekordbox asks for **1024 frames — the whole buffer it was told it had** — which
is the correct WASAPI pattern for an exclusive event-driven stream. Wine can
never satisfy it, for two independent reasons:

1. **`held_frames` counts frames Wine has already copied into ALSA.** `held ==
   in_alsa` on every single sample, i.e. the mmdevapi ring was EMPTY and the
   request was refused anyway.
2. **The ring is exactly the advertised buffer size**, so even with correct
   accounting a full buffer can only be handed over when the ring is completely
   empty — which never happens while streaming.

### The fix, in three parts, and what each one bought

| change | effect, measured |
|---|---|
| free space judged by what is still in OUR ring, not `held_frames` | numbers moved, refusals continued |
| ring allocated deeper than the advertised buffer | refusals **158,000/s -> 44/s** |
| **advertise one period** for exclusive event streams (the Windows contract) and keep the deeper ring behind it | refusals **0**, and `GetBuffer` now **succeeds ~385 times a second** |

`RBW-DBLBUF exclusive: advertising 256 frames, ring 1024, period 256`.
Marker greppable in the installed library.

### Not finished, and stated plainly

**The stream rebuild still happens** — in fact more often, roughly every 8 s
instead of 15.7 s — and now with **zero** Wine-side failures anywhere in the
lifecycle log. So the BUFFER_TOO_LARGE storm was real, is fixed, and was *not*
the whole story. Whatever triggers the remaining teardown, Wine is not reporting
an error for it.

Two things are needed before this can be called a fix:

1. **Validation with a track playing.** Every measurement in this phase is idle,
   where writing silence is correct behaviour. The oracle is the isochronous
   capture: audio should be continuous instead of one second per cycle.
2. **A check that the single-device case did not regress.** Advertising 256
   frames instead of 1024 is a shorter buffer; the previously-working
   PC-MASTER-OUT-off path must be re-measured.

Until both are done this stays in the tree as work in progress, not in the
shipping series.

### Phase 20b — the rebuild is a ~7.5 s poll in the application, and four candidate triggers are dead

With the WIP patch installed (refusals zero), instrumented every low-frequency
mmdevapi entry point — 105 COM methods across `session.c`, `devenum.c`,
`audiosessionmanager.c` — each with a millisecond timestamp.

**What precedes every teardown, identically:** a full device sweep
(`MMDevEnum` / `MMDevCol_GetCount` / repeated `MMDevice_GetId` /
`MMEndpoint_GetDataFlow` / a burst of `MMDevice_Release`), then
`GetDefaultAudioEndpoint`, then `client_Stop` on both clients, then
`Initialize`/`Start` on both. It repeats on a **~7.5 s** interval, idle, with
**no failing call anywhere in the log**.

**Eliminated as the trigger, each measured:**

| candidate | verdict |
|---|---|
| `AUDCLNT_E_BUFFER_TOO_LARGE` storm | fixed by the WIP patch; **the rebuild continues** |
| `IAudioClock::GetPosition` | **never called at all** — probe installed and able to fire, zero lines across 20 rebuilds |
| device list changing | **stable**: count 10 across 127 polls, one CHANGED line at startup |
| default endpoint changing | **stable**: exactly one render pointer and one capture pointer across 32 teardowns |
| sample-rate mismatch | refuted in phase 19c |

So rekordbox re-initialises its audio on a timer and Wine reports nothing wrong.
The next suspects are the ones not yet instrumented: what the app reads from
each device during the sweep (`IPropertyStore` values — friendly name, format,
`PKEY_AudioEngine_DeviceFormat`), `IAudioClient::GetService` for interfaces Wine
refuses, and `IMMNotificationClient` registration. Note
`control_RegisterAudioSessionNotification` is a **Wine stub that returns S_OK**
and is called about twice per cycle, so the app believes it registered for
session events it will never receive.

### The user's observation corroborates the measurement

*"the master level volume icon flashes up briefly (<500 ms) then vanishes for
many seconds"*. That is the level meter following the audio, and it matches the
isochronous capture exactly: signal present for a short burst, then digital
silence for the rest of the cycle. It is the same phenomenon, not a second
fault — useful because it means the on-screen meter is a faithful, free
indicator of whether the fix is working.

### Could not run: the single-device regression test

Emptying `AppData/Roaming/Pioneer/rekordbox6/pcmasterout_device_v2.txt` does not
disable PC MASTER OUT — rekordbox rewrites it (`Speakers (Out: default)`) from
its own settings. The setting survives, so the one-device arm still needs the UI
toggle, and the WIP patch therefore still must not ship.

## Phase 21 (2026-08-17) — the master-level dial flash, traced: it is locked to the stream rebuild

The user asked for the flashing indicator to be the centre of the investigation.
`bin/meterscope.py` samples the toolbar strip through the compositor
(`import -window`, ~8 Hz) **and the DDJ playback substream in the same loop**, so
the pixels and the audio stream share one clock and no alignment between two
tools is needed. It refuses to run if every region reads pure black, which is
the XWayland capture fault of T00 I1.

Regions watched: the blue PC-MASTER-OUT laptop icon, the circular master dial,
the two level-meter bars, the small segmented bar, and the clock as a control.

**Result, idle, no track, 75 s, shipping build:**

    PCM RUNNING -> closed    12.8   28.8   44.6   60.5
    PCM closed  -> RUNNING   14.0   29.8   45.7   61.5
    bluebar lights at        14.2   30.0   45.9   61.9
    dial lights at           14.2                 61.9

**The indicator lights 0.2-0.4 s after the stream reopens, four times out of
four.** Intervals 15.81, 15.93, 15.97 s against PCM reopen intervals of 15.8,
15.9, 15.8 s. The clock region ticks throughout as a control, so the capture is
live and the strip is not frozen.

**So the flash is not a UI fault, not a GPU fault, and not a separate problem.**
It is the level meter faithfully reporting the only moment audio exists: the
brief window after each stream restart, which is exactly the one second of
signal the isochronous capture sees at the wire. The user's description --
"flashes up briefly then vanishes for many seconds" -- is a precise, unaided
observation of the audio fault, and the two are now measured to be the same
event.

### Why this matters more than the finding itself

`meterscope.py` is an **unattended oracle for the audio fault**. It needs no
human, no track playing and no controller interaction:

- fault present -> the indicator flashes on a ~16 s cycle;
- fault fixed -> the indicator should stop cycling.

Every previous check of this fault needed the user to play a track and describe
what they heard. That loop is now closed, and any candidate patch can be scored
in 75 seconds.

### Phase 21b — the oracle scores the WIP patch, and refutes half of it

Two variants, 75 s each, idle, no human, scored by `bin/meterscope.py`:

| build | indicator cycle | PCM behaviour |
|---|---|---|
| shipping | 15.8 - 16.0 s | RUNNING/closed only |
| WIP: deeper ring **+ advertise one period** | **8.2 s** (twice as often) | **RUNNING <-> XRUN constantly** |
| WIP: deeper ring only, advertise as requested | 15.8 - 16.0 s | RUNNING/closed only, **no XRUNs** |

**The period-sized advertisement is refuted.** It removed the
`BUFFER_TOO_LARGE` refusals but starved the device: continuous underruns and a
rebuild twice as often. That is exactly the regression risk flagged when it was
written, and it was caught in 75 seconds by a tool that needs no human — where
the previous evidence loop needed the user to play a track and describe the
sound.

**The deeper ring on its own is neutral-to-good**: no XRUNs, same cycle, and it
removes the ~158,000/s refusal storm. It is a real efficiency and correctness
improvement, but on its own it does not fix the cycle, and the single-device
case still has not been measured, so it still does not ship.

### What the flash actually indicates — a correction worth making

Phase 21 called the indicator "the level meter following the audio". The idle
runs refine that: it flashes at every stream reopen **even with no track
playing and therefore no signal**. So it is better read as a *device
connected/ready* indicator that re-animates on reconnect, not a signal meter.
The correlation with the rebuild is unchanged and is what matters -- but the
inference "it shows audio level" was one step further than the evidence went.

### Where the audio investigation now stands

The rebuild cadence is unchanged by anything done to the buffer path, and it
survives with zero Wine-side errors. Two readings remain open:

1. rekordbox rebuilds on a fixed ~16 s timer regardless, and the audible fault
   is that audio only flows for ~1 s after each restart (which the shipping
   build explains: that is when the refusal storm begins). On Windows the same
   rebuild would be inaudible.
2. Something Wine reports, that is not an error, tells rekordbox to rebuild.

Distinguishing them needs a track playing, because idle cannot show whether
audio *sustains* between rebuilds. That is the one measurement still requiring
the user.

## Phase 22 (2026-08-17) — the audio arrives just BEFORE each teardown, not after the restart

Track playing, shipping build, wire capture and `meterscope` run together
(tshark started ~1 s before meterscope's clock, so meterscope t ~= tshark t - 1):

    audio bursts at the DDJ   12.0   28.0   44.0   60.0   75.5   (1.0-1.5 s each)
    PCM closes               ~12.2   28.0   43.9   59.7
    PCM reopens               13.3   29.1   45.0   60.9
    level meters light        11.6   43.3   59.2   (brief, just before each close)

    total audible 6.5 s of 80 s

**This overturns phase 20's reading.** I had written that the one second of audio
was "the window right after Start before the refusals begin". It is the
opposite: after each restart the stream is open and **silent for ~14 s**, then
about a second of real audio appears, and *then* the stream is torn down. The
level meters agree — they light in the half-second before each close, not after
the reopen.

The likeliest explanation for a burst that ends at the close is a **flush**:
buffered frames pushed out as the stream is stopped. Which would mean the
application cannot feed the stream during normal running at all, and the only
audio that ever escapes is what drains on teardown.

That is exactly consistent with the shipping build's measured behaviour:
`GetBuffer` refused ~158,000 times a second for the whole 15 s, so nothing can
be written; the stream carries silence; at teardown whatever was buffered
escapes; repeat.

### What this predicts, and the test for it

If the burst is a teardown flush, then **fixing GetBuffer should turn the audio
continuous**, not merely more frequent. The period-advertisement variant already
moved it from 3.0 s in 45 s (7%) to 15 s in 40 s (37%) — consistent with the
client finally being able to write — but it starved the device with XRUNs.

The remaining candidate is the **deeper ring alone**, which idle-tested clean:
no XRUNs, refusal storm gone. It has never been measured with a track playing.
That is the next run, and it is the one that decides whether the buffer work
ships.

## Phase 23 (2026-08-17) — SETTLED: the application writes the silence. Wine does not lose it.

The question open since phase 19b is answered. The render probe (fixed with LRU
slots, and **demonstrably able to fire** — it reports 0 for fourteen seconds and
then 171 of 172) during playback, shipping-equivalent build:

    calls=260  frames=44032  silent=0  nonzero=0      <- ~14 s, ALL ZEROS
    calls=43   frames=44032  silent=0  nonzero=0
    calls=260  frames=44032  silent=0  nonzero=40     <- signal appears
    calls=43   frames=44032  silent=0  nonzero=6
    calls=172  frames=30463  silent=1  nonzero=171    <- nearly every buffer
    calls=29   frames=29696  silent=1  nonzero=28
                                                      <- teardown, then repeat

**rekordbox writes digital silence into both streams for ~14 s of every 16 s
cycle, then real audio for ~1 s, and the stream is torn down.** It is being
served throughout — `GetBuffer` succeeds ~302 times a second — and it writes
zeros anyway. Wine transmits faithfully what it is handed, which is why the
isochronous capture shows the same shape at the wire.

**Wine's audio data path is therefore not the cause of the dropouts.** Four
buffer variants were measured against a track playing:

| arm | audio at the DDJ | XRUNs | cycle |
|---|---|---|---|
| shipping | 8% | no | 15.8 s |
| free-space check only (ring 1024) | 7% | no | 15.8 s |
| **deeper ring 2048, advertise 1024** | 8% | no | 15.8 s |
| advertise one period (ring 1024) | 37% | **yes** | 8.2 s |

Only the arm that changed the *timing* moved the number, and it did so by
starving the device. Nothing in the buffer contract makes the application
render.

### What this redirects the work to

The fault is above WASAPI: rekordbox's engine declines to produce audio into
these streams for most of each cycle. The remaining Wine-shaped questions are
about what it *reads* before deciding:

- `IAudioClock::GetPosition` is **never called** (measured), so it is not
  syncing on the stream clock.
- The two streams have very different service rates — the shared PC stream ~43
  calls/s (~1024-frame buffers, 23 ms) against the exclusive DDJ stream ~260
  calls/s (~170-frame buffers, ~4 ms). On Windows a Pioneer interface presents
  one device through its own driver; here the engine is asked to drive two
  unrelated clocks at very different periods.
- Not yet checked: `GetDevicePeriod`, `GetStreamLatency`, `GetMixFormat` and the
  `IPropertyStore` device-format values — what Wine tells the app about each
  device is now the most likely place a wrong answer would make the engine
  refuse to render.

### The honest headline

**The BUFFER_TOO_LARGE storm was a real Wine bug and is worth fixing on its own
merits** — 158,000 wasted refusals a second, and the user reports the visualiser
is "much smoother" between pauses with the deeper ring in — **but it is not the
cause of the audio dropouts, and no buffer change will fix them.**

## Phase 24 (2026-08-17) — "render blocking" tested directly, and refuted

`bin/threadscope.py` samples all ~200 rekordbox threads every 250 ms — CPU
consumed, kernel wait channel, state — alongside the DDJ substream in the same
loop, then splits each thread's CPU into the **silent** phase and the ~1 s
**burst** before each teardown. A producer that is gated would show near-zero
CPU while silent and a spike during the burst, and would name its blocker in
`wchan`.

**Track playing, 90 s, five teardowns (15.8, 31.5, 47.3, 63.3, 79.0):**

    tid       %cpu burst  %cpu silent  ratio  wchan
    2422293      53.24       49.26      1.08  poll_schedule_timeout
    2424467      10.93        9.68      1.13  (running)
    2424289      10.84        9.68      1.12  (running)
    2424382      10.76        9.61      1.12  (running)
    2424211      10.67        9.63      1.11  (running)
    2424552      10.58        9.51      1.11  (running)

**No thread runs only during the burst.** Every ratio is ~1.1: the application
is doing the *same amount of work* while it emits silence as while it emits
audio. Nothing is parked waiting and then springing to life. **The
render-blocking hypothesis is refuted** — rekordbox is not stalled, it is busy,
and busy producing zeros.

### What the busy threads actually are

The 53% thread is the **GPU/X11 renderer**, not audio. `strace` of it alone:

    88.55% poll   (fd 17, the X11 socket)
     4.47% ioctl  DRM_IOCTL_I915_GEM_EXECBUFFER2 / GEM_MADVISE / SYNCOBJ_WAIT
     2.03% recvmsg  (2809 of 3680 EAGAIN)
           NTSYNC_IOC_WAIT_ANY -> ETIMEDOUT

Half a core on graphics submission and X protocol, in both phases. That is T08
territory, and it is consistent with the user reporting the visualiser as
"much smoother" once the refusal storm was removed.

**And the thread writing to the sound card is Wine's, not rekordbox's:** tid
2425732 issues every `SNDRV_PCM_IOCTL_WRITEI_FRAMES` on fd 611
(`/dev/snd/pcmC1D0p`) — 2,204 in six seconds — faithfully pushing out the zeros
it was given. rekordbox's own audio thread makes **no syscalls at all**, because
Wine's `GetBuffer`/`ReleaseBuffer` are unix-library calls rather than kernel
calls, which is why no thread shows an audio signature under strace.

### Where that leaves it

Three layers are now cleared by measurement: Wine does not lose the data
(phase 23), the buffer contract does not gate the app (four arms, phase 23), and
the app is not blocked (this phase). rekordbox is running at full tilt and
choosing to emit silence.

The remaining Wine-shaped question is what it is **told** about each device
before it decides. Not yet instrumented, and all low-frequency and cheap:
`GetDevicePeriod`, `GetStreamLatency`, `GetMixFormat`, `IsFormatSupported`, and
the `IPropertyStore` device-format values. Those are static, so they can be read
with the app idle and need no track and no human.

### Phase 24b — what Wine tells the app about each device is correct

Instrumented `GetDevicePeriod`, `GetStreamLatency`, `GetMixFormat` and
`GetBufferSize` (idle; these values are static, so no track and no human):

    GetDevicePeriod    def=100000  min=50000 (100ns)  hr=0     -> 10 ms / 5 ms
    GetMixFormat       48000 Hz  2ch  32-bit          hr=0     -> the PC device
    GetMixFormat       44100 Hz  4ch  16-bit          hr=0     -> the DDJ
    GetStreamLatency   23.99 ms  and  15.6 ms         hr=0
    GetBufferSize      1024 frames  and  1323 frames  hr=0

**All sane, all succeeding.** No wrong answer here for the engine to trip over.

**A probe fault caught before it became a finding.** The first version of this
logging printed `*defperiod` *before* calling `get_periods()`, so it was reading
the caller's uninitialised stack. It produced `def=0`, `def=917751600` (91
seconds) and `min=5458064128` (545 seconds) — which looks exactly like Wine
returning garbage, and would have been reported as a serious bug. Logging after
the call gives 10 ms / 5 ms. **Read-before-write in a probe is the same class of
error as the four-slot table and the truncating hex dump: it fabricates a
finding rather than missing one.**

### Open inconsistency to resolve next

The render probe reports `nonzero=0` for **both** clients — the exclusive DDJ
stream and the shared PC stream. But an earlier 60 s recording of the laptop
sink monitor showed **continuous, clean music** (100% audible, mean RMS 3146).
Both cannot be true of the same moment. Either the PC client is also silent now
and that recording was of a different state, or the probe is misreading the
shared client. **Resolve it by recording the laptop monitor and the DDJ wire in
the same window, with a track playing** — one run, and it decides whether the
application is silencing everything or only the controller.

## Phase 25 (2026-08-17, evening) — THE FAULT HAS A NUMBER: the engine runs at 0.05x real time, and PC MASTER OUT is the switch

Two results, both from runs made minutes apart on one launch, and they change
what this theme is about.

### 25a — the phase-24b inconsistency is resolved: the PC stream is silent too

`bin/dualsink.py` samples the DDJ substream and the laptop sink's **monitor** in
one loop, on one clock, with the recording bucketed at 250 ms — the same
one-process discipline that settled the master-level flash.

Run `20260817T171408-dualsink`, track playing, PC MASTER OUT on, 50 s:

    peak RMS on the PC monitor        1075        <- the recording is real
    buckets with audible PC audio     16/195  (8%)
    DDJ substream state changes       6           <- the rebuild cycle is present

    audio at t = 6.7 .. 7.4    then close at 7.43
    audio at t = 22.3 .. 23.1  then close
    audio at t = 38.2 .. 39.0  then close

**The PC master out — an ordinary shared-mode PipeWire client, nothing exclusive
about it — is silent for 92% of the time, in the same 15.8 s pattern as the
DDJ, with its bursts ending at each teardown.** So the earlier "60 s of
continuous clean music at the laptop monitor" was a recording of a *different
configuration* (PC output alone), not a contradiction. Phase 23 stands: the
application silences everything.

### 25b — THE ENGINE RATE. rekordbox is playing at one twentieth of real time.

The instrument that should have existed from the beginning: rekordbox keeps the
playing track's file open, and the kernel reports how far it has read
(`/proc/<pid>/fdinfo/<fd>` → `pos`). A deck playing in real time consumes the
file at its bitrate. `bin/enginerate.sh` samples that against the file's own
bitrate from `ffprobe`, alongside the DDJ substream state, and reports the
engine's speed as a fraction of real time. No OCR, no compositor, no recording,
no human, and a paused deck is explicitly refused rather than reported as 0.00x.

**One variable — the PC MASTER OUT toggle in the toolbar — measured back to back
on the same launch, same track, same 40 s window:**

| run | PC MASTER OUT | file read rate | engine rate | DDJ stream rebuilds |
|---|---|---|---|---|
| `20260817T172004-enginerate` | **on** | 2,113 B/s | **0.05x** | 5 |
| `20260817T172154-enginerate` | **off** | 40,154 B/s | **1.00x** | 0 |

Real-time rate for the file is 40,017 B/s. With PC MASTER OUT off the engine
tracks it to within 0.3%; with it on the engine does **one twentieth** of the
work and the stream is torn down and rebuilt five times.

### And the decisive detail: the file is read ONLY during the teardown

In the stalled arm the position is frozen for fourteen seconds at a time and
then jumps by exactly 48 KiB — and the sample where it jumps is the sample where
the DDJ substream reads `closed`:

    30.5   2727936        0    0.00x   RUNNING
    31.5   2777088    48250    1.21x   closed      <- 48 KiB, exactly at teardown
    32.5   2777088        0    0.00x   RUNNING

48 KiB of a 320 kbit/s file is ~1.2 s of audio, which is the length of the audio
burst measured at the wire, at the monitor and in the WASAPI buffers.

**So rekordbox is not "writing silence into a running stream". Its transport is
stopped.** It decodes and plays exactly one buffer per stream rebuild, and the
rebuild is what unblocks it. Everything measured in phases 19-24 — silence at
the wire, zeros in the buffers, a burst that ends at each teardown, threads that
are equally busy in both phases — is the shape of a transport that is waiting,
being kicked once every 15.8 s by the watchdog that rebuilds the stream.

### What this rules in and out

- **It is not the buffer contract.** Four buffer arms were measured in phase 23
  against a fault that is not in the buffer path at all.
- **It is not the exclusive device.** The shared PC client stalls in exactly the
  same pattern, and with PC MASTER OUT off the *exclusive* DDJ client alone runs
  at 1.00x with zero rebuilds.
- **It is the second output stream.** Adding it takes the engine from 1.00x to
  0.05x. Nothing else changed between the two runs.

### The oracle this hands the next session

`bin/enginerate.sh` is a 40-second, unattended, numeric verdict on the actual
fault rather than on a symptom of it: **1.00x = fixed, 0.05x = broken, 0.00x =
refused as "paused or dead"**. Every candidate fix from here is scored with it.

### Next, in order

1. **Which second stream?** Repeat arm A with the main output on the PC device
   (shared + shared) rather than the DDJ (exclusive + shared). If it still
   stalls, two streams are enough on their own; if it runs, mixing an exclusive
   stream with a shared one is the trigger.
2. **Diff the threads between the two arms**, not between phases of one arm.
   `bin/threadscope.py` refuted render-blocking by comparing burst against
   silence inside the broken arm, where everything is ~1.1. Comparing *working*
   against *stalled* is a far stronger contrast, and it should name the thread
   that stops.
3. Then instrument what the second client is told: `GetCurrentPadding` per
   client is the one number the engine must read to decide it may produce, and
   it has never been logged for the shared client.

### Phase 25c — WINE IS EXONERATED FOR THE TWO-CLIENT CASE, without rekordbox

`upstream/dualclient.c` (+ `build-dualclient.sh`) reproduces the *configuration*
rather than the application: two event-driven render clients, one EXCLUSIVE on
the DDJ-400 and one SHARED on the default endpoint, each with its own feeder
thread that waits on its stream event, consults `GetCurrentPadding`, calls
`GetBuffer`/`ReleaseBuffer`, and counts everything — events, timeouts, refusals
and **frames actually written against real time**, because a client can be
signalled briskly and still write nothing, and this project has already
announced one fix about a stream that was dead.

Three arms, 20 s each, rekordbox not running:

| arm | client | events | timeouts | GetBuffer fail | frames written |
|---|---|---|---|---|---|
| `excl` alone | EXCL/DDJ | 2002 (100/s) | 0 | 0 | **100% of real time** |
| `shared` alone | SHARED/PC | 1752 (87/s) | 0 | 0 | **100% of real time** |
| **`both`** | EXCL/DDJ | 2003 (100/s) | 0 | 0 | **100% of real time** |
| | SHARED/PC | 1753 (87/s) | 0 | 0 | **100% of real time** |

**Wine feeds an exclusive and a shared event-driven client simultaneously,
perfectly, for as long as you ask it to.** The event contract is honoured, no
client is starved, nothing is refused. The fault does **not** reproduce without
rekordbox.

So the stall is rekordbox's own, and the Wine-shaped question is no longer "does
Wine keep the streams fed" — measured, it does — but "what does rekordbox ask
Wine for in this configuration that it does not ask for in the other one".

Two known differences between the reproducer and rekordbox, both untested:

- **Buffer size.** The reproducer took the device's default period (10 ms →
  a 1764-frame exclusive buffer). rekordbox's setting is `AudioBufferSize=256`
  and the stream Wine gives it is ~170 frames, ~4 ms.
- **Sample rate on the shared client.** The reproducer used the mix format,
  48000 Hz. rekordbox forces its PC stream to 44100 Hz — `pactl` shows its
  client as `float32le 2ch 44100Hz` — so it is asking Wine's shared mixer to
  resample, and the two streams then run at different rates from one engine.

Those are the next two arms to add to `dualclient.c`.

### Phase 25d — the engine renders a FIXED NUMBER OF BUFFERS per cycle, whatever their size

With PC MASTER OUT on, `bin/enginerate.sh` scored the engine at four buffer
sizes (Preferences → Audio → Buffer size; the setting is verified at the device
by `/proc/asound/card1/pcm0p/sub0/hw_params` → `period_size`, not by reading the
dialog):

| buffer | ALSA period | engine rate | frames rendered per second | buffers per second |
|---|---|---|---|---|
| 256 (5.8 ms) | 256 | 0.05x | 2,205 | 8.6 |
| 512 | 512 | 0.11x | 4,851 | 9.5 |
| 1024 | 1024 | 0.22x | 9,702 | 9.5 |
| 2048 (46 ms) | 2048 | 0.40x | 17,640 | 8.6 |

**The engine rate is exactly proportional to the buffer size, so the number of
buffers it completes per second is constant at ~9.** Eight times the buffer,
eight times the audio, same number of callbacks. Whatever gates the engine
counts *buffers*, not samples and not seconds.

The per-second trace at 2048 shows it is not an even 9 Hz trickle either — the
engine runs at **0.90-1.21x for several seconds**, then stalls dead for ~12 s,
then resumes:

     3.0   1806336  36277  0.91x RUNNING     <- real time
     8.1   2015232  48411  1.21x RUNNING
     9.1   2015232      0  0.00x closed      <- teardown
    10.2   2052096  36252  0.91x RUNNING
    11.2   2052096      0  0.00x RUNNING     <- and then nothing for 12 s
    22.4   2088960  36237  0.91x RUNNING

So per cycle it renders a burst of ~136-150 buffers at full speed and then
stops. That is the signature of a **fixed-depth queue that fills and is never
drained**, not of a slow producer: the engine produces at full speed until
something is full, and only the stream rebuild empties it.

**A bigger buffer is not a workaround.** 0.40x is still broken audio; it just
moves more samples per stall.

### Phase 25e — things that are NOT the trigger, each with a run

- **The 44100/48000 rate difference.** Forcing PipeWire's graph to 44100
  (`pw-metadata -n settings 0 clock.force-rate 44100`) left the engine at 0.11x,
  exactly where the same buffer size scored before. *(Caveat, recorded because
  it matters: the speaker sink stayed at 48000 in `pactl`, so this forced the
  graph rate and not the endpoint. It is a weak refutation, not a strong one.)*
- **Wine's WASAPI service.** Six `dualclient` arms — exclusive alone, shared
  alone, both, both with the minimum period, both with the shared client forced
  to 44100 with AUTOCONVERTPCM, and both asking for the whole buffer on every
  event — all wrote **100% of real time** with zero timeouts and zero refusals.
- **The audio thread being blocked.** Corrected: `bin/threaddiff.py` (fixed, see
  below) shows rekordbox's per-cycle audio thread burning **62% of a core in the
  broken arm and 66% in the healthy one**. It is spinning, not parked.

**An instrument fault, caught and owned.** The first version of `threaddiff.py`
computed each thread's CPU as (jiffies at the end - jiffies at the start), which
silently reports **0%** for every thread that did not exist at the start. In this
configuration the audio threads are destroyed and recreated every 15.8 s, so
that is precisely every thread that matters, and the script duly reported "no
thread does any audio work when the fault is present" — a finding I stated
before an `strace` of one of those very threads showed it issuing **36,000
ioctls a second**. Each thread is now charged over its own observed lifetime.
Same class as the four-slot table and the read-before-write probe: *a probe that
cannot see the interesting object reads exactly like a system where nothing is
happening.*

### What the next session should do

The fault is in rekordbox's own two-output path, and the Wine layer under it is
measured clean. The open question is what fills up. Ranked:

1. **Name the queue.** ~9 buffers/s, ~140 buffers per cycle, drained only by a
   stream rebuild. If that count is the depth of rekordbox's PC MASTER OUT FIFO,
   the consumer side of that FIFO is the thing that never runs.
2. **Instrument per client, not per process.** The existing render probe
   (`debug/mmdevapi-render-probe.c.txt`) already separates the two clients; run
   it in *both* arms and compare `ReleaseBuffer` rates per client. Phase 23 ran
   it only in the broken arm and read "both clients silent" as a property of the
   application rather than of the configuration.
3. **The 5-second thread.** Every cycle creates 8 threads that live 14.6 s, plus
   exactly one more, born ~1.4 s later, that lives **5.0 s** to the tenth. A
   five-second timeout in an audio path is worth naming.

### Phase 25f — per-client accounting: BOTH clients are served at real time in both arms

`debug/mmdevapi-clients-probe.diff.txt` (RBW-CLIENTS) counts, per client and
labelled with the device name, what the application is told, asks for and
writes. Same launch, same track, one toggle.

**Healthy — PC MASTER OUT off, one client, engine 0.98x:**

    dev=plughw:1,0  pad 313,346 calls last=471
                    GetBuffer ok=43  fail=163,286  hr=88890006  askmax=1024
                    Release 43 calls  44,032 frames  silent=0 nonzero=43   (signal in every buffer)

**Broken — PC MASTER OUT on, two clients, engine 0.05x:**

    dev=plughw:1,0  pad 322,001 calls last=760
                    GetBuffer ok=43  fail=157,221  hr=88890006  askmax=1024
                    Release 43 calls  44,032 frames  silent=0 nonzero=0     (all zeros)
    dev=default     pad 350 calls last=853
                    GetBuffer ok=262 fail=0                      askmax=256
                    Release 262 calls 44,453 frames silent=0 nonzero=0     (all zeros)

Read those together and the WASAPI boundary is completely explained:

- **Both clients are written at exactly real time in both arms** — 44,032 and
  44,453 frames per second against 44,100. Neither device thread is starved,
  blocked or behind. The only difference between a working DJ setup and a broken
  one is whether those frames contain **signal or zeros**.
- **The engine is upstream of all of this.** Nothing in Wine's buffer contract
  can make the application put audio into buffers it is already being handed on
  time. This closes out the buffer-accounting line of work for good: the four
  arms of phase 23, RBW-RING, and the deeper-ring idea were all aimed at a layer
  that is measurably not the constraint.
- **The refusal storm is real, is Wine's, and is NOT the trigger.** rekordbox
  spins ~160,000 `AUDCLNT_E_BUFFER_TOO_LARGE` refusals a second on the exclusive
  client asking for its full 1024-frame buffer — **in the healthy arm too**,
  where playback is perfect. It is a genuine inefficiency worth fixing on its own
  merits (that is roughly a whole core of wasted work, and it is why
  `GetCurrentPadding` is called 320,000 times a second), but it cannot be the
  cause of a fault that appears only when a second device is added.

### Phase 25g — leads killed, so nobody re-chases them

- **PipeWire / the `default` endpoint is not the trigger.** rekordbox stores its
  PC MASTER OUT target in a plain text file,
  `AppData/Roaming/Pioneer/rekordbox6/pcmasterout_device_v2.txt`. Repointing it
  from `Speakers (Out: default)` to the raw laptop card
  `Speakers (Out: sof-hda-dsp - )` — a completely different code path, direct
  ALSA instead of PipeWire — gave **0.04x**, unchanged. *Any* second output
  stalls the engine.
  *(That file is also the cheapest way to change the PC MASTER OUT device
  without driving the UI.)*
- **`QueryThreadCycleTime` is a Wine stub that leaves its output uninitialised**
  (`dlls/kernelbase/thread.c`: FIXME, `SetLastError`, `return FALSE`, `*cycle`
  never written) and it looked like a perfect candidate — DJ engines use exactly
  that call for render-load protection. It is **not rekordbox**: the only binary
  in the whole installation that references it is
  `rekordboxAgent-win32-x64/rekordboxAgent.exe`, i.e. Chromium's scheduler in
  the tray agent. Dead end, and worth recording as such.
  *(Note the counting trap: that FIXME is behind a `static int once` guard, so
  its frequency cannot be read off the log — the same trap that once made a
  million `WaitForVBlank` calls look like one.)*

### Phase 25h — the user's track-load clue, measured: 0.9 s against 5.8 s

The report was *"a significant delay loading a track, and only when the DDJ-400
is the selected audio device"*. It has been unexplained since it was made, and
it was never timed. `bin/loadtime.sh` times it from the release of the drag to
the moment rekordbox **opens the audio file**, read from `/proc/<pid>/fd` — the
kernel's own record, which cannot be fooled by a UI that has drawn the title but
not finished loading.

Same launch, same tracks, one toggle:

| arm | load 1 | load 2 | earlier pair |
|---|---|---|---|
| PC MASTER OUT **off** | **0.9 s** | **0.9 s** | 0.2 s, 0.2 s |
| PC MASTER OUT **on** | **2.9 s** | **5.8 s** | 7.9 s, 2.3 s |

**Three to nine times slower, and it is the same switch as the audio fault.**
The variance in the broken arm is itself consistent with the mechanism: the
engine gets ~140 buffers per 15.8 s cycle, so how long a load takes depends on
where in the cycle it starts.

**A correction to the attribution, gently:** the delay is not caused by the
DDJ-400 being the selected device — it is caused by the second output stream.
The two are entangled from the user's side, because PC MASTER OUT is only
offered when a DJ device is selected. With the DDJ selected and PC MASTER OUT
off, loading is fast.

So the load delay is not a separate fault: it is the same stalled engine seen
through a different feature. That is one fewer open thread, and it means fixing
the engine stall fixes both.

**Instrument note.** The first version watched the *count* of open files under
`~/Music`, then the bare fd numbers. Both miss a load that reuses an fd number,
and both then report "not opened within 30 s" about a track that loaded
perfectly — a false failure, twice, before it was changed to fd:inode pairs.

### Phase 25i — the refusal storm is the application polling, not Wine misbehaving

Phase 20 called the ~160,000 `AUDCLNT_E_BUFFER_TOO_LARGE` refusals a second "a
real Wine bug worth fixing on its own merits". Tonight's reproducer sharpens
that, and the sharpening matters because it removes a candidate upstream report.

`dualclient.exe both full` asks for **the whole buffer on every event**, exactly
as rekordbox does — and gets **2003 successes and 0 failures in 20 s**. The
difference is not what is asked for, it is *when*: the reproducer waits on the
stream event and then asks once; rekordbox asks in a tight loop without waiting,
so it is refused every time until a period happens to be free. Wine is answering
correctly, and it serves the client at exactly real time either way (43
`ReleaseBuffer` calls a second, 44,032 frames).

What remains of the original observation is a narrower accounting point:
`held_frames` counts frames Wine has already copied into ALSA's own buffer, so a
request can be refused while the mmdevapi ring is in fact empty
(`held == in_alsa` on every sample, phase 20). Fixing that would let the polling
succeed sooner. It is a defensible upstream cleanup; it is **not** a user-visible
defect, and no measurement here would move if it were fixed.

**So there is no Wine bug to file from this line of work.** Recording that
explicitly, because "158,000 wasted refusals a second" reads like one.

## Phase 26 (2026-08-18) — what rekordbox ASKS FOR, side by side, and the buffer axis closed

### The instrument that made this readable

`WINEDEBUG=+mmdevapi` is unusable on this application — 200,000 lines a second,
797 MB in 45 s, and the pipe backpressure throttles the app. But **three calls
account for all of it**: `GetCurrentPadding`, `render_GetBuffer` and
`render_ReleaseBuffer`, which RBW-CLIENTS already counts. Silencing just those
three TRACEs (`RBW-QUIET`, in `debug/mmdevapi-clients-probe.diff.txt`) drops the
channel to **2 KB/s** — a factor of 8,000 — and turns it into a readable API
transcript with no measurable perturbation.

### The two arms, same launch, one toggle

**PC MASTER OUT off, 60 s: ZERO device-layer calls.** No enumeration, no
`Activate`, no `Initialize`, no `IsFormatSupported`, no `Start`, no `Stop`. The
app sets its stream up once and streams.

**PC MASTER OUT on, 90 s:**

    MMDevEnum_EnumAudioEndpoints      138        client_Initialize    12
    MMDevEnum_GetDefaultAudioEndpoint 252        client_Start         12
    client_IsFormatSupported          210        client_Stop          36
    MMDevice_Activate                  48        client_SetEventHandle 12
    MMCF_CreateInstance / DllGetClassObject 12   client_GetService    24

**rekordbox rebuilds its entire audio subsystem every 14.7 s** — it creates a
fresh `MMDeviceEnumerator` through `CoCreateInstance`, enumerates all eleven
endpoints reading `PKEY_Device_FriendlyName` off each, re-resolves the default
render *and capture* endpoints, re-probes formats ~17 times, then `Activate` →
`Initialize` → `SetEventHandle` → `GetService` → `Start` on both clients. One
cycle, timed from the log:

    t=0.00   enumerate, then Stop both clients
    t=1.08   Initialize PC (shared),  t=1.10 Start
    t=1.11   Initialize DDJ (exclusive), t=1.11 Start
    t=15.84  enumerate again, Stop both        <- 14.7 s of running

**No call fails anywhere in that sequence.** The teardown is clean and
unprovoked: `Stop`, `UnregisterAudioSessionNotification`, `Release`. Nothing in
the Wine layer refuses, errors or warns.

### What each client actually asks for

    PC  : Initialize(SHARED,    AUTOCONVERTPCM|SRC_DEFAULT_QUALITY|EVENTCALLBACK,
                     duration 10 ms, period 0, 44100 Hz 2ch float)
          -> Wine adjust_timing: period 10 ms, duration widened to 30 ms
          -> GetBufferSize 1323 frames, GetStreamLatency 23.99 ms
    DDJ : Initialize(EXCLUSIVE, EVENTCALLBACK,
                     duration = period = 5.805 ms, 44100 Hz 4ch PCM)
          -> Wine (our patch 0002) widens to 4 periods
          -> GetBufferSize 1024 frames

So the app asks for **256 frames** on the controller and **441** on the PC, and
Wine hands it **1024** and **1323**. That looked like the answer.

### It is not. The buffer axis, measured

`RBW_EXCL_PERIODS` / `RBW_SHARED_PERIODS` make both inflation factors settable at
run time from one binary (`bin/periodmatrix.sh` runs an arm and scores it):

| exclusive | DDJ buffer | shared | PC buffer | engine rate | rebuilds / 40 s |
|---|---|---|---|---|---|
| 4 (shipping) | 1024 | 3 (shipping) | 1323 | **0.05x** | 6 |
| 4 | 1024 | **1** | **441** (what it asked for) | **0.05x** | 4 |
| **2** | **512** | 3 | 1323 | **0.13x** | 8 |
| **1** | **256** (what it asked for) | 3 | 1323 | **0.12x** | 33 (churning) |

Giving the application exactly the buffer it asked for, on either device or
both, **does not fix it**. Halving the exclusive buffer roughly doubles the
engine rate and quadruples the rebuild rate; going to one period collapses into
a rebuild every 1.2 s. Nothing approaches 1.00x.

**So the buffer geometry is not the trigger** — it modulates the symptom.
Combined with phase 25f (both clients served at real time, in both arms) and
phase 25c (Wine feeds two clients perfectly without rekordbox), the entire
buffer/period axis is now closed.

### Also eliminated here

- **The device list is stable.** Eleven endpoint IDs, identical across all 138
  enumerations in 90 s. The app is not seeing a changing device list.
- **Session notifications are not polled.** `IAudioSessionControl::GetState` is
  never called. The app registers a notification callback — which Wine
  **stubs** — on both clients, and never asks again. That remains a candidate:
  Wine delivers no session events at all.
- **No IAudioClock, IAudioClock2 or IAudioClockAdjustment calls exist** in the
  entire transcript, so the app is not slaving one device's clock to the other
  through any API Wine could answer wrongly.

## Phase 27 (2026-08-18) — FOUND: it is the EVENT-CALLBACK path. `WasapiPolling=1` clears it.

rekordbox keeps its own WASAPI tuning in `rekordbox3.settings`:

    WasapiExclusive 1   WasapiPolling 0   WasapiTimeoutCount 3
    WasapiThresholdCount 1   WasapiBufferThreshold 2

Setting **`WasapiPolling` to 1** — which makes the application poll
`GetCurrentPadding` instead of waiting on the stream event — changes the fault
qualitatively. Same launch conditions, PC MASTER OUT **on**, track playing,
measured with `bin/dualsink.py` (DDJ substream and the laptop monitor on one
clock):

| arm | audible PC audio | DDJ stream rebuilds |
|---|---|---|
| `WasapiPolling=0` (shipping) | **8%**, in ~1 s bursts locked to each teardown | 3 per 40 s |
| **`WasapiPolling=1`** | **91%**, continuous music | **1 per 50 s** |

    polling=1:  ##################################################....#..............#############...
                (each # is 250 ms of audible audio at the laptop monitor)

The 15.8 s destroy-and-rebuild cycle **stops**. In one 40 s window there were
zero PCM state transitions at all; across the runs it drops from three per 40 s
to about one per 50 s.

### What that pins down

With polling, the streams are no longer opened with
`AUDCLNT_STREAMFLAGS_EVENTCALLBACK` — the exclusive stream visibly takes Wine's
non-event path instead (its buffer becomes 8 periods, 2048 frames, rather than
the 4-period 1024 of the event path). So:

**The stall lives in the event-callback path, and only when two event-driven
streams exist at once.** That is consistent with everything measured before it
and now explains why nothing else moved the number:

- it is not the buffer geometry (phase 26) — polling changes *when* the client
  is woken, not how much room it has;
- it is not exclusivity (phase 26, `RBW_FORCE_SHARED`) — polling helps with the
  exclusive stream still in place;
- it is not the session-notification stub or MMCSS priority (phase 26);
- and it is not Wine's ability to feed two clients (phase 25c) — `dualclient`
  waits on **one** event per thread and is fed perfectly.

The obvious mechanism to test next is Wine's **event gate**: `winealsa`'s
`alsa_write_data` signals the client event only when a **full period** is free
(the `RBW-EVENT3` condition in patch 0003). A client waiting on two such events —
particularly with `WaitForMultipleObjects(WAIT_ALL)` — stalls whenever the two
conditions are rarely true at the same moment, which is exactly the shape here.

### Status of `WasapiPolling=1` as a user-facing workaround

**Promising, not yet shipped.** It must still be measured in the single-device
configuration (PC MASTER OUT off) before it can be recommended, because polling
costs CPU and this project has shipped an unmeasured audio change once already.

### Phase 27b — CORRECTION: `WasapiPolling=1` improves it about six-fold. It is NOT a fix.

The phase 27 headline above was written on **one** `dualsink` run (91% audible,
continuous music). Repeating it does not hold up. Same build, same track, PC
MASTER OUT on, `WasapiPolling=1`, engine speed read from the deck's own clock
(`bin/deckrate.sh`, which works where the file-offset oracle goes VOID because
polling mode reads the whole track into memory in about thirty seconds):

    buffer 256 :  1.00x, 0.29x, 0.30x, 0.32x, 0.39x, 0.32x      <- bimodal, mostly ~0.3x
    buffer 1024:  0.25x, 0.25x, 0.25x                            <- consistent, no better

So the honest numbers are:

| arm | engine speed | stream rebuilds |
|---|---|---|
| `WasapiPolling=0` (shipping) | 0.03-0.05x | every 15.8 s |
| `WasapiPolling=1` | **~0.3x**, occasionally 1.00x for a whole window | mostly none |
| either, PC MASTER OUT off | **1.00x** | none |

**A six-fold improvement and the destroy-rebuild cycle largely stops — but it
still plays at a third of real time, so it is not usable and must not be shipped
as a workaround.** It does confirm the direction: the event-callback path is
where the fault lives, because taking the application off it changes the
behaviour qualitatively.

`WasapiPolling=1` was also measured in the **single-device** configuration, and
it does not regress it: 1.00x, 28 of 28 samples, same as shipping. That matters
because it means the setting is safe to experiment with; it simply is not a cure.

**The lesson, again, and it is the same one:** the first measurement said "fixed"
and I wrote it up as FOUND. Four repeats said ~0.3x. Nothing was shipped on the
strength of the first one, but the write-up existed for twenty minutes and would
have gone into a handoff. *A fix is not a fix until it has been measured more
than once.*

### Where phase 27 leaves the investigation, honestly

Narrowed, not solved:

- the fault needs **two output streams** and the **event-callback path**;
- it is **not** buffer geometry, exclusivity, session notifications, MMCSS
  priority, PipeWire, the device list, CPU contention, or Wine's ability to feed
  two event-driven clients (all measured);
- Wine's event **cadence** is poor — the DDJ's 5.805 ms period is signalled every
  **8.3 ms** on average with a **17.5 ms** worst case — but that is **identical in
  the healthy single-device arm**, which plays perfectly at 1.00x, so it is not
  the differentiator either. It is worth fixing on its own merits: Wine drives
  the event from a software timer per stream (`alsa_timer_loop`,
  `NtDelayExecution`) rather than from the sound card, and it is 43% slow.

## Phase 28 (2026-08-18) — inside the application: the decoder is never asked

The Wine API surface is exhausted, so this phase followed the work *inside*
rekordbox, by tracing which thread wakes which.

### The decoder thread is parked, not slow

The thread that reads the track file was identified by `strace`-ing reads on the
open mp3 descriptor. In the broken arm it does 12,288-byte reads about three
times per **cycle** — and between them:

    40 s of sampling at 4 Hz: 160 of 160 samples in futex_do_wait, 0 CPU jiffies

**It is not working slowly. It is asleep, waiting to be told to decode.** So the
gate is upstream of the decoder.

### The wake chain, and when it fires

`strace -f -tt -e trace=futex` on the whole process, then following the futex
addresses:

    broken:  3512081 -> 3512084 -> 3507101 -> decoder      38 wakes, ONE burst in 22 s
    healthy: 3513354 -> 3513500 -> decoder                 573 wakes in 15 s, continuous

Same shape, utterly different rate. And the middle link differs in kind: in the
healthy arm it blocks with `timeout=NULL` and is woken 18 times; in the broken
arm the equivalent thread sits in a **5 ms polling loop** (1,411 timed waits, all
`ETIMEDOUT`) and decides "no work" almost every time.

**When the one burst happens is the sharpest fact of the phase.** Sampling the
DDJ substream state and the futex trace on the same wall clock:

    10:43:16.505  DDJ RUNNING          <- stream starts
    ...14.5 s of nothing...
    10:43:30.998  decode burst (39 wakes in 4 ms)
    10:43:31.068  DDJ closed           <- teardown, 66 ms later
    10:43:32.322  DDJ RUNNING          <- restart

**The engine decodes 66 milliseconds before the teardown, not after the start.**
So the single second of audio per cycle is not a prefill that then starves — it
is produced as part of the reset. Between one stream starting and the next
teardown, the engine asks for **nothing at all**.

### What that means, stated carefully

The application renders 44,032 frames per second into the exclusive client the
whole time (phase 25f) — at exactly real time, all zeros. Its transport does not
advance and its decoder is not asked. So the engine is **running and
deliberately emitting silence**, in a state it never leaves until a watchdog
resets the device.

### Two more eliminations from this phase

- **Wine does not buckle under rekordbox's access pattern.** `dualclient spin`
  reproduces the real thing's impatience — no event wait, poll padding, hammer
  `GetBuffer` — and reaches **22 million refusals a second**. Alone or in pairs,
  both clients still wrote **100% of real time**. One spinning client does not
  starve another.
- **Padding is load-bearing, and it is not wrong in a way that helps.**
  `GetCurrentPadding` is the only progress number the application reads (320,000
  calls a second on the exclusive client; it never calls `IAudioClock`), and
  Wine computes it from `held_frames`, refreshed once per timer tick. Replacing
  it with an exact value from the ALSA hardware pointer (`snd_pcm_delay` plus
  what is still in Wine's ring) **stopped playback altogether** — the deck would
  not start at all, 0 of 27 samples. That is a strong statement about how
  sensitive this application is to padding semantics, and a warning against
  "improving" that number casually. Reverted.

### An instrument fault caught mid-phase

`bin/deckrate.sh` and `bin/deckadvancing.sh` capture with `spectacle -f`, which
photographs the **whole screen**. With a terminal in front they were measuring
the terminal, and duly reported "0 of 27 samples advanced — THE ENGINE IS
STALLED" about a run whose deck state was unknown. Both now raise the rekordbox
window before capturing. *Measuring the wrong object is this project's oldest
recurring fault, and it just recurred.*

### Phase 28b — each device has its own writer thread, and both write at real time

Extending the per-client probe with the **writing thread id** and the block size
(`RBW-WHO`), broken arm, both clients:

    dev=default     writer tid 07c0 x254/s   blocks 1..256 frames   44,363 frames/s   all zeros
    dev=plughw:1,0  writer tid 0788 x43/s    blocks 1024 frames     44,032 frames/s   all zeros

**Two independent writer threads, one per device — there is no inline
mirroring**, so a stall in one device's callback cannot be blocking the other
directly. The PC path writes small variable blocks as fast as data appears (the
signature of a thread draining a FIFO); the DDJ path writes fixed 1024-frame
blocks at the buffer rate. Both hit real time to within 0.6%.

So at the boundary everything is healthy and symmetric. The only thing wrong is
that the frames contain silence, and the decoder that would fill them is asleep
(phase 28).

**Another latch fault in my own probe, caught by its own output.** The first
version latched the first two writer threads it ever saw and counted matches
against them — but rekordbox recreates its audio threads every cycle, so after
the first rebuild every writer matched neither and both counters read zero while
the block-size fields kept updating. That mismatch is what gave it away. The
identities are now reset with the counters.

## Phase 29 (2026-08-18) — 7.2.18 is identical, and the engine is gated on the second stream EXISTING

The user updated to **rekordbox 7.2.18** (7.2.17 removed) and pointed out the
decisive fact that **PC MASTER OUT works on a real Windows machine** — so this is
an interop difference, not an application bug. The harness is now
version-agnostic (`bin/rbexe.sh`; thirteen scripts had 7.2.17 hardcoded and
would have silently launched nothing).

### 7.2.18 changes nothing

| arm | 7.2.17 | 7.2.18 |
|---|---|---|
| PC MASTER OUT off | 1.00x, 0 rebuilds | **0.99x, 0 rebuilds** |
| PC MASTER OUT on | 0.05x, 6 rebuilds / 40 s | **0.05x, 6 rebuilds / 40 s** |

### The interop candidates, each measured

- **rekordbox detects Wine.** `wine_get_version` is present in `rekordbox.exe`
  itself (and in `tensorflow_cc.dll`). wine-staging can hide those exports;
  `upstream/winedetect.c` confirms the switch works (`wine_get_version`,
  `wine_get_build_id`, `wine_get_host_version` all become hidden — note
  `wine_server_call` stays visible). With `HideWineExports=Y`: **0.05x on, 0.98x
  off. No change.** The application is not branching on that check.
- **Wine's timer granularity is fine.** Measured from the app's own futex waits:
  a requested 5 ms sleep takes 5.07 ms at the median, 6.56 ms worst; 2 ms takes
  2.07 ms. Nothing is being rounded up.
- **Wine's timer loop is exact.** Instrumented inside `alsa_timer_loop`: body
  **17 µs**, sleep 5787 µs, **total 5804 µs against a 5805 µs period**. The loop
  is not the source of any lateness — which corrects the phase-27 framing of the
  cadence as "43% slow timer".
- **The event cadence CAN be made exact, and it does not help.** The 8.3 ms mean
  for a 5.805 ms period comes from the *gate*: the event is skipped whenever the
  ring is full, which is about a third of ticks. `RBW_EVENT_GATE=always` signals
  on every period boundary, the way hardware does:

      DDJ  100 events/s -> 173 events/s   mean 8300 us -> 5805 us  (nominal 5805)
      PC                                  mean          10000 us  (nominal 10000)

  **Engine: still 0.07x.** Exact, jitter-free, Windows-shaped callbacks change
  nothing.

### The discriminator: make the second device perfect

`RBW_NULLSINK=1` turns the shared (PC MASTER OUT) client into an infinitely fast
sink inside mmdevapi — `GetCurrentPadding` always 0, `GetBuffer` always succeeds
into scratch memory, `ReleaseBuffer` costs nothing, the driver never touched.
The exclusive DDJ client is untouched.

**Engine: 0.07x, four rebuilds in 30 s. Unchanged.**

**So the engine is not gated on how the second stream behaves — it is gated on
the second stream existing.** A second output device that is flawless, instant
and never busy stalls it exactly as much as a real one.

### What that means for the direction of this work

**No change to Wine's audio path can fix PC MASTER OUT.** Buffers, share mode,
event cadence, padding, session notifications, thread priority, the backend
device, and now the second stream's entire behaviour have all been substituted
and the result is the same. The application reconfigures itself into a
two-device topology and that topology does not run here.

The remaining difference from Windows is therefore **above the audio path**, in
whatever the engine consults when it builds that topology. Nothing in the
mmdevapi transcript fails, so the next place to look is outside it entirely.
