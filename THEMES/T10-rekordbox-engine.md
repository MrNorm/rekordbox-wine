# T10 — inside rekordbox's audio engine: what the machine code says

**Opened 2026-08-18.** Static analysis of `rekordbox.exe` (7.2.18, 100 MB, PE32+,
no symbols), begun after the user pointed out that PC MASTER OUT works on a real
Windows machine and that boundary probing had stopped paying.

**Scope.** This is interoperability analysis — why an audio path behaves
differently under Wine. It touches no activation, licensing or protection code.
If the trail reaches protection logic, that is the project's NO-GO line.

## Method: anchors, not a decompilation marathon

A 100 MB stripped C++ binary is hopeless to read cold. It is not hopeless when
the application's **own setting names are in it**, because a string reference
leads straight to the code that uses the setting. Three small tools do the work
without waiting on a full analysis pass:

| tool | what it does |
|---|---|
| `bin/pexref.py` | every RIP-relative reference to a string, plus absolute pointers to it, by arithmetic sweep with numpy (54 MB `.text` in under a second) |
| `bin/pexrefva.py` | the same for an arbitrary VA range — "who reads this global" |
| `bin/pefunc.py` | exact function bounds from the PE's `.pdata` RUNTIME_FUNCTION table — instant, no analysis needed |

Ghidra 12.1.2 is installed and its headless analysis of the binary is a separate,
much slower track; everything below came from `objdump` plus those three tools.

## The settings map

Each setting has a registration stub around `0x140b315a0..0x140b316e2` of the form
`lea <name>,%rdx; lea <object>,%rcx; call 0x1429737d0`, and the settings loader
(two copies, `0x141cc4780` and `0x141cefd60`) reads each one and stores it in a
global:

| setting | name object | **runtime value** |
|---|---|---|
| `WasapiPolling` | 0x145e35f58 | **byte at 0x145ed5d7d** |
| `WasapiTimeoutCount` | 0x145e35070 | **int at 0x145b52218** |
| `WasapiBufferThreshold` (by use) | — | **int at 0x145b52210** |
| `WasapiExclusive` (by use) | — | byte at 0x145b3d898 |

## The audio device wait loop — `0x140fe7b56 .. 0x140fe802a`

This is the function that decides when and how much to write. Its imports
resolve to `WaitForSingleObject` (0x143374568) and `Sleep` (0x143374788).

**1. `WasapiPolling` picks the wait primitive.**

    cmpb $0x0, 0x145ed5d7d      ; WasapiPolling
    je   <event path>           ; 0 -> WaitForSingleObject
    ...                         ; 1 -> Sleep

**2. The "event" wait is a spin, not a block.**

    mov  0x145edb258,%rcx       ; a PROCESS-GLOBAL event handle
    setl %al                    ; timeout = 0 or 1
    mov  %eax,%edx
    call *WaitForSingleObject   ; WaitForSingleObject(h, 0 or 1 ms)

So even in event mode rekordbox never blocks on the stream event for a period —
it polls with a 0 or 1 ms timeout. That is the 37,300 ioctl/s NTSYNC storm this
project measured from the outside two sessions ago.

**3. The handle is a single global, created once at startup.**

    0x1400834b0:  CreateEventW(NULL, FALSE, FALSE, NULL)   ; auto-reset, unnamed
                  mov %rax, 0x145edb258

One process-wide auto-reset event, read by thirteen code sites across the audio
paths. **Every device thread waits on the same object**, and an auto-reset event
releases exactly one waiter per signal — so with two output devices the two
threads share, and steal, one signal stream. (Note this is *not* the WASAPI
stream event: those are per-client, and Wine sees two distinct handles passed to
`SetEventHandle`.)

**4. In EXCLUSIVE + EVENT mode the app asks for the whole buffer, unconditionally.**

    cmpl $0x1,0x18(%rbx)        ; exclusive?
    je   <0x140fe7d23>
    cmp  %dil,0x145ed5d7d       ; WasapiPolling == 0 ?
    je   <0x140fe7d82>
    0x140fe7d82: mov 0xa8(%rbx),%r14d    ; frames = bufferSize   <-- no padding consulted

That single instruction explains the whole `AUDCLNT_E_BUFFER_TOO_LARGE` storm:
the client asks for `GetBufferSize()` frames every time, which Wine can only
grant when its ring is empty. **It is the documented exclusive-event contract,
and the app is entitled to it.**

**5. In POLLING mode it consults padding instead.**

    call *0x30(%rax)                     ; GetCurrentPadding
    mov  0x145b52210,%edx                ; WasapiBufferThreshold
    limit = min(bufferSize, period * threshold)
    if (padding > limit) -> loop again
    else frames = bufferSize - padding

That is why `WasapiPolling=1` changes the behaviour qualitatively: it stops
asking for the whole buffer.

**6. The retry deadline — the loop the user asked about.**

Computed in the open/init function `0x140fe8f60`:

    movsd 0xc0(%rsi),%xmm2      ; a duration, microseconds
    movd  0x145b52218,%xmm0     ; WasapiTimeoutCount
    cvtdq2pd; mulsd             ; deadline = count * duration
    mov   %rax,0x108(%rsi)

and checked in the wait loop at three sites:

    call *WaitForSingleObject
    call <now>                  ; microseconds
    sub  %r13,%rcx              ; elapsed since the loop started
    cmp  0x108(%rbx),%rcx       ; elapsed vs deadline
    jle  <loop again>

**So the audio thread spins — wait 0/1 ms, retry — for up to
`WasapiTimeoutCount × <duration>` microseconds inside one callback.** The
duration at `+0xC0` is set during device setup and is the natural candidate for
the buffer duration, which **Wine inflates 4x** (1024 frames instead of the 256
the app asked for). Same multiplier, longer spin.

## The prediction, and its measurement

If the spin length is what starves the engine, then scaling it down should scale
the damage down. `WasapiTimeoutCount` does exactly that, with nothing else
changed. PC MASTER OUT on, engine speed from `bin/deckrate.sh`:

| `WasapiTimeoutCount` | engine |
|---|---|
| 3 (shipping) | 0.05x - 0.09x |
| **1** | **0.14x, 0.29x** |

A two-to-four-fold improvement — **and not a fix.** It lands in exactly the same
band as every other thing that shortens the spin: `WasapiPolling=1` (~0.3x) and
halving Wine's exclusive buffer (0.13x).

**That convergence is itself the finding.** Four independent levers — the app's
timeout multiplier, the app's polling mode, Wine's buffer inflation, and Wine's
event gate — all move the engine into the 0.1-0.3x band and none of them reaches
1.00x. The spin length modulates the damage; it is not the gate.

## Where this leaves the fault

Consistent with phase 29's null-sink result: making the second device perfect
did not help, and here we can see why — the second device's *thread* still
exists, still spins on the shared global event, and still asks for a whole
buffer it cannot have. What no experiment has yet moved is whatever decides that
the transport may not advance at all.

## Next, with the anchors now in hand

1. **Identify `+0xC0`** — find the writer in the device setup path and confirm
   whether it is the buffer duration (making Wine's 4x inflation a direct
   multiplier on the spin).
2. **Follow `+0x30(%rbx)`** — the counter compared just after the wait
   (`cmp %edi,0x30(%rbx)`), which decides whether to keep waiting at all.
3. **Find the callers** of this wait function and walk up to the transport: that
   is where the "may I advance" decision lives, and it is the only thing left.
4. Ghidra's decompiler output, once the analysis pass finishes, makes 2 and 3
   much faster than reading assembly.

## Decompiled — the retry loop in C (2026-08-18)

Ghidra's full analysis of a 100 MB binary takes hours, but the decompiler does
not need it. `decomp.java` (in `~/rbw-ghidra-scripts`) imports with
`-noanalysis`, disassembles at a given address, creates the function from the
`.pdata` bounds and decompiles just that one. **First C output in about four
minutes.** Saved as `runs/GHIDRA/fn_140fe7b56.c.txt`.

The exclusive + event-callback retry loop, cleaned up:

```c
// device object = RBX;  mode at +0x18 (1 = exclusive);  bufferSize at +0xa8
// period at +0xb8;  own event handle at +0x68;  deadline at +0x108
if (mode == 1 && WasapiPolling == 0 && *(char*)(dev+0xC8) == 0) {
    g_callbacks++;                                  // 0x145ee15a8, a global counter
    if (*(longlong*)(dev+0x108) >= 0) {
        do {
            budget = *(longlong*)(dev+0x120);
            start  = *(longlong*)(dev+0x118);
            now    = now_us();
            r = WaitForSingleObject(*(dev+0x68),     // THIS device's event
                                    (now - start) < budget);   // timeout: 1 ms, then 0
            if (r == WAIT_OBJECT_0) {
                GetCurrentPadding(&pad);
                if (ok && pad <= bufferSize) break;  // always true -> proceed
            }
            GetCurrentPadding(&pad2);
            if (ok && pad2 < bufferSize) break;      // proceed unless COMPLETELY full
            if (g_sleepEvent == 0) Sleep(...);
            else WaitForSingleObject(g_sleepEvent, 0);
        } while (now_us() - t0 <= *(longlong*)(dev+0x108));   // the deadline
    }
}
```

### A hypothesis raised and killed inside ten minutes

The global handle `_DAT_145edb258` is waited on inside the retry loop with a
**zero timeout**, which on an auto-reset event *consumes* a pending signal. Two
device threads doing that would steal each other's wakeups — an elegant
explanation for a two-device-only fault.

**It is wrong.** Disassembling the six other sites that touch that handle shows
one consistent idiom:

    mov  0x145edb258,%rcx
    test %rcx,%rcx
    je   .sleep
    mov  <n>,%edx
    call WaitForSingleObject      ; wait n ms on a never-signalled event
    jmp  .done
    .sleep:
    mov  <n>,%ecx
    call Sleep                    ; fall back to Sleep(n)

It is a **fine-grained sleep primitive** — a dummy event nobody ever signals,
used because waiting on an event with a timeout gives better granularity than
`Sleep()`. There is no signal to steal. *Recorded because the wrong version of
this would have been a very persuasive write-up.*

### What the loop's exit conditions actually say

The loop leaves as soon as **either** the device's own event fires (then
`pad <= bufferSize`, which is trivially true) **or** `padding < bufferSize`.

So it only keeps spinning while **padding is exactly equal to the whole buffer
and the event has not fired**. That is a precise statement of the Wine-vs-Windows
difference in the one number this application polls 320,000 times a second:

- **Windows**, exclusive event-driven: the event fires every period and padding
  collapses at the period boundary, so the loop exits on the first iteration.
- **Wine**: padding is `held_frames`, which we have measured sitting at exactly
  `bufsize` (1024 of 1024) on a large fraction of samples, and the event is
  gated on a **whole free period**. Both exit conditions therefore fail together,
  and the thread spins for the entire deadline —
  `WasapiTimeoutCount × duration`, with the duration scaled by a buffer Wine has
  already inflated 4x.

That is a mechanism that connects, for the first time, a specific Wine behaviour
to the specific loop the application spins in. It also explains the whole family
of partial improvements: `WasapiPolling=1` skips this loop entirely,
`WasapiTimeoutCount=1` shortens it, and a smaller exclusive buffer shortens the
duration it is scaled by — 2x to 6x each, and none of them a cure, because none
of them makes the two exit conditions succeed.

### The test this predicts

Make **either** exit condition succeed the way it does on Windows:

1. ensure `GetCurrentPadding` never returns exactly `bufsize` while a period is
   free (padding must reflect what the device has consumed, not what Wine still
   holds); or
2. fire the stream event every period regardless of ring occupancy — already
   built as `RBW_EVENT_GATE=always`, and measured: cadence became exact but the
   engine did not recover, which means condition 1 is the one that matters.

Point 2 is already evidence *against* the event half of the explanation and
*for* the padding half. Padding is now the single most specific open lead, and
it is the number the earlier `RBW_PADDING=hw` experiment changed in the **wrong
direction** (it made padding larger, and playback stopped altogether).

## The call ladder, from the runtime stack (2026-08-18)

Static cross-references dead-ended: the device wait function has **no direct
callers and no vtable slot** in the file, so it is reached indirectly. The way
through is that we own the DLL it calls. `RBW_STACK=1` captures
`RtlCaptureStackBackTrace` at `ReleaseBuffer` and prints every frame as
module+offset, ready to feed back to the decompiler:

    mmdevapi.dll+0x6471
    rekordbox.exe+0xfe9411      <- device write (the function that computes the deadline)
    rekordbox.exe+0xfe4b53
    rekordbox.exe+0xfe2a8a
    rekordbox.exe+0x2b3b8eb
    rekordbox.exe+0x1cec9a5     <- FUN_141cec870, 2533 bytes
    rekordbox.exe+0x1cd395a     <- FUN_141cd3910, the per-device step
    rekordbox.exe+0x1cfad9e     <- FUN_141cfad10, the loop over devices
    rekordbox.exe+0x1cd6238 / +0x1cd4faf / +0x1cd2fe9
    rekordbox.exe+0x1959470 / +0xf1b6f5 / +0xf1d8ae / +0xf1d406
    rekordbox.exe+0x2a0dc54 / +0x2711c5e   <- CRT thread start
    kernel32.dll+0x11649 / ntdll.dll+0x110db

**That is the whole ladder from thread entry to the WASAPI write**, obtained in
one run. It is the step that static analysis could not provide, and it is only
possible because Wine lets us instrument the DLL the application links against.

### What the two engine frames do

`decomp.java` now takes explicit `start-end` ranges from `.pdata` (a bare address
yields a one-byte body under `-noanalysis`). Decompiled:

```c
// FUN_141cd3910 — process/apply ONE device
undefined1 FUN_141cd3910(longlong self, undefined8 key) {
    p = FUN_141cd0e80(self, &tmp, key);
    if (*(char*)*p == '\0') {              // <-- a gate: only proceeds if this byte is 0
        FUN_141cead10(self);               //     \
        FUN_141ceb3a0(self);               //      > open / start / write  (reaches WASAPI)
        FUN_141cec870(self);               //     /
        ...
        FUN_1429737d0(&tmp, "AudioDeviceChanged");
        FUN_142a0b7b0(self + 0xc0, &tmp);  // broadcast "AudioDeviceChanged"
        return 1;
    }
    return 0;
}

// FUN_141cfad10 — iterate the configured outputs
FUN_141cd34c0(*self, &list, arg);          // fetch the list of device setups
for (i = 0; i < count; i++) {
    entry = list[i];
    k = lookup(entry, "audioOutputDeviceName");
    if (FUN_1422b1e50(&k) == '\0'          // <-- "is this device already fine?"  NO
        && FUN_141cd3910(*self, &k) != 0)  // <-- so (re)apply it
        break;                             //     and stop at the first one applied
}
```

**So the 14.7 s cycle is a device-configuration reconciliation loop.** It walks
the configured outputs, keyed by the setting `audioOutputDeviceName` — the very
string in `rekordbox3.settings` that holds `"DDJ-400 WASAPI"` and
`"Speakers (Out: default)"` — asks "is this one already satisfied?", and when the
answer is no, tears the device down and reopens it, then broadcasts
`AudioDeviceChanged`.

That matches every external observation: a full `CoCreateInstance` →
`EnumAudioEndpoints` → `Activate` → `Initialize` → `Start` sequence every cycle
(phase 26), the single decode burst 66 ms before each teardown (phase 28 — the
burst happens *inside* this reopen), and the fact that a perfect second device
does not help (phase 29 — the loop is not about the device's behaviour).

### The next question is now exactly one function wide

**`FUN_1422b1e50` is the predicate that keeps answering "not satisfied".** It is
called with the device-name key and its false answer is what triggers the
rebuild. Whatever it compares — a name, a state, a format, a handle — is the
thing Wine presents differently from Windows.

Second target: `FUN_141cd0e80`, which supplies the byte gating `FUN_141cd3910`.

### Correction to the previous section

The padding explanation written above **over-reached**, and the measurement says
so. `RBW_PADDING=interp` (subtract `interp_elapsed_frames()` from `held_frames`,
so padding falls continuously between ticks as it does on Windows) was built and
measured: **PC MASTER OUT off 1.00x, on 0.09x — no change.** And our own earlier
per-client data already showed padding at 471/534/759/760/503/479 against a 1024
buffer, i.e. *below* `bufsize` on most samples, so the retry loop was already
exiting. The retry loop is not the gate; the reconciliation loop above it is.

## The predicate, decompiled — it matches DEVICE NAMES

`FUN_1422b1e50`, the test whose "no" drives every rebuild, is 173 bytes:

```c
bool FUN_1422b1e50(name) {
    r = FUN_1422bb4a0(name, 0, tbl);
    if (r == 0 || *(int*)(r+8) != 1) {
        if (!match(name, "DDJ")) return false;
    }
    if (match(name, "rekordbox Aggregate Device")) return true;
    return match(name, "Pioneer MIX ASIO");
}
```

The three constants it compares against, read straight out of `.rdata`:

    0x143b86380  "DDJ"
    0x143b86388  "rekordbox Aggregate Device"
    0x143b863a8  "Pioneer MIX ASIO"

So this is **"is this output an aggregate / Pioneer ASIO device?"**, answered by
string matching on `audioOutputDeviceName`. For both of our outputs —
`"DDJ-400 WASAPI"` and `"Speakers (Out: default)"` — it returns **false**, and the
caller then applies that device and breaks out of the loop:

```c
for each configured output:
    k = entry["audioOutputDeviceName"]
    if (!isAggregateOrAsio(k) && applyDevice(k)) break;   // apply ONE, then stop
```

**The loop applies exactly one output per pass and stops.** With a single output
that is complete. With two outputs configured — which is precisely what PC
MASTER OUT means — one pass can only ever satisfy one of them.

That is the first structural asymmetry found that is intrinsically about *having
two outputs*, and it sits directly above the rebuild we have been watching from
the outside for four sessions. It is consistent with every prior measurement:
the rebuild being a full re-negotiation (phase 26), the decode burst landing
inside the reopen (phase 28), and a perfect second device changing nothing
(phase 29), because the loop never examines the device's behaviour at all.

**It is not yet proof.** It works on Windows with the same two outputs, so either
the loop terminates differently there, or the re-trigger that starts a fresh pass
every 14.7 s is the real variable. Those are the next two questions, and both are
now one decompiled function away:

1. what re-triggers `FUN_141cfad10` — its callers, obtainable the same way with
   `RBW_STACK` on a rebuild;
2. what `FUN_1422bb4a0` looks up (a device table keyed by name), and whether its
   `+8 == 1` field is something Wine reports differently.

### A speculative but cheap thing to try

`"rekordbox Aggregate Device"` is a name the application treats specially — the
predicate returns **true** for it, which takes the caller down the *other*
branch entirely. Wine's endpoint names are ours to choose (`winealsa` builds
them). Naming an endpoint that string is a one-line change and would exercise a
code path we otherwise cannot reach.

## ROOT CAUSE (2026-08-18) — Wine drops a device from enumeration while it is in use

### The application's side, decompiled

`FUN_141ce4220` is the handler that tears everything down. Its first statement is
a log line that names the whole bug:

```c
FUN_142a17a90(1, "audioDeviceListChanged ASIO/WASAPI/CoreAudio reset");
...
if (deviceStillMatches(...)) {
    FUN_141ced5d0(self); FUN_141cedc40(self);
    FUN_141ceeb90(self); FUN_141ceeef0(self);      // stop + close everything
    ...
    timeout = match(param_3, "DDJ-WeGO4") ? 5000 : 1000;
    FUN_142a0add0(self + 0xa0, 3, timeout);        // schedule the reopen
}
```

**That 1000 ms timer is the 1.08 s Stop→Initialize gap** that has sat in
`STATE.md` as an unexplained mystery since phase 24. It is not a stall; it is a
scheduled retry.

So rekordbox is being told, over and over, that **the audio device list
changed** — and it is doing exactly the right thing in response.

### Wine's side, in nine lines

`dlls/winealsa.drv/alsa.c`:

```c
static BOOL alsa_try_open(const char *devnode, EDataFlow flow)
{
    if ((err = snd_pcm_open(&handle, devnode, dir, SND_PCM_NONBLOCK)) < 0) {
        WARN("The device \"%s\" failed to open...");
        return FALSE;            /* <-- excluded from the endpoint list */
    }
    snd_pcm_close(handle);
    return TRUE;
}
```

`alsa_get_endpoint_ids()` calls that for every candidate and **omits any device
that fails to open**. A device held in WASAPI **exclusive mode** is open, so
`snd_pcm_open` returns `EBUSY` — and Wine reports the device as *not present*.

### Measured, with the tools already in the repo

    DDJ idle:                 render endpoints: 7   ... [6] Speakers (Out: DDJ-400 - USB Audio)
    DDJ held open exclusive:  render endpoints: 6   ... the DDJ is GONE

(`upstream/wasapitest.exe` for the listing, `upstream/dualclient.exe excl` to
hold the device. No rekordbox involved.)

### The loop this creates

1. rekordbox opens the DDJ in exclusive mode and plays.
2. Something prompts a device-list check (with PC MASTER OUT there are two
   configured outputs, and the reconciliation loop walks them).
3. Wine enumerates — **the DDJ is missing, because rekordbox itself has it open.**
4. rekordbox: `"audioDeviceListChanged ... reset"` → tear down both streams.
5. The teardown releases the ALSA device, so it reappears.
6. The 1000 ms timer fires → reopen both → back to step 1.

**On Windows an endpoint stays enumerated while it is open** — enumeration
reports presence, not availability — so this loop cannot happen there. That is
exactly the interop asymmetry the user predicted, and it is Wine's to fix.

### Why every previous experiment failed to move it

Because none of them touched enumeration. Buffers, share mode, event cadence,
padding, session notifications, MMCSS, the null-sink — all downstream of a
decision the application makes from the *device list*. It also explains the
null-sink result exactly: a perfect second device does not help, because the
fault is that the FIRST device vanishes from the list while in use.

### The fix

`snd_pcm_open` returning `-EBUSY` means "this device exists and is in use", not
"this device is absent". `alsa_try_open` should treat it as success.

## CORRECTION (same day) — the enumeration bug is REAL, but it is not the cause

I committed the section above as "ROOT CAUSE". **That was wrong, and the fix I
wrote for it does not stop the fault.** Recording the correction immediately,
next to the claim.

### What is true

Wine really does drop a busy device from `EnumAudioEndpoints`, and that really is
a bug — proven without rekordbox, and fixed in nine lines:

| | endpoints | DDJ listed? |
|---|---|---|
| DDJ idle | 7 | yes |
| DDJ held open exclusive, **shipping Wine** | **6** | **no** |
| DDJ held open exclusive, **RBW-ENUMBUSY** | 7 | yes |

`alsa_try_open()` now treats `-EBUSY`/`-EAGAIN` as "present and in use" instead
of "absent". Windows enumerates by presence, not availability, so this is a
genuine Wine-vs-Windows divergence and is worth upstreaming on its own merits.

### What is not true

**It does not cure the fault.** With the fix installed and PC MASTER OUT on:

    engine rate      0.05x  ->  0.22x        (a real improvement)
    PCM transitions  8 per 60 s  ->  8 per 60 s   (UNCHANGED)

and the teardowns still land every ~15.8 s with the same ~1.1 s gap.

**And the decisive check I should have run before claiming causation:** with the
fix in place and rekordbox running and cycling, enumerate the endpoint list
repeatedly —

    six enumerations over ~30 s: 7 endpoints every time, identical md5

**The device list is stable, and the application resets anyway.** So the reset is
not driven by an observable change in Wine's endpoint list, and the handler
`FUN_141ce4220` ("audioDeviceListChanged … reset") — which the runtime stack
proves *is* the code doing the teardown — is being invoked for some other reason.

### The methodological failure, stated plainly

I had the mechanism (a busy device vanishing), a clean measurement of it, and a
story that fitted every previous observation — and I wrote "ROOT CAUSE" before
running the one experiment that could refute it. The oracle was sitting right
there; the whole discipline of this project is that a mechanism is a hypothesis
until the fix moves the number, and the number moved only a little. Same error as
RBW-RING and the T08 headline, in a new place.

### What survives, and what is next

- **Keep**: the enumeration fix as a candidate patch (`debug/`, not shipped —
  the single-device configuration has not been measured against it), and the
  fact that it is worth ~4x on its own.
- **Established**: the teardown is `FUN_141ce4220`, reached from a dispatcher
  through `FUN_141b421f0`, and it schedules the reopen on a **1000 ms timer**,
  which is the long-unexplained 1.08 s Stop→Initialize gap.
- **Next**: `FUN_141b421f0` does not call the handler directly, so the call is
  indirect. The way to close this is another `RBW_STACK`-style capture with a
  deeper frame budget, or a breakpoint on `FUN_141ce4220` to see what invokes it
  — the same technique that produced the ladder, applied one rung higher.

## The re-trigger, traced (2026-08-18, later)

### The teardown handler is a SETTINGS listener, not a device listener

`FUN_141ce4220` is referenced only from data — it is a virtual method. Decoding
the MSVC RTTI locator that precedes its vtable gives the class:

    vtable holding FUN_141ce4220 -> .?AVSettingIF@djplay@@   =  djplay::SettingIF

So the reset is delivered through the application's **settings-change**
interface. That reframes the whole cycle: rekordbox is not being told "a device
appeared or vanished" — it is being told **"a setting changed"**, and it responds
by re-applying the audio device.

### The settings file is rewritten once per cycle, and only a timestamp moves

Watching the settings directory during the fault (PC MASTER OUT on):

    8.0s  written: rekordbox3.settings
   24.0s  written: rekordbox3.settings
   40.0s  written: rekordbox3.settings
   56.0s  written: rekordbox3.settings          -> every 16 s, the cycle exactly

Diffing two consecutive writes, **one line changes in 671**:

    - BufferSize="256" Date="1.787068374521e12" MixerMode_Is_Internal="1"
    + BufferSize="256" Date="1.787068390405e12" MixerMode_Is_Internal="1"
                            (delta 15,884 ms)

and the block it belongs to is the **DDJ-400 WASAPI** `DEVICESETUP` — not the PC
one. So every cycle the application re-applies the *controller's* device setup
and stamps it. Nothing else in the configuration differs between cycles.

### The period has a single source in the binary

`FUN_142a0add0(obj, id, ms)` is the application's `startTimer`. Scanning all
**386** call sites for their millisecond immediates gives a histogram —
1000 ms x68, 5000 ms x36, 30000 ms x14 … and **exactly one 15000 ms timer in the
whole executable**:

    0x141334c64:   lea rcx,[rsi+0x1f0]
                   mov edx,4              ; timer id 4
                   mov r8d,0x3a98         ; 15000 ms
                   call FUN_142a0add0     ; startTimer

armed at the end of a 2,627-byte manager constructor (`FUN_141334260`).
**15,000 ms + the 1,000 ms reopen timer = the 15.9 s cycle measured at the
device.** Both constants are now accounted for, and the 1.08 s Stop→Initialize
gap that stood unexplained from phase 24 to phase 29 is simply the second one.

### Where that leaves the chain

    [15 s timer id 4, FUN_141334260]  -> ? -> djplay::SettingIF notification
        -> FUN_141ce4220  "audioDeviceListChanged ASIO/WASAPI/CoreAudio reset"
        -> stop + close both streams
        -> startTimer(id 3, 1000 ms)
        -> FUN_141cfad10 reconciliation loop -> FUN_141cd3910 -> reopen
        -> settings written, DDJ DEVICESETUP re-stamped
        -> 15 s later, again

The one unresolved link is the arrow after the timer: what the id-4 callback
checks, and why its answer differs under Wine. That callback is a virtual method
on the object at `+0x1f0` of that manager, so the next step is the same RTTI
walk that identified `SettingIF`, applied to this object's vtable.

## Phase 6 — the teardown trigger, decoded end to end (static, 7.2.18)

The 15.9 s cycle is now traced from the timer to the stream teardown, and the
decision point is a **single string comparison**. Every address below is for
`rekordbox.exe` 7.2.18, image base `0x140000000`.

### The call ladder, read off the live Stop stack

The `RBW_STACK=Stop` capture gave return addresses; each one has now been
matched to an instruction, so the ladder is no longer a guess:

    0x142711c5e   caller of the JUCE dispatch loop
    0x142a0dc54   ret from `call 0x140f1d2f0`  — the pump: try to dispatch a
                  message; if none, wait on the dummy event 0x145edb258 or Sleep(1)
    0x140f1d406   ret from `call 0x140f1d820` — reached only when the message id
                  is 0x47B (JUCE's custom message) AND the target window equals
                  the global message-window handle at 0x145ed5d68
    0x140f1d8ae   ret from `call [rbx+0x8]`   — MessageBase::messageCallback()
    0x141b4243b   ret from `call rsi`         — rsi = listener->vtable[0x10]
    0x141ce431f   inside FUN_141ce4220        — the audio teardown

So the teardown does **not** come from a timer poking the audio code. It is a
posted message, delivered on the JUCE message thread, broadcast to a listener
list.

### FUN_141b421f0 — the broadcaster (drains a queue, dispatches to listeners)

Object layout (juce idiom):

    +0x18   CRITICAL_SECTION guarding both arrays
    +0x48   String queue data      +0x50 numAllocated   +0x54 numUsed
    +0x58   listener array data    +0x60 numAllocated   +0x64 numUsed

Per queued message it calls `StringArray::addTokens(msg, delim, quote)`
(`FUN_14296a2f0`, delimiter constant `DAT_143950b00`) and, **if there are at
least two tokens**, calls `listener->vtable[0x10](token0, token1)`. If the queue
is empty it calls `listener->vtable[0x8]()` instead. The captured return address
`0x141b4243b` is the instruction after the two-token call, so the teardown came
from the **two-token dispatch**, not the empty-queue arm.

### The listener slot is confirmed by RTTI

Scanning `.rdata` for a vtable containing `0x141ce4220`, then walking back to the
Complete Object Locator:

    vtable VA 0x1439fbfe8   base-offset 0   class .?AVSettingIF@djplay@@
    FUN_141ce4220 = slot 0x10  (index 2)

`FUN_141ce4220` sits in exactly the slot the broadcaster calls with two strings.
So the interface is `djplay::SettingIF`, and slot 0x10 is its two-string
notification — call it `onChanged(a, b)`.

### FUN_141ce4220 — what the callback actually checks

    void FUN_141ce4220(this, param_2, param_3)      // param_2 is NEVER READ
      log(1, "audioDeviceListChanged ASIO/WASAPI/CoreAudio reset")
      local_28 = ""                                  // a juce::String
      obj = dynamic_cast(<audio device manager>+0x408, ...)
      if (obj) {
          local_28 = obj->name                       // the CURRENTLY OPEN device
          if (FUN_1422b1e50(local_28))               // the DDJ / Aggregate / MIX ASIO predicate
              local_28 = this->str_at_0x358          // substitute a stored name
      }
      if (FUN_1422b48c0(local_28, param_3)) {        // STRING EQUALITY
          FUN_141ced5d0(this); FUN_141cedc40(this)   // stop  both streams
          FUN_141ceeb90(this); FUN_141ceeef0(this)   // close both streams
          ... FUN_142b3a9e0(...)                     // reset the device manager
          startTimer(this+0xa0, id=3,
                     param_3 == "DDJ-WeGO4" ? 5000 : 1000)   // the reopen
      }

**The decision is one comparison: "is the device named in the notification the
device I am currently playing through?"** If yes, both streams are destroyed and
rearmed 1000 ms later — which is precisely the 1.08 s Stop→Initialize gap already
measured, and the "5000 for a DDJ-WeGO4" branch confirms `param_3` is a device
name, not a settings key.

This also explains why the first argument never mattered: the callback ignores
the topic and keys entirely off the name in the payload.

### What this closes, and what it opens

Closed: the shape of the fault. Something announces, roughly every 15 s, that
the device rekordbox is playing through has changed. rekordbox believes it and
performs a correct, deliberate teardown-and-reopen. The engine is not stalling —
**it is being reset on purpose, by the application, on bad information.**

Open: who pushes that message into the queue. Ruled out this session:

- **Wine's `IMMNotificationClient` path is not it.** `dlls/mmdevapi/devenum.c`
  fires only `OnDefaultDeviceChanged` (never `OnDeviceStateChanged`,
  `OnDeviceAdded`, `OnDeviceRemoved`, `OnPropertyValueChanged`), and only from
  `notif_thread_proc`, which blocks in `RegNotifyChangeKeyValue` on
  `HKCU\Software\Wine\Drivers\winealsa.drv` and then calls `notify_if_changed`,
  which returns early unless the registry string genuinely differs
  (`if(!lstrcmpW(old_val, new_val)) return FALSE;`). Nothing there can fire on a
  15 s cadence with a static registry.

### Aside — rekordbox has a dormant internal trace facility

`FUN_142a17a90(channel, fmt, ...)` is the logger behind
"audioDeviceListChanged…". It is gated on a master byte at `0x145edb254` and a
table of 10 per-channel sinks at `0x145ee0600`; with either unset it takes the
critical section and returns without formatting.

`0x142a17d45` is its `startLogging(host, port)`: it defaults the host to
**"127.0.0.1"** (`0x1453eb168`) and the port to **0x2711 = 10001**
(`0x145edbcfc`), allocates ten 0x48-byte channel objects bound to
`port + channel`, and only then sets the master byte to 1.

**It has zero callers** — `e8`-relative scan over `.text` finds none — so the
facility is dead code in the release build and cannot be switched on by
configuration alone. Recorded because if it can be entered (injected DLL, or a
Wine-side call once the module base is known) it yields the vendor's own trace
of this exact fault. Not attempted yet; the offset is 7.2.18-specific.

Caution for the next session: an earlier span-1 xref scan on `0x145edb254`
reported five hits, but three were instruction-byte overlaps —
`bin/pexrefva.py` assumes an instruction ends 4 bytes after the RIP
displacement, which is wrong for `mov [rip+d32], imm8/imm32`. Those "hits" were
really `0x145edb255` (a touch-input flag set from a `user32.dll` /
`GetPointerType` probe) and `0x145edb258` (the dummy event). Decode the
instruction before believing a target address.

## Phase 7 — the pusher, and the true source of the 15 s event

`djplay::AudioDeviceWatcher` (RTTI from the vtable containing the pump) is a
multiple-inheritance object:

    +0x00  rb::AudioIODeviceType::Listener   vtable 0x143950b78
             [0] 0x141b42730  dtor
             [1] 0x141b425b0
             [2] 0x141b425c0  <- THE PUSHER
    +0x08  juce::AsyncUpdater                vtable 0x143950b98
             [0] 0x141b42720
             [1] 0x141b421f0  <- handleAsyncUpdate() == the broadcaster/pump
    +0x18  rbxfrm::ExistenceConfirmable magic 0x5e715e28
    +0x20  CRITICAL_SECTION
    +0x50  StringArray queue   (+0x58 numAllocated, +0x5c numUsed)
    +0x60  Array<Listener*>    (+0x68 numAllocated, +0x6c numUsed)
    +0x70  bool (registered?)

Note the pump's `param_1` is `this+8` (it is entered through the AsyncUpdater
vtable), which is why its field offsets read 0x18/0x48/0x54/0x58/0x64 — subtract
8 from the layout above.

### The push site — 0x141b426bd, inside FUN_141b425c0

    movsxd rdx,[r13+0x5c]        ; numUsed
    lea    eax,[rdx+1]
    mov    [r13+0x5c],eax        ; numUsed++
    mov    rax,[r13+0x50]        ; queue data
    lea    rcx,[rax+rdx*8]       ; &queue[n]
    lea    rdx,[rsp+0x70]
    call   0x142973a10           ; String copy-construct into the slot
    call   0x142948a50 (x2)      ; LeaveCriticalSection
    lea    rcx,[r13+0x8]
    call   0x142a0b680           ; trigger

`0x142a0b680` is `juce::AsyncUpdater::triggerAsyncUpdate()`: a
`lock cmpxchg [internal+0x18], 1` that posts the message only if one is not
already pending, resetting the flag if the post fails.

**So AudioDeviceWatcher owns no timer.** Its cadence is entirely inherited from
whoever calls the pusher. Corrects any reading of phase 5 that put a 15000 ms
timer inside this class.

### The source is rekordbox's own device-type layer

The pusher is **slot 2 of `rb::AudioIODeviceType::Listener`** (RTTI decoded from
the vtable at `0x143950b58`, the base-class vtable installed first by the
constructor). The constructor `FUN_141b41de0(this, bool)` walks the collection
returned by `FUN_142b3e880(FUN_141ccfd60(FUN_141cc4270()))` and calls
`FUN_142b39030(deviceType, this)` on each — i.e. `AudioIODeviceType::addListener`
for every device type. The destructor `FUN_141b41ed0` unwinds the same loop,
guarded by the flag at +0x70.

So the full cascade is:

    rb::AudioIODeviceType (WASAPI)  "the device list changed, name = N"
      -> AudioDeviceWatcher::<Listener slot 2>(N)      FUN_141b425c0
           push "topic,N" onto the queue; triggerAsyncUpdate()
      -> PostMessage(0x47B) to the JUCE message window
      -> AudioDeviceWatcher::handleAsyncUpdate()       FUN_141b421f0
           addTokens(msg, ","); for each listener: slot0x10(token0, token1)
      -> djplay::SettingIF::<slot 0x10>                FUN_141ce4220
           if (token1 == currently-open device name)
               stop + close BOTH streams; startTimer(id 3, 1000 ms) to reopen

Every link in that chain is correct application behaviour. **The fault is that
the first line is being asserted at all**, roughly every 15 s, while nothing
about the hardware has changed.

### Where that puts the investigation

The question is now narrow and Wine-side observable: *what does rekordbox's
WASAPI device-type see that makes it announce a device-list change?* JUCE's
WASAPI device type detects changes either from `IMMNotificationClient`
callbacks — which Wine essentially never fires (phase 6) — or by re-enumerating
and diffing. If it re-enumerates and probes each endpoint, a probe that fails
only while a second client is active would produce exactly this: a device drops
out of the list, the list "changes", the streams are torn down, the reopen
succeeds, and 15 s later it happens again. That is self-sustaining and it is
gated on the second stream existing — which is precisely what RBW_NULLSINK
already proved (phase 29).

Note the earlier enumeration control does **not** refute this: it showed a
stable 7-endpoint list with identical md5, but that measured *my* enumeration of
endpoint IDs and names, not the properties rekordbox probes per endpoint.

**Next action:** with the RBW-QUIET build (which makes `WINEDEBUG=+mmdevapi`
affordable at ~2 KB/s instead of 797 MB/45 s), capture 60 s of the broken arm
with a track playing and read the mmdevapi calls in the ~200 ms before each
teardown. Looking for a call that returns a failure or a changed value on a 15 s
cadence — `IsFormatSupported`, `GetMixFormat`, `Activate`, `GetState`, or a
property-store read.

## Phase 8 — RUNTIME: the announcement comes from rekordbox's own buffer-queue watchdog

### How it was caught

`kernel.yama.ptrace_scope` was temporarily set to 0 (recorded in
`PATH-TO-GOLD.md` with its reversal) so `gdb` could attach to a running
rekordbox. The module maps at exactly `0x140000000` with no ASLR shift, so every
static address above is directly usable at runtime.

Wine's internal signals must be passed through or gdb stops immediately and a
batch script ends before any breakpoint is reached:

    handle SIGUSR1 SIGUSR2 SIGSEGV SIGTRAP SIG32 SIG33 SIG34 SIG35 nostop noprint pass

Breakpoint on the pusher `0x141b425c0` — run `runs/GDB/20260818T211*-push2.log`:

    === PUSH #1  (AudioIODeviceType::Listener slot 2)
      rcx(this)=0x145e34ea0  rdx=0x2643038  r8=0xf143bd8
      retaddr=0x142b38f60
      stack also contains 0x140fe4434

### The two frames that closes the chain

`0x142b38ee0` is **`juce::ListenerList::call`** — the textbook backwards
iterator with a saved/restored bail-out checker, dispatching
`listener->vtable[0x10](rdx, r8)`. Its only two callers are `0x140fe442f` (whose
return address `0x140fe4434` is on the captured stack) and `0x140fedd3a`.

So the announcer is the 3932-byte function **`0x140fe3530 .. 0x140fe448c`** —
in the same region as the device wait loop `0x140fe7b56`, i.e. the audio engine,
**not** any device-enumeration code.

### What that function actually does

It is the engine's per-device service loop. For each of the
`*(int *)(param_1 + 0x3d4)` devices in the array at `param_1 + 0x3c8` it takes a
per-device spinlock (`lVar11 + 0x78 + slot*4`, with a 0x13-iteration spin then
`Sleep(0)`), then walks a linked list of queued buffers chained through `+0x128`
and counts them:

    for (n = 0, p = queue_head; p; p = *(p + 0x128)) n++;

    if (n - expected < 4) {
        release spinlock                      // normal: nothing to do
    } else {
        ... unlink and free the excess entries (0x130 bytes each) ...

        now = time_ms();
        if ((now - dev->last_trim_ms < 100) && (++dev->trim_count > 100)) {
            dev->trim_count = 0;
            announce = true;                  // <-- the device-change assertion
        }
        dev->last_trim_ms = now;              // dev+0x88
    }                                         // dev+0x98 = trim_count

and after the device loop, if `announce`:

    listeners = dynamic_cast(engine->0x3e0, ...);
    juce::ListenerList::call(listeners, listeners+8, engine + 0x3f0);

**This is a failure-storm watchdog.** The engine trims its own output queue when
more than three buffers beyond expectation have piled up; if it has had to do
that 101 times with less than 100 ms between consecutive trims, it concludes the
audio device is misbehaving and announces a device-list change — which is what
tears down both streams and reopens them a second later.

### Why this is the answer to phases 6-7

Nothing external asserts the device change. **rekordbox asserts it about
itself.** The cascade in phase 7 is intact, but its first cause is now known and
it is inside the engine:

    output queue over-fills  ->  trim  ->  101 rapid trims
      ->  AudioIODeviceType listeners called
      ->  AudioDeviceWatcher pushes "topic,deviceName"
      ->  PostMessage(0x47B) -> handleAsyncUpdate
      ->  SettingIF slot 0x10 -> stop+close both streams -> 1000 ms reopen

### This retro-explains the central T03 measurement

T03 phase 26 recorded, without an explanation: *"the engine completes a fixed
~9 buffers per second whatever their size (256 -> 0.05x, 512 -> 0.11x,
1024 -> 0.22x, 2048 -> 0.40x, exactly proportional). Something counts buffers
and fills up; only a stream rebuild empties it."*

That "something" is this queue and this watchdog. The proportionality falls out
of it: the trim threshold is a **count of buffers** (`n - expected >= 4`), not an
amount of audio, so doubling the buffer size doubles the audio that survives per
cycle and doubles the measured rate. It also explains why only a rebuild clears
it — the teardown frees the queue.

### Refuted by this finding

- The device list is not changing and does not need to. Wine builds its endpoint
  list once (`mmdevapi/main.c:185`) and never rebuilds it; `devwatch` measured
  **0 `WM_DEVICECHANGE` events in 75 s** with rekordbox running (and 0 in 45 s
  idle), runs `runs/DEVWATCH/20260818T2100*`. Both facts are consistent: nothing
  external was ever involved.
- Any remaining "spurious enumeration" hypothesis is dead.

### What is still unknown — the real root cause

**Why does the output queue over-fill only when a second device is open?** The
watchdog is correct behaviour; it is firing because the engine genuinely cannot
drain its queue. Two clients are each served ~44,032 and ~44,453 frames/s
against 44,100 (T03 phase 26), so neither is being starved of callbacks — yet
buffers pile up. The next question is what the engine is waiting on between the
callback and the queue pop, with the strongest candidate being the two devices'
clocks: the engine appears to service both devices in one loop
(`param_1 + 0x3c8`, count at `+0x3d4`) under per-device spinlocks.

### Next actions

1. Name the per-device fields by decompiling `FUN_140fe51a0(dev, &local_188, n)`
   at the top of the loop, and find what sets `expected` (`local_1fc`).
2. Watch `dev->trim_count` (`dev+0x98`) and `dev->last_trim_ms` (`dev+0x88`)
   live through `/proc/<pid>/mem` — a read-only poll, zero perturbation, unlike
   a breakpoint on a site hit 100 times per cycle. Confirms the arithmetic of
   the 15.9 s period directly.
3. Then ask why the queue grows: compare queue depth per device in both arms.

### Instrument note

`gdb` attach/detach is usable but not free: the run that produced the capture
ended with rekordbox exiting during detach. Treat any breakpoint run as
destructive to that session, and never breakpoint a hot site in a
timing-sensitive path — this watchdog is *made of* timing.

## Phase 9 — THE FAULT, OBSERVED DIRECTLY: the DDJ's exclusive queue falls behind the PC's

### The instrument

`bin/queuescope.py` reads the engine's per-device queues through
`/proc/<pid>/mem`. No breakpoints: this watchdog is *made of* timing, and a
breakpoint on a site hit ~100 times per cycle would manufacture the very storm
it detects. It finds the device objects by scanning writable anonymous memory
for the vtable they share at `+0x00` (`0x145550178` in 7.2.18), so no debugger
is needed at all.

This matters — an earlier attempt used gdb, and the attach/detach left rekordbox
in a Wine crash dialog. The follow-up poll then read `[0, 0]` depths and zero
counters, which reads exactly like "the queues are fine" when in fact the
application was dead. **A dead device looks like a fixed one**, again.

### What it shows — run `runs/QUEUE/20260819T0630*`, PC MASTER OUT on, track playing

    t       depths        spread  trim_count
      1.0  [0, 0, 3, 3]       3  [0,0,0,0]
      3.0  [0, 0, 3, 5]       5  [0,0,0,1]   <- dev3 trim_count RESET after 100 (ANNOUNCE)
      4.0  [0, 0, 0, 0]       0  [0,0,0,0]   <- teardown: both streams destroyed
      5.0  [0, 0, 3, 3]       3  [0,0,0,0]   <- reopened, balanced again
     ...
     18.1  [0, 0, 3, 5]       5  [0,0,0,13]
     18.8  [0, 0, 3, 5]       5  [0,0,0,0]   <- ANNOUNCE (after 99)
     19.8  [0, 0, 0, 0]       0
     ...
     33.9  [0, 0, 2, 5]       5  [0,0,0,6]
     34.7  [0, 0, 0, 4]       4  [0,0,0,0]   <- ANNOUNCE (after 99)

Announces at t = 3.0, 18.8, 34.7 s → intervals of **15.8 s and 15.9 s**. That is
the exact period T03 measured from the outside, now produced by a mechanism read
from the inside. Every quantity predicted from the decompilation in phase 8 —
the threshold of 4, the counter limit of 101, the reset, the collapse to empty —
is present and behaves as predicted.

### Which device is which — read from live memory

The object at `device + 0x18` carries the name:

    dev2  "Speakers (Out: default)"   "Windows Audio"                    "JUCE WASAPI"
    dev3  "DDJ-400 WASAPI"            "Windows Audio (Exclusive Mode)"   "JUCE WASAPI"

**The queue that backs up is dev3 — the DDJ, the exclusive-mode client.** It
climbs to 5 while the shared PC endpoint sits at 3. The DDJ is not consuming
buffers as fast as the PC endpoint is, so rekordbox — which requires every
output to stay within 3 buffers of the shallowest — trims it, repeatedly, and
then declares the device changed.

Note this is the opposite of the intuition the investigation has been carrying.
The PC MASTER OUT stream is the *trigger* but not the *victim*: adding it simply
introduces a second, healthier queue for the DDJ to be measured against.

### This overturns a T03 verdict — and reconciles it

T03 recorded: *"The ~160,000 `AUDCLNT_E_BUFFER_TOO_LARGE` refusals a second are
real, are Wine's, and are NOT this fault: they happen in the healthy arm too,
where playback is perfect."*

The observation was right; the conclusion does not follow. Those refusals are on
the **exclusive** client — the DDJ. When the DDJ is the only output, its queue
can back up as much as it likes and **nothing in rekordbox polices it**, because
`depth - min(depth)` over one device is always 0. The refusals are therefore
invisible in the healthy arm *by construction*. Add a second output and the same
refusals become fatal, because now there is something to fall behind.

So "it happens in the healthy arm too" was never evidence of innocence here. The
harmlessness in that arm is a property of the *watchdog*, not of the refusals.

### Status of the causal chain

Proven by direct observation:

- dev3 (DDJ, exclusive) is the queue that grows; dev2 (PC, shared) stays level.
- The spread reaches the engine's own threshold of 4.
- `trim_count` climbs to ~100, resets, and the announce fires.
- The announce is followed by both queues collapsing to 0 (the teardown).
- The period is 15.8-15.9 s, matching every external measurement in T03.

Still inferred, and the one remaining link to close:

- **That the DDJ queue grows *because* Wine refuses `GetBuffer` on the exclusive
  client.** This is strongly suggested — the refusals are on exactly that client,
  at a rate (~160k/s) that guarantees the app cannot hand buffers over on
  schedule — but it has not yet been demonstrated that removing the refusals
  removes the spread.

### Next action

`debug/wip-exclusive-buffer-contract.diff.txt` is a parked patch on exactly this
contract. Build it, install it, and re-run `bin/queuescope.py` in the same
configuration. The prediction is sharp and falsifiable:

    if the refusals are the cause -> spread stays <= 3, trim_count never climbs,
                                     no announces, no 15.9 s cycle
    if it is not                  -> spread still reaches 4 and the cycle persists

`queuescope` scores this in 60 seconds with no human and no screenshots, and
unlike `enginerate` it does not depend on the track file staying open — which
failed repeatedly this session once a small track had been read to EOF.

## Phase 10 — REFUTED: the `BUFFER_TOO_LARGE` refusals are not what makes the queue diverge

Phase 9's remaining inference was that the DDJ's queue backs up *because* Wine
refuses `GetBuffer` on the exclusive client. That has now been tested and it is
**wrong**.

### The test

`debug/wip-exclusive-buffer-contract.diff.txt` applied to `alsa.c.pre-dbg` — the
exact base the currently installed shipping driver was built from, so this is a
genuine one-variable change — built and installed as the system `winealsa.so`
(reversal recorded in `PATH-TO-GOLD.md`). Run `runs/QUEUE/20260819T063207-dblbuf.log`,
PC MASTER OUT on, track playing, 60 s.

The patch demonstrably does what it claims:

    RBW-DBLBUF exclusive: advertising 256 frames, ring 1024, period 256
    RBW-TOOBIG lines: 0                     (was ~158,000 per second)
    RBW-GETOK  GetBuffer succeeded 390-403 times in the last second (asked 256)

### The result: the fault survives, and cycles faster

    baseline (shipping driver)  teardowns at  3.0, 18.8, 34.7 s   -> ~15.9 s apart
    patched  (no refusals)      teardowns at  3.2, 12.1, 29.2,
                                              37.5, 46.3, 55.0 s  -> ~8.5 s apart

`trim_count` still climbs to 100 on the DDJ device and still resets into an
announce; the queues still collapse to `[0, 0]` on each teardown. Removing every
single refusal did not stop the queues diverging. **The refusal storm is a
separate Wine inefficiency, not the cause of this fault.** T03's original
instinct to set it aside was right after all, for a reason it did not have: not
because it is harmless in the healthy arm, but because eliminating it changes
nothing in the broken one.

### What the negative result nevertheless tells us — the divergence is a TIME drift

The threshold rekordbox applies is a **count of buffers** (4), but the two arms
advertise different buffer sizes, so that count is worth different amounts of
time:

    baseline  1024 frames advertised = 23.2 ms/buffer  -> 4 buffers = 92.9 ms
    patched    256 frames advertised =  5.8 ms/buffer  -> 4 buffers = 23.2 ms

and the observed time to reach the threshold shortened with it — 15.9 s to
8.5 s. A fault that scales with the *time* the threshold represents, rather than
with the buffer count, is a **drift**: the DDJ and the PC endpoint consume audio
at slightly different rates, and the gap accumulates until it crosses whatever
the threshold currently is worth.

Implied drift rate: ~92.9 ms per 15.9 s = 0.58%, and ~23.2 ms per 8.5 s = 0.27%.
Both are one to two orders of magnitude larger than real hardware clock
tolerance (~0.01%), and both are larger than the 0.05-0.11% that `dualclient`
measured between the same two endpoints outside rekordbox — so the numbers do
not yet agree and the drift may not be steady.

### Next action — measure the SHAPE of the divergence, not just its endpoint

Extend `bin/queuescope.py` with a `--trace` mode that writes every sample
(~50 Hz) to a TSV, and look at how the spread grows between two teardowns:

    a straight ramp  -> a genuine constant rate difference between the devices
    a staircase/step -> the DDJ stalls in discrete events and never catches up

Those two point at completely different Wine bugs, and the traces distinguish
them in one 60-second run. Do it on the **baseline** driver, which is both the
reference measurement and the daily configuration.

## Phase 11 — CORRECTION: it is not a drift. It is a discrete event every 15.9 s

Phase 10 inferred a drift from two endpoints (15.9 s at 1024-frame buffers,
8.5 s at 256). The 50 Hz trace refutes that inference outright.

`bin/queuescope.py --trace`, baseline driver restored, PC MASTER OUT on, 75 s
(`runs/QUEUE/20260819T0648*-trace.tsv`, 3717 samples at 50 Hz). Teardowns at
**9.8, 25.7, 41.5, 57.4, 73.2 s** — intervals of **15.9, 15.8, 15.9, 15.8 s**.

The trajectory within one 15.9 s window, DDJ = b, PC = a:

    t_rel   depth_a  depth_b  spread  trim_b
     1.49      3        3        0       0
     ...      (flat, every sample, for FOURTEEN AND A HALF SECONDS)
    14.57      3        3        0       0
    15.11      3        5        2      16
    15.66      3        5        2      87      -> 100 -> announce -> teardown

There is no ramp and no staircase. The system is **perfectly stable** — spread
0, trim counter 0, not one trim — for 14.5 s, and then fails completely inside
about one second.

**A drift cannot produce that.** A rate difference between two devices would show
the spread creeping up through 1, 2, 3 over the window. It never leaves 0. And
the interval is regular to within 0.1 s across four cycles, which accumulation
would not be either.

So the causality is the reverse of what phases 9-10 assumed. The queue imbalance
is not what sets the period; **something fires on a fixed ~15 s period and
disrupts the DDJ stream**, and the watchdog — behaving exactly as designed —
notices the resulting imbalance, trims ~100 times in about a second, and
announces a device change.

This puts the 15000 ms timer found statically in phase 5 back at the centre:

    0x141334c64:  lea rcx,[rsi+0x1f0]; mov edx,4; mov r8d,0x3a98   ; startTimer(obj, id 4, 15000 ms)

15000 ms of timer plus ~0.9 s of trim storm and teardown is 15.9 s. That is the
period, exactly, and it is the question the user asked at the start of this
thread — *what does the id-4 callback check* — arriving from the other end.

### What phase 10 still establishes

The exclusive-buffer patch remains refuted as a cure (the fault survived it
completely), and the refusal storm remains a real but separate Wine
inefficiency. What phase 10 got wrong was only the *interpretation* of the two
periods; with the patched driver the interval was 8.9/17.1/8.3/8.8/8.7 s, which
is better read as a ~8.6 s periodic trigger with one skipped cycle than as a
drift rate.

### Next action — identify the 15 s event

Leading candidate, from phase 5: rekordbox rewrites its settings file on a
~16 s cadence. If that write stalls the audio thread under Wine, it would
produce exactly this signature. The test is cheap and direct: poll the mtime and
size of
`prefixes/rb7/.../Pioneer/rekordbox6/rekordbox3.settings` at 20 Hz beside a
`queuescope --trace` run and check whether each write lands in the same 100 ms
as each spread excursion. Correlation there names the trigger in one run.

## Phase 12 — the id-4 callback, identified and read

The question that opened this thread — *what does the id-4 15 s callback check?*
— is answered. The static route was blocked (the MultiTimer sub-object's vtable
is installed by a base constructor, not by `FUN_141334260`), so it was resolved
from live memory instead.

### The walk

`FUN_141334260` stores its `param_1` into a global in its prologue:

    141334285:  mov QWORD PTR [rip+0x4943f54],rcx        # 0x145c781e0

so the manager is a singleton at a known address. Reading it out of a running
process and following it:

    manager singleton @0x145c781e0 = 0x518e08b0
    timer sub-object  @manager+0x1f0
    its vtable        = 0x1436cb970
    COL base-offset   = 0x1f0                     <- matches the sub-object offset
    CLASS             = .?AVBrowseBasicView@browse@@

**The 15 000 ms timer belongs to `browse::BrowseBasicView` — the library browser
panel.** Not the audio engine, not a device manager. The vtable has two slots
(`~MultiTimer`, `timerCallback`), so slot 1 is the callback.

### The dispatch table — 0x141338de0

    timerCallback(this = &view->multiTimer, timerId):
        rcx - 0x1f0  recovers the BrowseBasicView
        id 0 -> FUN_14132aea0(view, -10)
        id 1 -> FUN_14132aea0(view, +10)
        id 2 -> FUN_14132ba30(view)
        id 3 -> FUN_14132bde0(view)
        id 4 -> FUN_141336370(view)        <- the 15 s one
        else -> ret

### What id 4 does — FUN_141336370

    if (!FUN_1419989c0(0) && !FUN_141aa13d0()) {
        view->b_6b9 = 0;
        obj = FUN_1413aea60(view->[0x228]);
        if (!obj) goto done;
        c = view->b_6b9;
    } else {
        mgr = FUN_141cc4270();             // the same singleton the audio path uses
        if (FUN_141cf11b0(mgr)) {          // <-- reads a named setting
            ... lazily construct singleton DAT_145d76740 under a critical section ...
            FUN_1419fc9c0(singleton, &lambda_capturing_view);
            return;                        // dispatch the sync task and stop here
        }
        view->b_6b9 = 0;
        obj = FUN_1413aea60(view->[0x228]);
        if (!obj || view->b_6b9 == view->b_6ba) goto done;
    }
    FUN_1413e59a0(obj, c);
    done: view->b_6ba = view->b_6b9;

`FUN_141cf11b0` lazily builds a settings singleton (`DAT_145e52430`) and looks up
one key by name. Reading that key's `juce::String` out of the live process:

    DAT_145e34fb0 -> 0x270c610 -> "EnableLibrarySync"

**The id-4 callback checks `EnableLibrarySync`**, and when it is on it dispatches
a library-sync task.

### And that closes off the obvious workaround

`EnableLibrarySync` is already **`val="0"`** in this prefix. The sync branch is
therefore *not* being taken, and the fault happens anyway. So "turn library sync
off" is not a fix — it is already off. The work that costs the time must be in
the other path: `FUN_1413aea60(view->[0x228])` and `FUN_1413e59a0(obj, c)`.

### Caution — the timer is not yet PROVEN to be the trigger

Everything linking this timer to the audio fault is still circumstantial: it is
the only 15000 ms timer in the binary, and the audio cycle is 15.85 s. But a
repeating JUCE timer would fire every 15.00 s regardless of the teardown, and
the measured period is consistently ~0.85 s longer than that — which is exactly
the length of the trim-storm-plus-teardown. That is equally consistent with the
period being set by the *cycle* rather than by a free-running timer, and it is
the reason the next step is a direct test rather than more reading.

## Phase 13 — the id-4 timer is NOT the trigger, and no JUCE timer is

### The direct test: neuter the callback in the live process

With `ptrace_scope` at 0, a single byte can be written over the callback's
entry to make it a no-op, with no rebuild and no restart:

    original byte at 0x141336370: 0x48   ->  wrote 0xC3 (ret)  ->  restored 0x48

`bin/queuescope.py` for 70 s with the callback neutered:

    trims on the DDJ device : 422        (baseline 410-511)
    trim_count resets       : 5          (baseline 4-5)

**Identical.** The fault does not care whether the id-4 callback runs. So
`browse::BrowseBasicView` timer 4 is not the trigger, despite being the only
15000 ms timer the static search could find.

### bin/timerscope.py — every live JUCE timer, its period, and its owner class

Written because the static search was demonstrably incomplete: timers are also
armed through `FUN_14100f010(owner, id, ms, lambda, flag)`, which passes the
period as an ordinary argument, so the literal can sit nowhere near the call.

It scans writable memory for the timer entry vtable (`0x145531008`), then reads
`+0x10` period, `+0x18` owner, `+0x20` id, and decodes each owner's class from
its RTTI. On a running rekordbox: **168 timer entries, 121 live**. Sorted by
period:

    300000 ms  id 4   MainComponent
     60000 ms  id 1   rb::app::service::product_registration::TimeController
     15000 ms  id 4   browse::BrowseBasicView          <- the only one, and it is innocent
      1000 ms  id 0   MainComponent
      1000 ms  id 1   djplay::WidgetLoudView  (x4)
      1000 ms  id 4   RecControlPanel  (x2)
       500 ms  ...    StatusBar, SettingIF, BrowseListViewer, PreviewComponent, ...

**Exactly one JUCE timer in the entire process has a 15000 ms period, and
neutering its callback changes nothing.** So the 15.000 s interval does not come
from the JUCE timer system at all.

### Where that leaves the hunt

The interval is 14.99/14.97/15.01/14.99 s measured from each teardown, which is
a timer being *re-armed by the teardown* and expiring 15.000 s later. Candidates
that are not JUCE timers:

- **`WaitForMultipleObjects(2, {this+0x48, this+0x50}, FALSE, 15000)`** at
  `0x14293e4fb`, in `0x14293e410..0x14293e511`, returning true only for
  `WAIT_OBJECT_0`. Confirmed as `KERNEL32!WaitForMultipleObjects` by parsing the
  import descriptors directly (`objdump -x` prints hint numbers, not names, for
  this binary — parse the IAT yourself). A wait that something signals at each
  teardown and that then times out exactly 15.000 s later fits the measurement
  precisely. **This is the leading candidate and the next thing to test.**
- The remaining unexamined 15000 sites: `0x141957ddb`/`0x141959e00`
  (`mov edx,0x3a98; call 0x141d2f1e0`), `0x1419d4fe0`, `0x141b97679`,
  `0x141ba5418`, `0x141d31092`/`0x141d32a6a` (stack argument),
  `0x142cde144` (`r9d`, `call 0x142cdbea0`).

### The technique that made all of this cheap, for the next session

Three things turned a week of inference into a day of measurement, and they
generalise:

1. **The image is mapped at its preferred base**, `0x140000000`, with no ASLR
   shift, so every address from static analysis is directly usable at runtime.
2. **`/proc/<pid>/mem` is enough.** Reading needs no debugger and perturbs
   nothing; `queuescope`, `timerscope` and the string reads all work this way.
   Objects are found by scanning writable anonymous memory for a known vtable,
   then decoding the class from RTTI in the image on disk.
3. **A one-byte write is a hypothesis test.** Writing `0xC3` over a function's
   first byte disables it for one measurement and is restored just as easily.
   This refuted the id-4 timer in a single 70-second run, where reading more
   decompiled code would have taken hours and settled nothing.

Do **not** use gdb breakpoints for this. Two attach/detach cycles this session
left rekordbox in a Wine crash dialog, and the follow-up measurement then read
"queues empty, counters zero", which looks exactly like a fixed application.

## Phase 14 — the `WaitForMultipleObjects(15000)` candidate is refuted too

`0x14293e410` turned out to be a synchronous cross-thread request:

    ResetEvent(this->[0x48]);                       // the reply event
    SetEvent(this->[0x40]);                         // wake the worker
    WaitForMultipleObjects(2, {this->[0x48], this->[0x50]}, FALSE, 15000);
    return (result == WAIT_OBJECT_0);

(imports confirmed by parsing the IAT: `SetEvent` `0x143374560`, `ResetEvent`
`0x143374708`, `WaitForMultipleObjects` `0x143374818`.) Four call sites, all in
`0x14288f680..0x142890626`.

### The test — change the timeout, see if the fault's period follows

The immediate lives at `0x14293e4ee`. Poked live from 15000 to **60000** ms:

    original imm32: 983a0000 = 15000 ms
    patched  imm32: 60ea0000 = 60000 ms

`bin/queuescope.py` for 100 s with the timeout quadrupled — collapse intervals:

    16.02, 15.85, 16.08, 15.83, 15.95 s

**Unchanged.** (Control immediately before the poke: 3 announces in 45 s.) A
trigger whose period is that timeout would have moved to ~60 s. Restored.

### Candidate list, updated

Refuted so far: the JUCE timer system entirely (phase 13), `BrowseBasicView`
id 4 (phase 13), this `WaitForMultipleObjects` (phase 14).

Still unexamined 15000 sites:

    0x141957ddb, 0x141959e00   mov edx,0x3a98 ; call 0x141d2f1e0   (2-arg)
    0x1419d4fe0, 0x141b97679, 0x141ba5418   mov edx,0x3a98
    0x141d31092, 0x141d32a6a   mov [rsp+0x30],0x3a98              (stack arg)
    0x142cde144                mov r9d,0x3a98 ; call 0x142cdbea0
    0x141070456                mov eax,0x3a98 ; call 0x1428a2690

But note the period need not be a literal 15000 at all — it could be computed
(15 * 1000), read from a setting, or come from Wine rather than rekordbox.
Enumerating constants is no longer the cheapest route.

### Change of tactics — attack from the effect, not the constant

The signature to chase is sharp and layer-agnostic: **something blocks the DDJ
hand-off for ~46 ms once every 15.000 s**, while the ALSA stream underneath
stays perfectly healthy (phase 11). So instead of guessing which timer, find
which *thread* is doing something at that instant.

`bin/threadpulse.py` (next): sample every thread's `utime+stime` and run state
from `/proc/<pid>/task/*/stat` alongside the queue depths, then compare the
1 s window around each collapse against the quiet baseline. Three outcomes,
each of which names the next move:

- a thread burns ~46 ms of CPU in that window  -> identify it and read what it runs
- the audio thread sits blocked (state D/S in a futex) -> it is waiting on a lock
  or on Wine; `wchan` says which
- nothing shows                                -> the stall is inside a Wine call,
  and the answer is an RBW probe in mmdevapi/winealsa timing every client call

## Phase 15 — nobody is busy when it happens

`bin/threadpulse.py` (new) samples every thread's `utime+stime` and run state
from `/proc/<pid>/task/*/stat` beside the queue depths, at ~78 Hz, and compares
the window around the event with a quiet window from the same cycle.

The first run windowed on the **collapse** and found a big signal: the main
thread +0.201 s/s, a second thread +0.109 s/s. That was wrong — the window
`c-1.2 .. c-0.1` spans the spread onset, the trim storm *and* the teardown, so
it credits the teardown's own work to whatever performs it.

Re-windowed on the **spread onset**, which is where causation lives:

    spread onsets:      8.95, 24.84, 40.74, 56.67, 72.80
    onset -> collapse:  0.85, 0.85, 0.96, 1.02, 0.87 s

    excess   fault   quiet       tid  thread
    +0.011   0.112   0.100   3785139   <- born mid-measurement, quiet is meaningless
    +0.010   0.116   0.106   3785018
    +0.009   0.009   0.000   3785295   <- born mid-measurement
    ...

**No thread has a meaningful CPU excess at the onset.** Nothing is computing.
The `wchan` snapshot taken during an excursion agrees: 186 of 188 threads sit in
`futex_do_wait`, `do_epoll_wait` or `anon_pipe_read`, and the two that are
running are the ones that run all the time.

So the ~46 ms is **not work** — it is a gap. Something stops the DDJ's client
being serviced for two buffer periods, without anybody doing anything.

(The probe flags threads created inside the measured span rather than ranking
them, because a per-thread CPU probe that reports 0 for threads born mid-window
is precisely the artefact that produced a confident and wrong "no thread does
any audio work" earlier in this project. rekordbox recreates its audio threads
on every teardown, so every cycle manufactures fresh ones.)

### The experiment this points to

If the DDJ stream stalls for ~46 ms every 15 s, that stall should be there **in
the healthy arm too** — with PC MASTER OUT off, the engine simply has no second
queue to measure it against, so `depth - min(depth)` is always 0 and the
watchdog can never fire.

That is a sharp, cheap prediction and it discriminates cleanly:

    DDJ queue jumps 3 -> 5 every ~15 s with PC MASTER OUT OFF as well
        -> the stall is a property of the DDJ/exclusive stream alone, the second
           device is only the yardstick, and the bug is Wine's to fix
    DDJ queue stays flat with PC MASTER OUT off
        -> the stall only exists when two clients are open, and the bug is in
           how Wine serves two clients at once

## Phase 16 — the stall does NOT exist with one device: it is a two-client fault

The phase 15 prediction was tested by switching `PCSpeakerSelected_23` from 1 to
0 in `rekordbox3.settings` — with rekordbox **killed first**, because it rewrites
that file every ~15 s and silently reverted an earlier edit (the process had
been up 49 minutes; the "relaunch" had done nothing and the measurement that
followed was of the same old process. Check the pid, not the log line.)

### Two findings, one of them structural

**1. With one output device, rekordbox does not create the queue objects at
all.** A scan of all 2325 MB of writable memory found **zero** objects carrying
the device vtable `0x145550178`, while `"DDJ-400 WASAPI"` still appears 44 times.
So the engine takes a different, simpler path when there is a single output —
the watchdog of phases 8-9 has nothing to police because the objects it polices
do not exist. `bin/queuescope.py` was also fixed here: it required a non-zero
last-trim timestamp to accept a candidate, which can never hold for a device
that has never been trimmed, i.e. exactly the healthy arm.

**2. There is no periodic hand-off stall in the healthy arm.** With the queue
objects unavailable, the measurement moves to ALSA, where the same event would
show as rekordbox's `appl_ptr` pausing while the hardware's `hw_ptr` runs on.
`bin/alsapulse.py --trace`, 80 s, 3955 samples at 49 Hz:

    state departures from RUNNING            : 0
    hw_ptr stalls                            : 0
    appl_ptr frozen >=25 ms while hw advanced: 0
    appl_ptr - hw_ptr                        : min 1, max 1024, mean 552 frames

The queued-ahead figure sweeps the whole 1024-frame buffer as it should, and its
dips (t = 8.22, 21.73, 44.53, 46.86, 50.34, 53.61 ...) have no 15 s periodicity.

### What that settles

The ~46 ms stall is **not** a property of the DDJ exclusive stream on its own.
It appears only when a second client is also open. Combined with phase 15 —
nothing is burning CPU when it happens — the shape of the bug is:

> With two WASAPI clients open, one of them stops being serviced for about two
> buffer periods, roughly every 15 seconds, with no thread doing any work and no
> disturbance at the ALSA layer.

That is a Wine question, and it is now precise enough to chase in Wine's own
code rather than rekordbox's.

### Caveat, recorded honestly

The two arms are not a clean single-variable comparison: the engine uses a
*different object graph* with one output than with two, not merely one fewer
device. So "the stall requires two clients" is established for rekordbox's
two-output configuration; it does not by itself prove that any pair of Wine
clients will show it.

### Next action — reproduce it without rekordbox

`upstream/dualclient.c` already opens exactly this pair (exclusive DDJ + shared
PC endpoint, both event-driven) and reported "100% of real time" for both. **It
never had the resolution to see this**: it runs 20 s and prints an integer
percentage, and a 46 ms hiccup once per 15 s is 0.23% — invisible. Give it
per-event timing: record the gap between consecutive successful service cycles
per client, keep the maximum and a histogram, and run it for 90 s. If the
exclusive client shows a ~46 ms gap on a 15 s cadence while the shared one does
not, the fault is reproduced with no rekordbox in the picture at all — which is
both the Wine bug report and the fix's test case.

## Phase 17 — `dualclient` with real resolution: Wine serves two clients cleanly

`upstream/dualclient.c` rebuilt with **service-gap timing** — the interval
between consecutive successful `GetBuffer`/`ReleaseBuffer` pairs, in integer
microseconds via `QueryPerformanceCounter`, keeping the outliers with the moment
they occurred. Two bugs in the old probe were fixed on the way:

- **`secs` was hardcoded at 20** and the numeric argument silently ignored, so
  every "90 s" run previously recorded was really a 20 s run.
- Growing the struct made the compiler emit `memcpy`, which a freestanding
  build has no CRT for; `memcpy`/`memset` are now provided in the file.

Run `runs/DRIFT/20260819T*-gaps.log`, 90 s, exclusive DDJ + shared PC at 44100
(`r44`), i.e. the same pair rekordbox opens:

    EXCL/DDJ   events 8860 (98/s)  timeouts 0  GetBuffer ok 8860 fail 0
               wrote 3974093 of 3971646 expected = 100% of real time
    SHARED/PC  events 7874 (87/s)  timeouts 0  GetBuffer ok 7874 fail 0
               wrote 3973477 of 3971646 expected = 100% of real time

    EXCL/DDJ   worst gap between service cycles:  20291 us
    SHARED/PC  worst gap between service cycles:  20766 us

**Over 90 seconds neither client ever went more than 20.8 ms unserved.** No
46 ms gap, nothing on a 15 s cadence. The fault is *not* reproduced.

That is a real result, not a null one: the earlier "both clients write 100% of
real time" could never have detected this fault, and now the same probe with
microsecond resolution still cannot find it. **Wine keeps two clients fed.**

### Where that leaves the search

The stall needs rekordbox and it needs two outputs, but it is not something Wine
does to any two clients. Differences between `dualclient` and rekordbox that are
still candidates:

1. **rekordbox drives both devices from one engine thread** (the service loop of
   phase 8 iterates the device array under per-device spinlocks), whereas
   `dualclient` gives each client its own feeder thread. A single-threaded
   servicer couples the two devices in a way two threads do not.
2. rekordbox's exclusive buffer is 1024 frames; `dualclient` was handed 1764.
3. rekordbox writes real audio through a decoder and a renderer; `dualclient`
   writes silence and does nothing else.
4. rekordbox holds ~190 threads, a GL renderer, and MIDI traffic to the *same
   USB device* that carries the audio.

(4) deserves a note: the DDJ-400 is one USB device carrying both audio and MIDI,
and this project ships a rawmidi output patch. Periodic controller traffic
stalling the audio endpoint on the same device is a plausible mechanism, though
it would have to explain why the single-output arm shows no stall at all
(phase 16 measured zero `appl_ptr` freezes over 80 s).

### Next action

Cheap and decisive about *what kind* of clock the 15.000 s is: change
rekordbox's `AudioBufferSize` and re-measure the collapse-to-onset interval with
`bin/queuescope.py --trace`.

    interval stays 15.00 s  -> a wall-clock timer, keep hunting the timer
    interval scales         -> it is driven by the audio clock / buffer count,
                               and the search moves into the engine's own
                               accounting

Also worth ten minutes first: grep Wine's `mmdevapi`/`winealsa` sources for a
15-second constant.

## Phase 18 — the buffer-size discriminator: it is a wall-clock alarm

`AudioBufferSize` changed 256 -> 512 in `rekordbox3.settings` (rekordbox killed
first), PC MASTER OUT on, everything else identical.
Run `runs/QUEUE/20260819T*-buf512.tsv`, 90 s:

    quantity                256 frames        512 frames
    ------------------      --------------    --------------
    collapse -> onset       15.00 15.01       13.65 13.65
    (the quiet interval)    14.99 14.97       13.65 13.69
    onset -> collapse       0.85 0.85         1.68
    (the trim storm)        0.96 1.02 0.87
    collapse -> collapse    15.85 15.9        15.33 15.35 15.33 15.35
    steady-state depths     [3,3]             [3,3]  (3702 of 4408 samples)

**The trim storm doubled** — 0.87 s to 1.68 s — exactly as the phase 8 model
requires: the storm is 101 trims and trims arrive one per buffer period, so
doubling the period doubles the storm. That is a clean independent confirmation
of the mechanism.

**The quiet interval barely moved**: 15.00 -> 13.65 s, a 9% change for a 2x
change in buffer size. An audio-clock quantity would have halved or doubled; a
fixed number of buffers would have gone to 7.5 s or 30 s. It did neither.

So the alarm is **wall clock, at approximately 15 seconds**, and the small
residual change is consistent with it being re-armed at a point in the
teardown/reopen sequence whose own duration depends on the buffer size.

### Consequence for the search

The 15 s timer hypothesis survives; only the candidates so far have died. Ruled
out to date: every JUCE timer in the process (phase 13, `bin/timerscope.py`
inventories all 121), `browse::BrowseBasicView` id 4 (phase 13, poked),
`WaitForMultipleObjects(...,15000)` at `0x14293e4fb` (phase 14, poked), and any
15-second constant in Wine's `mmdevapi`/`winealsa` sources (grepped, none).

### Next action — stop guessing which timer, watch the scheduler

Nothing burns CPU at the onset (phase 15), so the event is a wakeup, not work.
`perf record -e sched:sched_wakeup,sched:sched_switch -p <pid>` samples exactly
that without stopping the process, and its timestamps can be aligned to the
onset windows from `queuescope --trace`. The question it answers directly:
**which thread wakes up, and what wakes it, 15.000 s after every teardown?**

If `perf` is unavailable, the fallback is an RBW probe in winealsa that
timestamps every client service on the exclusive stream and reports gaps,
measuring inside Wine what `dualclient` could not reproduce from outside.

## Phase 19 — CORRECTION to phase 9's "the spread reaches 4", and a null result on wakeups

### The correction

`bin/queuescope.py` computed `spread = max(depths) - min(depths)` across **every
device object it found**. `find_devices` returns stale objects from earlier
stream generations as well as the live pair, and those sit at 0 for ever. So
every reading was measured against a floor of zero.

Counting the 90 s buffer-512 trace properly:

    spread between the two LIVE devices        : 0 -> 3976 samples, 1 -> 58,
                                                 2 -> 383, 3 -> 40
    spread as queuescope reported it (all four): 3 -> 3707, 4 -> 93, 5 -> 383

**The live pair's queues never part by more than 3.** The "max spread 5" in
phases 9-18, and the line "the spread reached the engine's own trim threshold
(>=4)", are artefacts of including dead objects. Fixed: the metric now ignores
devices that never showed any depth, and the summary no longer claims the
threshold was reached.

### What still stands, unchanged

These were observed directly and do not depend on the broken metric:

- `trim_count` on the DDJ device climbs to ~100, resets, and an announce follows;
  the queues then collapse to `[0,0]` — the teardown.
- The period: 15.85 s at 256-frame buffers, 15.33 s at 512.
- The DDJ device is trimmed 584 times to the PC endpoint's ~15 in 90 s: the
  imbalance is real and it is one-sided.
- The trim storm's duration scales exactly with buffer size (0.87 s -> 1.68 s).

### What it changes — and a hypothesis it strengthens

The engine trims when `depth - min(depth over its device array) >= 4`. If that
array contained only the two live devices, min would be 3 and nothing would ever
trim, because neither queue reaches 7. Trims plainly do happen. So either

  (a) **the engine's array includes objects whose queues are empty** — making
      min 0, so any device reaching 4 is trimmed. This fits the evidence
      unusually well: the DDJ peaks at 5 and is trimmed 584 times; the PC
      endpoint stays at 3 and is trimmed ~15 times; and the healthy arm has no
      such objects at all (phase 16); or
  (b) the engine compares values sampled at moments a 50-80 Hz probe cannot see,
      one queue reading 0 transiently.

(a) is testable: re-read `engine+0x3c8`/`+0x3d4` and walk the array, checking
whether every entry is one of the live pair. That needs the engine pointer,
which comes from one gdb stop at `0x140fe442f` (`engine = r8 - 0x3f0`).

### The null result

`bin/threadpulse.py` extended to nanosecond CPU and scheduling counts from
`/proc/<pid>/task/*/schedstat` (tick-based `utime` is quantised at 10 ms, the
same order as the event). Over 90 s and 6 cycles:

- no thread has a meaningful CPU excess at the onset — the largest is +2.7 ms
  per cycle, on the short-lived audio threads, which is the trim work itself;
- wakeup *rates* in the fault and quiet windows match once normalised for window
  length (16.7/s vs 15/s);
- **no thread wakes on the onsets at all.** Listing every thread scheduled
  between 1 and 40 times in the whole run gives threads on 3 s and 5 s cadences
  (`wine_threadpool` every 5.0 s) and none aligned with the onsets at 5.7, 21.1,
  36.4, 51.8, 67.1, 82.4 s.

So the trigger is not a thread waking up, and it is not a burst of work. Taken
with phase 17 (Wine serves two clients with a worst gap of 20.8 ms over 90 s),
the "something stalls the hand-off for 46 ms" framing may itself be wrong — it
rests on the same depth readings the correction above undermines.

### Where to restart

The honest position is that the *consequence* chain is solid — trim storm,
announce, teardown, reopen, 15.9 s — and the *cause* of the imbalance is not yet
known. The single most informative next step is (a) above: get the engine
pointer once and enumerate its actual device array, which decides whether the
trim threshold is being crossed because an empty stale device is dragging the
minimum to zero. That would make the fault a rekordbox bug that Wine merely
exposes, and it would explain every asymmetry seen so far.

## Phase 20 — measured at 114 kHz: the threshold IS crossed, and phase 19 over-corrected

Phase 19 was right that `queuescope`'s spread metric was contaminated by stale
device objects, and right to fix it. It was **wrong** to conclude from an 80 Hz
probe that the live queues never part by 4. They do — the events are just far
too brief for 80 Hz to see.

### Two things had to be fixed before this measurement was worth anything

1. **gdb attach has now crashed rekordbox on all three attempts.** The device
   array read below survived (the breakpoint printed before the detach), but the
   first attempt at this burst measurement ran against an application sitting in
   a Wine "Program Error" dialog and returned a beautifully consistent
   `A=0, B=1, spread=1` at 216 kHz. Always confirm the app is alive and playing
   before believing a clean-looking result.
2. `find_devices` returns stale objects, so the live pair must be chosen by
   observed activity, not by position.

### Hypothesis (a) from phase 19 is refuted

One gdb stop at `0x140fe442f`, `engine = r8 - 0x3f0`:

    engine   = 0x52a841a8
    ndevices = 2
    devarray = 0x4e5b3eb0
      [0] dev=0x1f3c5f50  slot=1
      [1] dev=0x1f3c6490  slot=1

Exactly the two live devices. **No stale objects in the engine's array**, so the
minimum is not being dragged to zero by dead entries.

### The burst measurement — 4,550,396 samples in 40 s at 114 kHz

    depth DDJ (exclusive) : 0->627352  1->5920  2->5044  3->3613821
                            4->60114   5->238135  6->10
    depth PC   (shared)   : 0->622817  1->9870  2->55805  3->3860062  4->1842

    signed spread (DDJ - PC):
        0 -> 4245150     1 -> 231807     2 -> 29255
        3 -> 35472       4 -> 2112       (and small negatives)

    samples with spread >= 4  :  2112   =  0.046%

**The trim threshold is crossed, in 0.046% of samples.** At 80 Hz that is one
sample every 25 seconds — which is exactly why the slower probe saw nothing and
why phase 19's correction went one step too far. Phase 8's mechanism stands as
originally stated.

### And the device that gets ahead is the DDJ

Names read from `device+0x18` in the same live process:

    reaches 4-6, gets trimmed : "DDJ-400 WASAPI"          "Windows Audio (Exclusive Mode)"
    stays at 3                : "Speakers (Out: default)" "Windows Audio"

This confirms phase 9's identification by an independent route and at 1400x the
sampling rate.

### Net position after phases 8-20

Solid, and measured:

- The engine trims a device when its queue exceeds the shallowest device's by 4;
  101 such trims less than 100 ms apart make it announce a device change, which
  destroys and rebuilds both streams ~0.9 s later, every 15.9 s (256-frame
  buffers) or 15.3 s (512).
- The device that overruns is always the **DDJ, in exclusive mode**; the shared
  PC endpoint stays level.
- The threshold is genuinely crossed, briefly and often enough to matter.
- The trim storm's length scales exactly with the buffer period, as the
  "101 trims" model requires.
- With one output device the engine does not even create these objects, so the
  fault cannot occur.

Not yet known: **why the DDJ queue overruns.** Wine serves two clients with a
worst-case gap of 20.8 ms over 90 s (phase 17), no thread wakes or burns CPU at
the onset (phases 15, 19), and the ALSA substream never stalls (phase 11). The
overrun is brief and bursty rather than a steady drift.

### Next action

Trace the *fine* structure. `bin/queuescope.py --trace` at 80 Hz cannot resolve
a 0.046% event; the burst sampler can. Log every sample of both depths at
~100 kHz for one full cycle and find where in the 15 s the `>= 4` excursions
cluster: uniformly (and the storm is a threshold-crossing in their *rate*), or
bunched at the end (and something really does change at 15 s). That single
histogram decides whether there is a 15 s trigger to find at all, or whether the
period is simply how long it takes for the excursions to become dense enough to
put 101 trims inside 100 ms windows.

## Phase 21 — the trigger is real: 100% of threshold crossings are in the last 3 s

`bin/queueburst.py` (new) samples both queue depths as fast as `/proc/<pid>/mem`
allows, records only the start of each `spread >= 4` excursion and each sustained
teardown, and histograms the excursions by their offset into the cycle. This is
the test that decides whether a 15 s trigger exists at all, or whether the period
is merely how long it takes for crossings to become dense enough that 101 of them
land inside consecutive 100 ms windows.

Run of 75 s, `AudioBufferSize` 512, PC MASTER OUT on:

    9,358,808 samples in 75.0 s = 125 kHz
    threshold crossings : 79
    teardowns           : 5   at 10.0, 25.3, 40.7, 56.1, 71.5 s
    cycle lengths       : 15.33, 15.38, 15.37, 15.37 s

    crossings by seconds since the teardown that began the cycle:
        0-1 .. 12-13 s       0
            13-14 s         12  ##########
            14-15 s         45  ########################################
            15-16 s          7  ######

    in the last 3 s of each cycle: 64 of 64  (100%)

**Zero crossings in the first thirteen seconds of every cycle, then all of them
at once.** The answer is unambiguous: the period is *not* an emergent density
effect. Something fires on a clock, ~13.65 s after each teardown, and the trim
storm follows within about 1.7 s.

This also matches the phase 18 measurement from the other direction: the quiet
interval was 13.65 s at 512-frame buffers and 15.00 s at 256.

### Why this is a timer and not slow drift

A drift accumulating toward a threshold would cross 1, then 2, then 3, then 4
progressively, and its timing would wander with load. Instead the queues are
*exactly* balanced for 13 seconds — not one crossing — and the first crossing
lands at 13.65, 13.65, 13.65, 13.69 s after each teardown. That is a spread of
0.04 s on a 13.65 s interval, 0.3%. Accumulation processes are not that
repeatable; alarms are.

### The state of the hunt

The trigger exists, it is a wall clock, and it is re-armed by the teardown. What
it is *not*: any of the 121 live JUCE timers (phase 13), `BrowseBasicView` id 4
(phase 13, poked to a no-op), `WaitForMultipleObjects(...,15000)` (phase 14,
timeout quadrupled with no effect), any 15 s constant in Wine's audio drivers
(grepped), a thread wakeup or a burst of work (phases 15, 19 — nothing wakes and
nothing computes at the onset).

### Next action

Two routes, in order of cost:

1. **Widen the constant search beyond 15000.** The interval is 13.65 s at one
   buffer size and 15.00 s at another, so the literal need not be 15000 at all —
   it may be a period in a different unit (seconds, ticks, samples) or computed.
   Search for 13650/15000/15/1000-scaled values *and* for timeouts passed to
   `WaitForSingleObject`, `SleepConditionVariable*`, `timeSetEvent`, and
   `CreateWaitableTimer` anywhere in the binary.
2. **Install `perf`** (needs root; `kernel.perf_event_paranoid` is 2 and would
   need lowering, both reversible and recordable) and trace
   `sched:sched_wakeup` + `syscalls:*` for one cycle, aligned to the onset
   window from `bin/queueburst.py`. Nothing wakes *often*, but something must
   run at that instant; a whole-system trace across a 200 ms window is small and
   would name it outright.

## Phase 22 — perf: rekordbox never arms a 15-second timer

`perf` installed (recorded in `PATH-TO-GOLD.md` with reversals, along with
`kernel.perf_event_paranoid=-1` and `kernel.kptr_restrict=0`). Note tracefs is
not readable by an ordinary user here, so `perf list` shows zero tracepoints and
every `perf` invocation must be run under `sudo`.

### The query

Every hrtimer armed by rekordbox carries its absolute expiry, so the timeout is
`expires/1e9 - timestamp`. Tracing `timer:hrtimer_start -p <pid>` for 10 s
captured **3,405,696 events — 340,000 timer arms per second**, which is Wine's
timer-driven waiting showing up in the kernel. Of those, 2770 had a timeout over
0.5 s. Aggregated by value:

    0.299 s  x1        0.300 s  x2427     0.500 s  x1088
    0.950 s  x166      1.000 s  x773      1.001 s  x9
    2.002 s  x93       3.000 s  x21       4.000 s  x2
    5.000 s  x8       20.001 s  x550     25.025 s  x62

**There is no 13.65-second and no 15-second timer anywhere in the process.**
Every long timeout is a wait that is re-armed constantly (the 20.001 s one is
re-armed every ~17 ms), i.e. a `WaitForSingleObject`-style timeout that keeps
returning early, not an alarm that is allowed to expire.

### What that rules out, and what it leaves

Combined with phases 13, 14 and 18, the trigger is **not** a JUCE timer, not a
`WaitForMultipleObjects` timeout, not any hrtimer with a 15 s expiry, and there
is no 15 s constant in Wine's audio drivers. It is nonetheless real and
repeatable to 0.3% (phase 21).

The obvious remaining shape is a **counter on a faster periodic tick**: a 500 ms
timer counting to 30, or a 1 s timer counting to 15, would produce exactly this
signature and would leave no 15-second constant anywhere to find. rekordbox has
plenty of candidates — `timerscope` lists `djplay::SettingIF` at 500 ms,
`MainComponent` at 1000 ms, `RecControlPanel` at 1000 ms, a dozen
`browse::BrowseListViewer` at 500 ms.

### Next action

Stop hunting the clock and identify the actor. With `perf` available the direct
question is answerable: trace `sched:sched_switch` for the process across two or
three cycles, align it to the onset times from `bin/queueburst.py` (both use
`CLOCK_MONOTONIC`, so `perf record -k mono` and Python's `time.monotonic()` are
directly comparable), and list the threads that run in the 100 ms before each
onset but not in the equivalent window mid-cycle.

`bin/threadpulse.py` looked for this at 80 Hz and found nothing; `sched_switch`
resolves individual context switches, which is four orders of magnitude sharper.

## Phase 23 — two results: no actor in the scheduler, and the queues are STATIC between faults

### `sched:sched_switch` finds no actor

`perf record -k mono -e sched:sched_switch -p <pid>` for 50 s (840,018 events,
104 MB), aligned to `bin/queueburst.py`'s onsets — both now report
`CLOCK_MONOTONIC`, so the two logs share a clock directly. Onsets at
374423.518636 and 374439.481345; teardowns at 374408.452960, 374424.385109,
374440.337193.

Comparing the 250 ms around each onset against three mid-cycle control windows
per cycle, the threads that appear only in the fault windows are:

    x10770  swapper/3            (the CPU going idle -- a consequence)
    x4      3807351 rekordbox.exe
    x3      243 kworker/5:1H  and a handful of one-off kworkers

Thread 3807351 looked promising until its timeline was pulled: it exists only
from just after one teardown to just after the next, and the other candidates
(3807423, 3807425) are the same. They are the **per-cycle audio threads
rekordbox recreates on every rebuild**, and their activity at the onset is the
trim work itself. No thread runs at the onset that is not already explained.

### The queues do not move between faults — which breaks my model of them

`bin/queuephase.py` was written to test a beat hypothesis: two devices on
independent clocks, serviced by one engine thread, whose deadlines drift past
each other with a beat period. A beat of 15 s from a 23.2 ms period needs only a
0.155% clock difference, which is the order `dualclient` measured. It explains a
trigger with no waker, no CPU, exact repeatability, and a two-device
requirement — everything phases 13-22 established.

The measurement refuted the *premise*. Sampling at 125 kHz for 45 s and
recording every change in either depth:

    service events: A 275   B 510      (in 45 seconds)
    all of them clustered at t ~ 0.1, 14.0-14.8, and 29.9-30.7 s
    teardowns at 14.9 and 30.7 s

**Between faults the depths do not change at all.** They sit at exactly `[3, 3]`
for thirteen seconds without a single transition, then churn for ~1.7 s, then
the teardown. If audio is flowing continuously — and it is; ALSA's `hw_ptr`
never stalls (phase 11) — then these lists are **not** per-buffer audio queues.
A per-buffer queue at 44100 Hz would show tens of thousands of transitions in
13 s, not zero.

So the phrase used throughout phases 8-21, "the DDJ's queue backs up by two
buffers", is not established. What is established is that a counted list on the
DDJ device object sits at 3, rises to 4-6 during a ~1.7 s window once per cycle,
and that the engine's trim path and its 101-trim watchdog respond to it.

### What this does and does not change

Unaffected — all directly observed:

- the trim counter climbing to ~100, resetting, and the announce following;
- the teardown of both streams and the 1000 ms reopen;
- the 15.9 s period and its 0.3% repeatability;
- the storm length scaling exactly with the buffer period;
- the DDJ (exclusive) being the device that rises while the PC endpoint holds;
- the whole cascade from `AudioIODeviceType::Listener` to `SettingIF` slot 0x10.

Now open again: **what the counted list actually holds.** It is walked through a
`+0x128` "next" pointer from `device + 0x68 + slot*8`, entries are 0x130 bytes,
and it is stable at 3 for 13 s at a time. That is the shape of a small pool of
long-lived objects — buffers held in flight, or pending device operations — not
a stream of audio blocks.

### Next action

Identify the list entries before doing anything else, because every remaining
hypothesis depends on what they are. They are heap objects of 0x130 bytes; dump
one from a live process and look for a vtable at +0 (RTTI gives the class name,
the same walk that identified `AudioDeviceWatcher` and `BrowseBasicView`), for
embedded frame counts, or for a pointer to a WASAPI buffer. `bin/queuescope.py`
already knows how to find the device objects and walk the chain, so this is a
short script, not a new campaign.

## Phase 24 — the list entries ARE audio buffers; the pool is stable because buffers are recycled

Dumping an entry from each live device's chain (0x130 bytes, walked through the
`+0x128` next pointer):

    entry +0x000  lo=6  hi=256          <- 256 is exactly AudioBufferSize
    entry +0x008  0x1858
    entry +0x010  pointer   \  the same pointer twice: the sample data and a
    entry +0x018  pointer   /  cursor into it
    entry +0x020..+0x127    payload / per-buffer state
    entry +0x128  next

The `hi` word at `+0x000` is **256**, matching the `AudioBufferSize` setting
exactly. And the DDJ entry's body is unmistakably PCM: repeating packed values
(`ffff8205 ffff8205`, `a4a45303 a4a45303`, `d3d36b04 e7e77504`) of the kind you
get from a decoded music buffer, where the PC endpoint's entry at the same
offsets holds heap pointers instead.

So these are **audio buffers after all**, and phase 23's inference from "the list
never changes" was too strong. The resolution is simple and it matters:

> The list is a **pool of three buffers that are recycled in place**. Normal
> playback cycles the same three descriptors without changing list membership,
> which is why 125 kHz sampling sees zero transitions for thirteen seconds. The
> depth only moves when the engine has to **add** buffers — i.e. under genuine
> back-pressure, when a device is not taking what it is given.

That restores the phases 8-21 reading with a better mechanism behind it. "The
DDJ's queue backs up" is right; what was wrong was imagining a continuous stream
of blocks flowing through the list. The correct picture is a steady-state pool
of 3 that grows to 4-6 on the DDJ, once per cycle, for about 1.7 s, and only on
the exclusive device.

### The corrected chain, end to end

1. Something, once every ~15 s (wall clock, re-armed by the previous teardown,
   still unidentified), makes the DDJ's exclusive stream stop accepting buffers.
2. The engine allocates extra buffers into that device's pool: 3 -> 4 -> 5 -> 6.
3. The pool now exceeds the shallowest device's by the engine's threshold of 4,
   so the engine trims the excess — repeatedly, once per buffer period.
4. After 101 trims less than 100 ms apart, it concludes the device has changed
   and calls its `AudioIODeviceType` listeners.
5. `djplay::AudioDeviceWatcher` re-broadcasts; `djplay::SettingIF` slot 0x10
   (`0x141ce4220`) stops and closes **both** streams and arms a 1000 ms reopen.
6. Fifteen seconds after that teardown, step 1 happens again.

Steps 2-5 are measured. Step 1 is the remaining unknown, and everything about it
is now pinned down except its identity: wall clock, ~15 s, re-armed by the
teardown, no thread wakes for it, no CPU is burnt, no hrtimer is armed for it,
and it does not happen with a single output device.

### Next action

The unknown is now specifically "why does the DDJ exclusive stream stop
accepting buffers for ~1.7 s once every 15 s, only when a second client is
open". That is a question about Wine's exclusive-mode client, and this project
can instrument Wine directly: add an RBW probe to `winealsa`/`mmdevapi` that
timestamps every `GetBuffer`/`ReleaseBuffer`/`GetCurrentPadding` on the
exclusive stream, records the gaps and the HRESULTs, and dumps anything over
20 ms with a timestamp. `dualclient` could not reproduce the fault from outside
(phase 17); measuring from inside Wine, in the process that actually shows it,
is the way to see what rekordbox is being told during those 1.7 s.

## Phase 25 — RBW-GAP: the DDJ stream never stops accepting. Step 1 refuted.

The probe was built to answer one question and it answered it immediately.

### The probe

`winealsa.so` rebuilt from the shipping base (`alsa.c.pre-dbg`) with `RBW-GAP`
added: per stream, the interval between consecutive **successful**
`ReleaseBuffer` calls, and for any gap over 50 ms, how many times the client
asked (`tries`), how many times Wine refused (`fails`), the last HRESULT, the
padding-poll count, and the held/bufsize frames. Timestamps are
`CLOCK_MONOTONIC`, the same clock `bin/queueburst.py` prints, so a gap lines up
directly against a queue excursion. Marker verified in the installed binary.

The discriminator was designed to be unambiguous:

    tries == 0                 the app never called GetBuffer -> the stall is
                               above Wine, inside rekordbox
    tries > 0, fails == tries  Wine refused every request -> the stall is Wine's

### The result

Four complete fault cycles (`bin/queueburst.py`: teardowns at MONO
375769.009406, 375784.142848, 375799.993154, 375815.850303; first crossings at
375783.286079, 375799.139927, 375814.996539; cycle lengths 15.13, 15.85,
15.86 s), and in the whole run the log contains **exactly one** RBW-GAP line:

    err:alsa:alsa_release_render_buffer RBW-GAP SHARED t=375642.535877
        gap=51.8ms tries=1 fails=0 lasthr=00000000 padcalls=2
        held=732 bufsize=1323 wrote=142

That is the **shared** (PC) stream, at start-up, before the measurement window,
with a single try and no refusal — an ordinary start-up hiccup.

**On the exclusive DDJ stream there is not one gap over 50 ms in four fault
cycles.** rekordbox hands buffers to the DDJ without interruption, right through
the excursion, the trim storm and the teardown.

### What that refutes

Phase 24's step 1 — "something makes the DDJ's exclusive stream stop accepting
buffers for ~1.7 s" — **is wrong**. It was the last surviving version of a
framing that has been carried since phase 15 ("something stalls the hand-off for
~46 ms"), and it is now measured to be false at the only boundary where it could
have been true. Wine accepts every buffer, on time, throughout.

So the engine grows the DDJ's buffer pool from 3 to 6 **while the DDJ is being
serviced perfectly**. The pool growth is not back-pressure from the driver.

### What the engine can actually see, and the next probe

If the pool is not growing because hand-off failed, it is growing because
something rekordbox *reads* tells it the device needs more. Its only real
sources of truth about an exclusive stream are `GetCurrentPadding` and the
event. `GetPosition` is already known not to be called at all (RBW-POS, recorded
in `debug/wip-exclusive-buffer-contract.diff.txt`).

So the next probe is a one-second aggregator on **padding**: for each stream, log
once per second the number of padding polls, the minimum and maximum padding
seen, the GetBuffer tries and refusals, and the worst service gap. Align that
series with the onsets. If padding on the exclusive stream does something
anomalous ~15 s after each teardown — a spike, a collapse, a stall in its
progression — that is what rekordbox is reacting to, and it is Wine's number to
get right.

## Phase 26 — RBW-SEC: the trigger is invisible at the Wine boundary

The second probe aggregates one line per second per stream: padding polls and
the range of padding seen, `GetBuffer` tries and refusals, successful releases
and frames handed over, and the worst service gap. Aligned against
`bin/queueburst.py` (teardowns at MONO 376107.52, 376123.40, 376139.24,
376155.12; onsets at 376122.55, 376138.42, 376154.28; cycles 15.88, 15.83,
15.88 s).

### The two streams, second by second

    EXCL / DDJ     padpolls ~240,000   padding 0..1024
                   tries ~160,000  fails ~160,000   (99.97% refused)
                   releases 43-45/s  frames ~44,032/s  maxgap 24-30 ms

    SHARED / PC    padpolls ~348      padding 441..1323
                   tries ~260      fails 0
                   releases 257-265/s  frames ~44,288/s  maxgap 20-22 ms

**Both streams are handed almost exactly 44,100 frames every second, all the way
through the excursion, the trim storm and the teardown.** The onset seconds
(376121.71/376122.72, 376137.51/376138.51, 376153.42/376154.42 on the exclusive
stream; the same seconds on the shared one) are indistinguishable from every
other second in the run — same poll counts, same padding range, same refusal
ratio, same frames delivered, same worst gap.

### What this settles

**Nothing that Wine does or reports changes at the onset.** The exclusive stream
is fed at real time, its padding sweeps its full 0..1024 range as it should, and
its service gaps stay at one buffer period. Combined with phase 25 (not one
hand-off gap over 50 ms in four cycles), the driver boundary is clean.

So the growth of the DDJ's buffer pool from 3 to 6 is **not a response to
anything Wine tells rekordbox at that moment**. The trigger is internal to
rekordbox, and it does not express itself through the audio API at all.

### A characterisation worth keeping for the eventual bug report

The asymmetry between the two clients is stark and is Wine's, even though it is
not this fault:

- the **shared** client is served on demand: 260 requests a second, **zero**
  refusals, ~170 frames per call;
- the **exclusive** client is refused **160,000 times a second** and succeeds 43
  times, taking a full 1024-frame buffer each time.

That is about a core of wasted work and 240,000 padding polls a second, and it
is worth fixing on efficiency grounds — but phase 10 already proved it is not
the cause of the teardown (removing every refusal left the fault untouched).

### Next action

The pool grows with no external cause, so find the code that grows it. The
entries are 0x130 bytes chained through `+0x128` from
`device + 0x68 + slot*8` (phase 24: they are audio buffers, header word =
`AudioBufferSize`). Find the **insert** site — the allocation of a 0x130-byte
entry and the store into that chain — and read the condition guarding it. That
condition is the trigger, and it is now known to depend on nothing the driver
reports.

`bin/queuescope.py` can supply a live entry address to anchor the search, and
the `.pdata` + RTTI tooling in `bin/pefunc.py` / `bin/pexrefva.py` is already set
up for exactly this kind of walk.

## Phase 27 — the pool insert site, its condition, and what that rules out

### The site

Six of the 149 `operator new(0x130)` call sites in the binary lie in the audio
engine at `0x140fe5xxx`, and two of them are inside **`FUN_140fe51a0`
(0x140fe51a0..0x140fe5785)** — the function the service loop calls once per
device at the top of every iteration (`FUN_140fe51a0(lVar11, &local_188,
iVar13)`, phase 8).

    void FUN_140fe51a0(device, srcbuf, n)
    {
        if (device->[0x2c] != 0) {
            if (   *(double *)(device + 0x108) == *(double *)(device + 0xf0)
                || *(int *)(device + 0x11c)    != *(int *)(device + 0x2c) / 2 )
            {
                release_lock(device + (slot + 0x1e) * 4);
                p     = &device->chain_head;      /* device + (slot + 0xd)*8
                                                     == device + 0x68 + slot*8 */
                entry = operator new(0x130);
                entry[0] = srcbuf[0];             /* channels  */
                entry[1] = srcbuf[1];             /* frames    */
                ...copy or silence the sample data...
                entry[0x4a] = entry[0x4b] = 0;
                while (*p) p = &(*p)->next;       /* +0x128 */
                *p = entry;                       /*  <-- THE APPEND  */
                spinlock_release(device + 0x78 + slot*4);
            } else {
                FUN_14297de20(device + 0x120, n * 0x14, 0);
                FUN_14297de20(device + 0x130, n * 0x14, 0);
                ...resample / mix in place, no allocation...
            }
        }
    }

So the pool grows by **appending at the tail of the chain**, and the branch is
chosen by two doubles compared for exact equality plus an integer test.

### The condition, read live — and it is not the switch

`bin/poolcond.py` (new) polls all four fields plus the queue depth. Over 70 s of
a running fault, on both devices:

    Speakers (Out: default)   +0x2c = 2   +0x11c = 0   +0xf0 = 44100.0   +0x108 = 44100.0
    DDJ-400 WASAPI            +0x2c = 4   +0x11c = 0   +0xf0 = 44100.0   +0x108 = 44100.0

    changes over 70 s : 0
    append            : 100.0%   resample : 0.0%   (both devices)

The two doubles are **sample rates**, and the test is "is the source rate the
destination rate?". Both are 44100.0, so no resampling is needed and the fast
copy-and-append path is taken. Note also `+0x11c` is 0 while `ch/2` is 1 and 2,
so the **second clause alone forces the append** regardless of the rates: in this
configuration the resample branch is dead code.

**The condition never changes and never can.** The insert is the ordinary
producer path, taken on every iteration for every device, not a switch that
flips once every 15 s.

### What that means for the search

The producer appends unconditionally. Therefore the pool depth is entirely
governed by **the consumer** — whatever pops entries off the head and writes them
to the device. In steady state the pool sits at 3 because pops match appends; it
reaches 6 because for about 1.7 s the pops fall behind by three.

And phases 25-26 already showed the device is being drained at exactly real time
throughout, with no anomaly at the onset. So the stage that falls behind is
**between the pool and the WASAPI call** — inside rekordbox, in the code that
pops.

### Next action

Find the pop. It is the mirror of the append: a read of
`device + 0x68 + slot*8`, a store of `entry->next` back into the head, and a
`thunk_FUN_1427115ec(entry, 0x130)` free. The trim path in `FUN_140fe3530`
(phase 8) already shows that exact free, so the ordinary consumer will look very
similar and is likely in the same 0x140fe5xxx cluster — the other four
0x130-byte allocation sites there (`FUN_140fe5790`, `FUN_140fe5ba0`,
`FUN_140fe5de0`) are the obvious neighbours to read first.

Then instrument the pop rate per device with the same `/proc/<pid>/mem`
technique and watch it against the onsets: the question is now narrow enough to
be a counter, not a hunt.

## Phase 28 — there is no pop. The pool is STATIC, and the engine loop is not running.

### The search for a consumer came up empty

Every `operator delete(ptr, 0x130)` in the audio engine (14 sites) is inside a
**drain loop** — `while (head) { head = head->next; free; }` — belonging to a
destructor or reset path. `FUN_140fe46f0` even reinstalls the device vtable at
`*param_1 = &PTR_FUN_145550178` as its first act. None of them is a per-buffer
pop.

### And the measurement says there is none to find

`bin/popcount.py` (new) samples the head pointer at `device + 0x68 + slot*8` and
counts every change. A pop necessarily changes it. 70 s, PC MASTER OUT on, track
playing, **20,706,133 samples at 296 kHz**:

    DDJ-400 WASAPI            head changed  155 times = 2.2 /s
    Speakers (Out: default)   head changed  582 times = 8.3 /s

    pops per second        t      DDJ      PC
                        0-13        0       0      (thirteen seconds, nothing)
                          14        8      28
                          15       30     112   <- teardown at 15.7
                          16        1       1
                        17-30        0       0      (again, nothing)

**The pool is completely static between faults.** Not one buffer is appended or
removed for thirteen seconds at a time. Every change happens in the ~1.5 s
around the teardown.

### What that forces

`FUN_140fe51a0` appends **unconditionally** (phase 27: the condition is true
100% of the time, and `device->[0x2c]` is 2 and 4, so the outer guard passes
too). If it were being called, the chain would grow on every call. It does not
grow. Therefore **`FUN_140fe51a0` is not being called**, and therefore the
engine's per-device service loop `FUN_140fe3530` **is not running** during the
quiet thirteen seconds.

Meanwhile, from phase 26, in those same thirteen seconds:

- rekordbox polls `GetCurrentPadding` on the DDJ **240,000 times a second**;
- it calls `GetBuffer` 160,000 times a second and is refused 160,000 times;
- it succeeds 43 times a second and writes 1024 frames each time;
- Wine is handed ~44,100 frames every second, exactly real time.

Those are not contradictory once separated: **the WASAPI feed thread is running
flat out and delivering real-time audio, while the engine thread that produces
the audio is not running at all.** What the feed thread delivers during those
thirteen seconds is whatever is already in the buffers — which is why T03 phase
19 measured silence at the wire and zeros in the WASAPI buffers, and why T03
recorded "the transport is stopped, not the data path".

### The picture this settles

The pool churn, the trims, the trim counter reaching 100 and the announce are
**all inside the ~1.5 s window**. They are not the cause of anything; they are
what happens when the engine finally runs again. The 15.9 s cycle is:

    ~13.6 s   the engine service loop does not run. The feed thread writes the
              stale buffer contents to both devices at exactly real time.
    ~1.5 s    the engine runs: it appends to the pools, the trim path fires
              repeatedly, trim_count reaches 101, the device-change announce
              goes out, both streams are destroyed and reopened.
    repeat

So the question was never "why does the DDJ queue back up". It is:

> **Why does rekordbox's audio engine thread stop running for thirteen seconds
> at a time, and what makes it run again?**

That also explains the engine rate directly: ~1.5 s of work per 15.9 s cycle is
~0.09x, and the measured rate is 0.05-0.09x.

### Next action

Identify the engine thread and find out what it is waiting on. It is the thread
that executes `FUN_140fe3530`; it can be recognised at runtime because it is the
one whose activity is confined to the churn window. Concretely:

1. `bin/popcount.py` already gives the exact churn windows.
2. Sample `/proc/<pid>/task/*/schedstat` and `/wchan` through a full cycle
   (`bin/threadpulse.py` does both) and find the thread whose `run_ns` is flat
   for 13 s and jumps during the churn — that is the engine thread.
3. Read its `wchan` during the quiet period. If it sits in `futex_do_wait` for
   thirteen seconds, the next question is which lock or event, and that is
   answerable with one gdb stop for the futex address.

Note phases 15 and 19 looked for "a thread that runs at the onset" and found
none — but they were looking for a *brief* actor at a 250 ms window, not for a
thread that is idle for thirteen seconds and then works for one and a half.
Re-run the same probe with that shape in mind.

### The churn windows, and a first look at who does the work

Sampling the head pointers alongside every thread's `schedstat` for 75 s gives
the churn windows precisely:

    8.2-9.1   24.1-25.0   40.0-40.9   55.8-56.7   71.7-72.6

Five windows, **0.9 s long each, 15.9 s apart** — the same period, now measured
from the pool's own activity rather than from the teardown.

Comparing CPU in the churn windows against a quiet window from the same cycle:

       excess    churn    quiet        tid  wchan
      +0.1047   0.6516   0.5469    3821577  poll_schedule_timeout
      +0.0066   0.0082   0.0016    3822238  poll_schedule_timeout
      +0.0030   0.0232   0.0202    3820978  ntsync_schedule

No thread lights up. The busiest thread does 0.65 s of CPU per second during the
churn against 0.55 s quiet — it is busy either way, which is what the padding
spin of phase 26 looks like.

**Caveat, and it is the one this project has paid for twice:** this comparison
only counts threads present at *both* ends of a window, so any thread created
inside it is silently excluded — and rekordbox creates fresh audio threads at
every teardown, which is exactly where these windows sit. The measurement is
therefore blind in the direction it most needs to see. Re-run it with the thread
set sampled continuously, and treat "no thread lights up" as unproven until then.

## Phase 29 — the engine threads, and what they wait on

### Why earlier attempts could not find them

`bin/enginethread.py` (new) samples the thread set **continuously** and
attributes every `run_ns` increment to the window it falls in, rather than
differencing the two ends of a window. That matters because of what it found:

**the churn-correlated threads are created and destroyed every cycle.** Run to
run, and even between two runs against the same process, the top threads are
different tids each time — 3829475/3829557/3829637/3829718/3829794, then
3830442/3830559/3830636, then 3830910/3830985, then 3831223/3831344/3831423/
3831499. Every one of them was already gone when queried a minute later. Any
probe that differences window endpoints, or that looks up a thread after the
fact, is blind to them by construction. That is the same instrument fault that
produced a wrong "no thread does any audio work" earlier in this project, and it
is why phases 15, 19 and 23 all reported "no thread lights up".

With continuous sampling they are unmistakable:

    ratio    churn    quiet        tid
     23.0   0.0115   0.0003    3830442      CPU-seconds per second of wall
     17.3   0.0126   0.0007    3830559      in each phase
     17.1   0.0122   0.0007    3830636

15-23x more active during the 0.9 s churn than during the 13 s quiet stretch.

Alongside them, one **long-lived** thread (3828236) burns 0.63-0.68 CPU-seconds
per second in *both* phases, state `R`, `wchan` 0. That is the WASAPI feed
thread of phase 26 — the one polling padding 240,000 times a second and being
refused 160,000 times. It never stops, which is why audio keeps flowing.

### The wchan, and the futex behind it

During the whole quiet stretch the churn threads are blocked, every sample:

    3831423  futex_do_wait x72   futex(uaddr=0x7f6f82914030, op=0x80, val=0x0) x72
    3831344  futex_do_wait x72   futex(uaddr=0x7f6f829142b4, op=0x80, val=0x0) x72
    3831499  futex_do_wait x71   futex(uaddr=0x7f6f82914bf8, op=0x80, val=0x0) x72
    3831223  futex_do_wait x13   futex(uaddr=0x7f6f829143f4, op=0x80, val=0x0) x12
    3828880  futex_do_wait x253  futex(uaddr=0x7f6f82914684, op=0x80, val=0x0) x253

`/proc/<pid>/task/<tid>/syscall` gives the futex address without a debugger,
which is the only way to get it here — these threads do not survive long enough
to be attached to, and gdb cannot unwind Wine's PE stacks anyway (a
`thread apply all bt 8` over 191 threads produced no `0x140xxxxxxx` frame at
all, only unix-side ntdll addresses).

`op=0x80` is `FUTEX_WAIT | FUTEX_PRIVATE_FLAG`, `val=0`.

### What that memory is — and why it is a lead

All five addresses lie inside **one anonymous 64 KB read/write mapping**:

    7f6f82914000-7f6f82924000 rw-p 00000000 00:00 0

Not a file, not Wine's sync section — an ordinary unix-side heap arena. A Win32
thread waiting on a Win32 event does not look like this: Wine implements those
through ntsync ioctls or the wineserver (the main thread's `wchan` is
`ntsync_schedule`, visibly different). A private futex on a malloc'd word with
`val=0` is the glibc `pthread_cond_wait` / `pthread_mutex_lock` pattern.

**So these threads are not waiting on an application event. They are blocked
inside a unix-side library call, on a pthread primitive, for thirteen seconds at
a time.** Their `comm` is `rekordbox.exe`, so they are the application's own
Win32 threads that have called down into a Wine unix library and not come back.

That is a much narrower target than anything in the previous twenty phases, and
it points back at the audio stack from a direction none of the earlier probes
covered: not the WASAPI contract, which phases 25-26 measured as clean, but the
**locking underneath it**.

### Next action

Identify which library owns those condition variables. Two cheap routes:

1. The five addresses are irregularly spaced within one arena
   (`0x030, 0x2b4, 0x3f4, 0x684, 0xbf8`), i.e. separate objects in separate
   allocations. Dump the memory around each one: a glibc `pthread_cond_t` and
   `pthread_mutex_t` have recognisable layouts, and the surrounding allocation
   will usually contain a pointer back into the owning library's data or code,
   which names it.
2. Or catch it in the act: with `ptrace_scope` at 0, read
   `/proc/<pid>/task/<tid>/stack`-equivalent information is unavailable, but a
   `perf record -e syscalls:sys_enter_futex -p <pid>` with call graphs across one
   cycle will attribute the wait to a library by return address. `perf` is
   installed; its sysctls need re-enabling as recorded in `PATH-TO-GOLD.md`.

The question to answer is simply: **who holds that lock for thirteen seconds,
and what releases it?**

### perf on the futex traffic — the churn is a burst of wakes, on a 16.0 s cadence

`perf record -e syscalls:sys_enter_futex --call-graph dwarf -p <pid>` for 40 s:
**104,806 futex entries**, 89,450 of them in that one arena. DWARF unwinding
produced **no usable stacks** (every sample block is a bare header), so the
call-graph route to naming the owning library failed; the raw events carried the
result instead.

Aggregating by address, and keeping those woken only a handful of times:

    address           waits  wakes  wake times (s)                   wakers
    0x7f6f829148ec       85      9  10.3 10.3 11.3 11.3 11.3
                                    26.3 26.3 27.3 27.3             3827982 x4, 3827628 x5
    0x7f6f84a19ac0        4      8  11.5 11.5  27.4 x6              3827628 x4 + short-lived
    0x7f6f82914624       79      4  5.9 15.9 26.0 36.0              3827628 x4

`0x7f6f829148ec` is woken in **two bursts, 16.0 s apart, each about one second
long** — the churn window, seen from the futex side. And the event stream shows
exactly what it is:

    589026.926  tid 3827979  op 0x80 WAIT     \
    589027.426  tid 3827979  op 0x80 WAIT      |  every 500.0 ms, exactly,
    589027.926  tid 3827979  op 0x80 WAIT      |  for the whole quiet stretch
    ...          (20 samples, 0.500 s apart)  /
    589036.847  tid 3827982  op 0x81 WAKE val=1     <- the burst begins
    589036.851  tid 3827628  op 0x81 WAKE val=1        (main thread)
    589036.852  tid 3827979  op 0x80 WAIT
    589037.352  tid 3827979  op 0x80 WAIT
    589037.863  tid 3827982  op 0x81 WAKE val=1

So thread 3827979 sits on a **500 ms timed condvar wait** throughout the quiet
period, and during the churn it is explicitly woken, repeatedly, by two
long-lived threads — 3827982 and the process main thread 3827628.

`0x7f6f82914624` is woken by the main thread alone at 5.9, 15.9, 26.0, 36.0 s —
a clean **10.0 s** period, which is a different heartbeat and not this fault.

### Honest status

This is a much finer-grained picture than any earlier phase, but it stops short
of naming the cause. What is now established:

- the threads that do the churn work are recreated every cycle and spend the
  quiet 13 s blocked in `futex_do_wait` on pthread primitives in a unix-side
  heap arena;
- the churn coincides with bursts of `FUTEX_WAKE` on a specific address, issued
  by two long-lived threads on a 16.0 s cadence;
- a separate thread polls that same address on an exact 500 ms timer throughout.

What is not established: which library owns the arena, and which of these wakes
is cause rather than effect. A burst of wakes at the churn is equally consistent
with "this is what starts the work" and "this is what the work does".

### Next action

Name the arena's owner. DWARF unwinding failed, so use `--call-graph fp` or
`lbr`, or trace `syscalls:sys_enter_futex` filtered to
`uaddr == 0x7f6f829148ec` with `perf probe` on the *libraries* rather than the
syscall. Alternatively bracket it from the Wine side: rebuild `winealsa` with a
probe that logs its own pthread waits, and see whether the arena addresses match
— the audio path is the one unix-side library this process is known to be deep
inside, and phases 25-26 measured its API behaviour as clean while saying
nothing about its locking.

## Phase 30 — the arena is Wine's ntdll sync layer, and phase 29's inference was wrong

### How it was named

The arena could not be identified from its contents (no back-pointers) or from
`perf` call graphs (DWARF unwinding produced no stacks at all). It was named by
catching a write to it.

1. In a fresh process the arena is `7f54823b5000-7f54823c5000`, and
   **139 of the process's threads** are blocked on futexes inside it, with
   `uaddr`s packed 8-12 bytes apart — an array of tiny per-thread words. Grouped
   by region, every other blocked thread is scattered across `[heap]` and a few
   larger anonymous mappings; this one arena holds the overwhelming majority.
2. Diffing the whole 64 KB every 2 ms for 8 s found only two words that change
   at all: `+0x0ae8` (30 times) and `+0x08e8` (twice). The arena is almost
   entirely static — 139 threads parked, rarely touched.
3. A **hardware watchpoint** on the hot word fired within seconds:

       Old value = 0   New value = 1   pc=0x7f548459656e
       Old value = 1   New value = 0   pc=0x7f54845967f4

4. Resolving those against `/proc/<pid>/maps` captured from the same process:

       0x7f548459656e -> /usr/lib/wine/x86_64-unix/ntdll.so  +0x4e56e
       0x7f54845967f4 -> /usr/lib/wine/x86_64-unix/ntdll.so  +0x4e7f4
       caller frame   -> /usr/lib/libc.so.6 +0xc09ad

5. Disassembling the installed `ntdll.so` at that offset:

       4e564:  mov  $0xc0084e85,%esi
       4e56e:  call *ioctl@GLIBC          <- the watched write
       ...     <linux_release_mutex_obj+0x50>

   and `0xc0084e85` decodes as `_IOWR('N', 0x85, 8)` =
   **`NTSYNC_IOC_MUTEX_UNLOCK`**, which is `linux_release_mutex_obj` at
   `dlls/ntdll/unix/sync.c:366`.

**The arena's owner is Wine's own `ntdll.so` — its synchronisation layer, using
the in-kernel `ntsync` driver.**

### The correction

Phase 29 inferred from "a private futex on a malloc'd word in an anonymous
arena" that these were *glibc pthread waits inside a unix-side library*, and
called it "a lead pointing back at the audio stack from a direction none of the
earlier probes covered: the locking underneath it".

**That was wrong.** The arena is not a library's private heap; it is Wine's
sync-object memory, and the waits are **ordinary Win32 synchronisation objects** —
events, mutexes, semaphores — implemented by ntdll with a userspace futex fast
path alongside the ntsync ioctls. The reasoning was sound but the premise was
not checked, and checking it took one watchpoint.

So there is no audio-stack lock here. The engine's worker threads are waiting on
Win32 sync objects, which is what worker threads do when **nothing is dispatching
work to them**.

### Where this leaves the fault

That is a mundane finding, and it is worth stating plainly: nothing in phases
25-30 has found Wine misbehaving. Measured and clean: the WASAPI contract
(phases 25-26 — both streams handed ~44,100 frames every second with no anomaly
at the onset), the ALSA layer (phase 11 — zero `hw_ptr` stalls), the two-client
case (phase 17 — worst service gap 20.8 ms over 90 s), and now the
synchronisation layer, which is doing exactly what it is supposed to.

The picture that survives all of it: **rekordbox's audio engine simply stops
dispatching work for 13.6 s out of every 15.9 s**, its worker threads park on
Win32 events waiting for that work, the WASAPI feed thread keeps shipping the
stale buffers at exactly real time, and when the engine finally runs it produces
a burst of pool churn that trips its own cross-device watchdog and tears the
streams down.

### Next action

Stop looking for a Wine defect in the audio path and find what rekordbox is
waiting for. The concrete target is the **dispatcher**, not the workers: some
thread hands work to those 139 parked threads, and it does so for 1.5 s out of
every 15.9. Two routes:

1. The wake side is already visible. `perf record -e syscalls:sys_enter_futex`
   showed the churn coinciding with `FUTEX_WAKE` bursts from two long-lived
   threads. Repeat that with the ntsync ioctls traced as well
   (`syscalls:sys_enter_ioctl` filtered to the ntsync fd) so the Win32 signal
   side is visible too, and identify the signalling thread.
2. Then attribute that thread to rekordbox code. Its Win32 call stack is
   unreachable through gdb, but a **watchpoint on the object it signals** gives
   a `pc`, and if that `pc` is in `rekordbox.exe` (base `0x140000000`, no ASLR)
   it maps straight onto the static analysis already in this theme.

## Phase 31 — THE DISPATCHER: the main thread rebuilds a 68-thread pool every cycle

### What the churn threads are doing

Sampling instruction pointers (`perf record -k mono -e cycles -F 999`) and
keeping only samples inside rekordbox's image (2898 of 48,568), the churn-only
hot addresses cluster in `FUN_142ce71c0` (0x142ce71c0..0x142ce7756). Decompiled,
it is unmistakable:

    y = b0*x + b1*x1 + b2*x2 - a1*y1 - a2*y2

a **biquad IIR filter**, four state arrays, `vfmadd213ss` throughout. The other
churn-only hot spots are `FUN_142ec6f10` (memcpy — the same routine the pool
append uses) and a handful of neighbours.

So the churn threads are doing **real audio DSP**. The engine genuinely produces
audio only during that 0.9 s burst, which is precisely the 0.06-0.09x rate.

`0x140fe7e70` — inside the phase-5 device wait loop `0x140fe7b56` — appears in
*both* phases (3 churn / 7 quiet): that is the WASAPI feed thread, which never
stops.

### It is not dispatched by a signal

`perf record -e syscalls:sys_enter_ioctl` over three cycles, with the ntsync
ioctls decoded:

    0xc0284e82  NTSYNC_WAIT_ANY    13538 total   304.5/s churn   320.0/s quiet   ratio 1.0
    0x80044e88  NTSYNC_EVENT_SET     555 total     4.0/s churn     8.2/s quiet   ratio 0.5

**No burst of Win32 event signalling at the churn** — there are *fewer* event
sets then than during the quiet stretch, and the wait rate is flat at ~300/s
throughout. Whatever starts the work, it is not a `SetEvent`.

### What actually happens: the pool is rebuilt from scratch, every cycle

`perf record -e sched:sched_process_fork -e syscalls:sys_enter_clone
-e syscalls:sys_enter_exit` over 45 s — **206 threads created, 207 exited** —
and every one of the creations is in a burst:

    68 threads in 0.322 s  starting teardown +0.993 s   parent 3839139 (main) x68
    68 threads in 0.281 s  starting teardown +0.996 s   parent 3839139 (main) x68
    68 threads in 0.281 s  starting teardown +1.000 s   parent 3839139 (main) x68

    exits:  8 exits at teardown -0.07 s
           60 exits at teardown +1.00 s   (concurrent with the creations)

**The main thread destroys and recreates a 68-thread audio worker pool on every
cycle**, and it does so at **teardown + 1.000 s** — exactly the
`startTimer(this+0xa0, id 3, 1000 ms)` reopen armed by `FUN_141ce4220`
(phase 6). That is the dispatcher, and the answer to what it dispatches is:
the entire engine, rebuilt.

### The cycle, complete

Taking the teardown as T:

    T-0.85   the churn begins: 68 worker threads run biquad DSP, the pools grow,
             the trim path fires ~101 times
    T-0.06   8 threads exit
    T+0.00   the announce lands; both streams are destroyed; queues collapse
    T+1.00   the 1000 ms reopen timer fires: the main thread creates 68 new
             threads while 60 old ones exit
    T+1.3 .. T+15.2   **nothing** — the new pool sits idle for fourteen seconds
    T+15.2   the next churn

So each generation of worker threads is created, **idles for fourteen seconds**,
does 0.9 s of audio processing, and is destroyed. Four times a minute, 272
thread creations a minute, for a 15.9 s cycle that produces about a second of
audio.

### What this changes

The engine is not "stalled" in the sense of being blocked on Wine. It is being
**rebuilt from scratch every 15.9 seconds**, and its freshly created workers do
nothing for fourteen of those seconds before finally running for one.

The open question is now sharp and it is entirely inside rekordbox: **what do
the 68 newly created workers wait fourteen seconds for, when the streams they
serve were reopened at T+1.0?**

### Next action

Instrument the gap, not the burst. The workers are created at a known instant
(T+1.000, and `bin/queueburst.py` locates T to the millisecond), so:

1. Trace `syscalls:sys_enter_*` for one of those tids from creation onward — the
   thread is new, so its entire syscall history fits in a few hundred events and
   will show exactly what it blocks on first and what finally releases it.
2. Or watchpoint the ntsync object it waits on and read the `pc` of the writer,
   the technique that named the arena in phase 30. If that `pc` is in
   `rekordbox.exe` (base `0x140000000`, no ASLR) it maps onto the static
   analysis already in this theme.

## Phase 32 — tracing one thread from birth: 63 of the 68 are PipeWire's, and nothing is idle

Re-run after the reboot with the lesson from `THEMES/T00`: **six named events, in
the foreground, waiting for the "Captured and wrote" line.** 1158 descriptors
instead of ~78,000; clean termination; 17.9 M samples / 1.6 GB in 32 s. The data
was then sliced with `perf script --time` and `--tid` rather than dumped.

Fault confirmed before recording: cycles of 16.17 and 16.18 s, teardowns at MONO
289.320 / 305.490 / 321.673.

### The 68 threads are mostly not rekordbox's

Taking the generation created at teardown+0.944 (290.264-290.652, all by the
main thread 2013) and pulling every event for all 68 children:

    comm names among the 68:
        module-rt      31
        alsa-pipewire  31
        data-loop.0     1
        rekordbox.exe   5

**Sixty-three of the sixty-eight are PipeWire client threads.** Most live
milliseconds — `module-rt` tid 4146: created 290.2643, one `FUTEX_WAKE`
(`op=0x81, val=0x7fffffff`, i.e. wake-all), exit 290.2708. **6.4 ms.** The
`alsa-pipewire` threads log a single event each and are gone.

So the "68-thread pool rebuild" of phase 31 is really: rekordbox closes and
reopens its audio devices, and Wine's ALSA path tears down and recreates an
entire **PipeWire client stack** each time — 31 `module-rt` + 31
`alsa-pipewire` + a `data-loop`, every 15.9 seconds, four times a minute.

### What the five rekordbox threads actually do — none of them is idle

Events per second, across the whole 14.8 s life of that generation:

    sec    4210   4211   4212   4214        4213
    291     176    176    794    396     309,329
    295     176    176    794    394     330,491
    299     176    176    781    394     310,952
    303     178    180    856    394     303,449
    304     174    252    816    426     293,880   <- the churn second
    305      71    142    385    194     136,968   <- teardown

**4210 and 4211 run at exactly 172-180 events per second**, which is
44100/256 = 172.3 — the buffer period, with `AudioBufferSize=256`. 4214 runs at
394/s and 4212 at ~800/s. All four are steady from birth to death, with only a
modest bump in the churn second.

And 4213 is extraordinary:

    ioctl(fd=0xc, cmd=0xc0284e82, ...) -> 0xffffffffffffff92
    0xc0284e82 = NTSYNC_IOC_WAIT_ANY      0xff..92 = -110 = -ETIMEDOUT

**~300,000 timed-out waits per second, every second of its life**, alongside a
steady ~120 successful waits per second. That is a Win32 wait with a zero
timeout in a spin loop — exactly the shape phase 5 read out of the device wait
loop at `0x140fe7b56` ("WasapiPolling forks WaitForSingleObject vs Sleep; wait
timeout is 0 or 1 ms"). It is the same spinner phase 26 saw from the Wine side
as 240,000 padding polls and 160,000 refusals a second.

### The correction to phase 28

Phase 28 concluded, from the pool's head pointer being motionless for thirteen
seconds, that "the engine's service loop `FUN_140fe3530` is not running". **That
inference was too strong.** The threads are not idle at all: they run at the
audio buffer rate continuously, from creation to destruction. What is true is
narrower — during those thirteen seconds they **do not touch the buffer pool**,
and the biquad DSP does not appear in IP samples. They are looping at the right
rate and producing nothing, which is precisely T03's "the transport is stopped,
not the data path".

### What is now worth chasing

Two concrete things, and the first is new:

1. **The PipeWire client stack is rebuilt every 15.9 s** — 63 threads created
   and destroyed per cycle. That is Wine's ALSA→PipeWire path reacting to
   rekordbox's device close/reopen, and it is expensive and on our side of the
   line. Whether it is a *cause* of anything or just a cost is untested, but it
   is the first thing in ten phases that is both anomalous and ours to fix.
   The obvious test: point PC MASTER OUT at the raw `hw:` card so PipeWire is
   out of the path entirely, and see whether the 63-thread churn and the 15.9 s
   cycle survive. (T03 recorded that repointing at the raw card still gives
   0.04x, but that was measured before any of this was understood and did not
   look at thread churn.)
2. **What the four steady threads are waiting on between buffers**, given they
   run at exactly the buffer rate but move no audio. That is a question about
   what the 172/s loop does when it finds nothing to do.

## Phase 33 — LBR call graphs work, and they read the engine's gate out of the running process

**The instrument that ten phases have been missing.** `gdb` crashes rekordbox
(3 for 3), DWARF unwinding produced no stacks at all (phase 29 addendum), and
frame-pointer unwinding is hopeless on an MSVC binary. But this is a 12th-gen
Intel part, so the CPU keeps the last 32 branches in hardware and perf can read
them without any unwind information at all:

    sudo perf record -k CLOCK_MONOTONIC -e cycles:u --call-graph lbr -F 499 \
         -p $(pgrep -f rekordbox.exe) -o perf-lbr.data -- sleep 35

35 s, 23,267 samples, 6.6 MB, no perturbation, and **every sample carries a call
chain that reaches into `rekordbox.exe`**. `perf script -F brstack` then gives
the individual branch records, which is stronger still: it says *which
conditional branches inside a function were actually taken*, i.e. it reads the
control flow of the live process.

Companion instrument: `bin/teardownmark.py`, which polls
`/proc/asound/card0/pcm0p/sub0/status` at 500 Hz and prints a `CLOCK_MONOTONIC`
stamp for every state edge. The teardown is unmissable there — the exclusive
substream goes `RUNNING -> SETUP -> closed` for ~1.1 s — and the clock is the
same one `perf -k CLOCK_MONOTONIC` and `bin/queueburst.py` use, so windows line
up to the millisecond. Measured this session:

    RUNNING 2520.830 | teardown 2535.600 | RUNNING 2536.747 | teardown 2551.544
    quiet 13.5 s   churn 1.4 s   closed 1.1 s   cycle 15.94 s

### Where the CPU goes, by second, aligned to the cycle

`ENG` = samples anywhere in `FUN_140fe3530` (the engine service loop);
`WAIT` = `FUN_140fe7b56` (the WASAPI writer); `DSP` = the biquad block and the
three functions around it that phase 31 found.

    sec   ALL   ENG  WAIT   DSP        (teardowns at 2519.7 / 2535.6 / 2551.5)
    2523  706    10   295     0
    2528  695     7   301     0
    2533  714     6   325     0
    2534  728    28   288     5   <- churn begins
    2535  643    50   157    11   <- teardown
    2537  724     5   300     0
    ...
    2544  700     6   296     0
    2550  ...    28   ...     5   <- churn begins again

So: the writer spins flat out the whole time; the engine loop ticks over at
~1 % CPU for thirteen and a half seconds and then jumps 10x for 1.4 s; and the
DSP runs **only** in that 1.4 s. Nothing is blocked. Something is *gated*.

### The gate, read out of the instruction stream

`FUN_140fe3530` at `0x140fe3910`:

    140fe3910  movzbl 0x1ed(%r13),%eax      ; engine->stopFlag
    140fe3918  test   %al,%al
    140fe391a  jne    0x140fe443d           ; -> exit the thread
    140fe3920  cvtdq2pd %ecx -> %xmm1       ; ecx = max(1, frames*1000/sampleRate)
    140fe3928  lea    0x138(%r13),%rcx      ; engine->workReadyEvent
    140fe392f  call   0x142947330           ; WaitableEvent::wait(ms)
    140fe3934  mov    $0x1,%r15b            ; assume "everybody is full"
    ...        for (i = 0; i < engine->ndevices(+0x3d4); i++) {
    140fe396e      lock cmpxchg ...         ; take dev->spinlock[dev->slot]
    140fe39e0      depth = 0; for (p = dev->queue[dev->slot]; p; p = p->next(+0x128)) depth++
    140fe39fc      cmp    $0x3,%edx
    140fe39ff      cmovge %eax,%ecx         ; r15 &= (depth >= 3)
    ...        }
    140fe3af4  test   %r15b,%r15b
    140fe3af7  jne    0x140fe3910           ; ALL devices have >=3 queued -> wait again
    140fe3b01  ...                          ; otherwise: PRODUCE

**`0x142947330` is JUCE's `WaitableEvent::wait(double timeoutMs)`** — MSVC
`std::mutex` at `this+0x08`, `std::condition_variable` at `this+0x58`,
`triggered` bool at `this+0xa0`, `manualReset` bool at `this+0x00`, and the
`if (!manualReset) triggered = false` clear at `0x1429473ab`. The timeout is the
buffer period, `256*1000/44100 = 5 ms`.

So the engine's producer is a straightforward **"keep three buffers queued on
every device"** rule. It wakes every 5 ms, counts each device's queue, and if
every device already has three or more, it produces nothing at all.

### What the branch records say, and it is unambiguous

Every LBR branch record whose source or target lies inside `FUN_140fe3530`:

    QUIET  (2521.5-2534.0, 2537.5-2550.0)
        67   0x140fe392f -> 0x142947330   CALL      (the wait, and NOTHING else)
    CHURN  (2534.2-2535.6, 2550.15-2551.54)
        68   0x140fe40c2 -> 0x140ff00c0   IND_CALL  (the per-device work)
         7   0x140fe392f -> 0x142947330   CALL
         1   0x140fe4117 -> 0x140fe51a0   CALL      (the pool append of phase 27)

**For thirteen and a half seconds out of every fifteen and nine tenths, the
engine service loop executes exactly one instruction sequence: wait 5 ms, count
the queues, find them all at 3 or more, wait again.** It is not blocked, it is
not descheduled, it is not waiting on Wine. It is being told there is nothing to
do — 2,700 times per cycle.

### Corrections to earlier phases

* **Phase 28** ("the engine's service loop `FUN_140fe3530` is NOT RUNNING")
  and **phase 31** ("T+1.3..T+15.2 nothing"): the loop runs continuously at the
  buffer rate. What is true is that it takes the *early* path.
* **Phase 32**'s correction of phase 28 was right about the threads not being
  idle but attributed the 172/s loops to "producing nothing"; they are the
  engine's 5 ms poll and the WASAPI writer's spin, and now both are named.
* **Phase 24/27**'s pool model survives intact, and the gate explains why the
  pool is motionless: production is *supposed* to stop at depth 3.

### The consumer, also decoded

`FUN_140fe98c0` -> `FUN_140fe7ae0` (`0x140fe7b56` in `.pdata`) is the WASAPI
writer. Object layout, read off the call sites:

    +0x10  IAudioClient          *0x30 = GetCurrentPadding
    +0xf8  IAudioRenderClient    *0x18 = GetBuffer, *0x20 = ReleaseBuffer
    +0x68  the stream event handle
    +0x18  == 1  -> exclusive mode
    +0xa8  buffer size in frames      +0xb8  period in frames
    +0x108 spin deadline (ms)         +0x118 timestamp of last write
    imports: 0x143374568 = WaitForSingleObject, 0x143374788 = Sleep

With `WasapiExclusive=1, WasapiPolling=0` the exclusive path is a
**deadline-bounded busy-wait**: `WaitForSingleObject(h, 0 or 1 ms)` ->
`GetCurrentPadding` -> if the whole requested block still does not fit,
`Sleep(0)` and go round again until `now - start > +0x108`. That is phase 26's
240,000 padding polls and 160,000 refused `GetBuffer` calls per second, and
phase 32's 300,000 `-ETIMEDOUT` `NTSYNC_IOC_WAIT_ANY` ioctls per second. It is
wasteful but it is *working*: it delivers 44,032 frames/s in 1024-frame blocks.

### The five settings that drive this code, none of which has ever been varied

    WasapiExclusive        1     -> +0x18 == 1, the exclusive path above
    WasapiPolling          0     -> global 0x145ed5d7d, selects spin vs event
    WasapiTimeoutCount     3     -> the +0x108 spin deadline
    WasapiThresholdCount   1
    WasapiBufferThreshold  2     -> global 0x145b52210, the padding limit

Thirty-two phases of this investigation have varied `AudioBufferSize` and the
Wine driver and never touched these. They are read directly by the function that
is burning a core, and they are one `bin/rbset.sh` away.

### The question this leaves, and it is a new one

The engine is told "every device already has three buffers queued" for 13.5 s.
Either the queues really are full — in which case the **consumer is not
consuming**, and yet it demonstrably hands 44,100 frames a second to both
devices — or the count is being taken against something that is not draining.
The next phase has to watch one device's queue depth and its `ReleaseBuffer`
calls on the same clock.

## Phase 34 — ROOT CAUSE. A start-up rendezvous of 600 device callbacks, and Wine gives the DDJ only 43 of them a second

Everything below is measured with hardware **execute** breakpoints
(`perf record -e mem:<code addr>:x -p <pid>`), which cost nothing, need no
debugger, and count exactly how often a given instruction runs and when. That is
the instrument this phase turns on; phase 33's LBR call graphs are what found
the addresses worth counting.

### The code

`FUN_140fe5de0` is the **per-device audio callback**. `FUN_140fe98c0` calls it
once per block, per device, and then hands the result to WASAPI
(`FUN_140fe7ae0`). Its first act, before any audio is touched:

    140fe5e18  cmpb  $0, 0x3c8(%r10)          ; r10 = this->0x10 = the engine
    140fe5e1f  je    0x140fe5eaa              ; barrier already satisfied -> work
    140fe5e25  eax = 1000 * engine->0x290     ; engine block size in frames
    140fe5e38  divsd engine->0x288            ; / sample rate   -> periodMs
    140fe5e4d  eax = 3000 / periodMs
    140fe5e55  ebx = max(10, eax)             ; THRESHOLD = 3 seconds of callbacks
    140fe5e5f  ++engine->counters[this->0x50] ; this device's callback counter
    140fe5e6f  for (j = 0; j < engine->ncounters; j++)
    140fe5e90      if (counters[j] < ebx) goto 0x140fe6170   ; <- RETURN, do nothing
    140fe5ea3  engine->0x3c8 = 0              ; barrier opens, for good

**No audio is produced by any device until every device has completed three
seconds' worth of callbacks.** At `AudioBufferSize=256` and 44100 Hz the period
is 5 ms and the threshold is **600 callbacks**.

### The measurement

Four execute breakpoints, 32 s, one live fault:

    0x140fe5e18  function entry      6338 hits
    0x140fe5e6a  counter increment   5982
    0x140fe5ea3  BARRIER OPENS          2      <- twice in 32 s, once per cycle
    0x140fe5fca  the real work        358

Per thread, one generation (each generation has one thread per device):

    tid 33164   2544 entries / 14.8 s = 172 /s    = 44100/256, the PC endpoint
    tid 33166    636 entries / 14.8 s =  43 /s    = the DDJ, exclusive

**600 callbacks at 43 a second is 13.95 seconds.** Measured, from the stream
reopening to the barrier opening: **13.91 s**. The DDJ's counter reaches 600 and
the barrier opens on that instant; its 636 total entries are 600 before the
barrier and 36 in the 0.87 s of audio that follows.

The barrier openings and the teardowns, on one clock:

    reopen 4778.970 -> barrier 4792.884 (13.914 s) -> teardown 4793.770 (0.886 s)
    reopen 4795.032 -> barrier 4809.83? ...
    barrier-to-barrier: 4776.867 -> 4792.884 = 16.017 s

### The cycle, finally complete and every step measured

    T+0.0   both streams closed by the announce
    T+1.2   reopened; every device's callback counter resets to 0
    T+1.2 .. T+15.1   THE BARRIER. Both device callbacks return at their first
            instruction. Nothing is popped from any queue, nothing is produced,
            the deck does not advance, and the WASAPI writer re-sends the last
            buffer it was given -- which is T03's silence at the wire, phase 28's
            motionless pool, and phase 33's "the engine loop only ever waits".
    T+15.1  the DDJ's counter reaches 600; the barrier opens
    T+15.1 .. T+16.0  0.87 s of real audio: the queues drain, the engine
            produces, the biquad DSP appears in the profile, the track file is
            read. Production is driven by whichever device is below 3 buffers --
            the PC endpoint, at 172 callbacks a second -- so the DDJ's queue, at
            43, gains buffers it cannot consume, is trimmed once per block, and
            after 101 trims inside 100 ms windows the watchdog announces a device
            change.
    T+16.0  both streams torn down. Go to T+0.

`1.2 + 13.9 + 0.87 = 15.97 s` -- the period this investigation has been chasing
since T03, to three significant figures, with no unexplained term left.

### The cause: Wine gives the exclusive stream a 1024-frame period

rekordbox asks for `AudioBufferSize = 256` frames and gets exactly that on the
shared PC endpoint: **172 callbacks a second = 44100/256**. On the DDJ's
**exclusive** stream Wine hands it a 1024-frame buffer, so rekordbox writes 1024
frames per callback and the callback runs at **43 a second** (phase 26 measured
the same thing from the driver side: 43-45 `ReleaseBuffer` calls a second,
~1024 frames each, 44,032 frames/s).

That single factor of four is the whole fault:

1. it makes the 600-callback rendezvous take **14 s instead of 3.5 s**, and
2. it makes the two devices consume at different rates, which is what drives the
   queue divergence, the trim storm and the teardown.

**With one output device neither consequence bites.** The rendezvous still takes
14 s -- so the daily configuration has a **fourteen-second silent start**, which
is a gold-standard defect in its own right and has never been written down --
but once it opens there is no second device to diverge from, the watchdog's
`depth - min(depth)` is identically zero, and playback runs at 1.00x for ever.

### What this predicts, and what to test next

* **Healthy arm**: the barrier at `0x140fe5ea3` fires exactly **once**, about
  14 s after the stream starts, and never again.
* **`AudioBufferSize = 1024`**: the engine's block would match the period Wine
  actually gives the DDJ, so both devices would run at 43 callbacks/s, the
  threshold would fall to `3000/23.2 = 129`, the barrier would open in 3.0 s and
  the queues would not diverge. Sharp prediction: **the fault disappears.**
  (T03 measured 1024 -> 0.22x, but that was scored over a 40 s window that spans
  the teardown cycle; it was never checked against the barrier.)
* **The Wine fix**: make `winealsa`'s exclusive path honour the requested
  256-frame period. That is the correct repair -- it fixes the 14 s start in
  *both* arms and removes the rate mismatch at its source.

### Instruments added

`bin/peimports.py` (names every IAT slot -- `objdump -x` prints hint numbers for
this binary, so `call *0x1433747c8` was anonymous until now; it is
`TryEnterCriticalSection`), `bin/pecslock.py` (every `lea +off(%reg)` paired with
a CRITICAL_SECTION call, for "who locks this member"), `bin/enginefind.py`
(locates the live engine object by device vtable -> device array -> holder; note
the chunked scan, because a whole-region read fails on this process's big heaps
and silently skipping them hid the engine for an hour).

### One hypothesis raised and killed on the way

The render path at `0x140fe9cca` calls **`TryEnterCriticalSection(engine+0x2d8)`**
and skips the entire audio graph if it fails. That looked like the answer. It is
not: execute breakpoints show it succeeds **5127 times out of 5127**, and the
`engine->0x2c2` flag beside it is set 5111 times. The render call is made 205
times a second throughout the quiet stretch -- it is the callback itself that
returns at its first instruction.

## Phase 35 — the 4x buffer inflation is OUR OWN Wine patch

Phase 34 said "Wine gives the DDJ's exclusive stream a 1024-frame buffer instead
of the requested 256". That is true, and this phase says *where the 1024 comes
from*, which changes what has to be fixed.

### What rekordbox actually asks for

`WINEDEBUG=+alsa` on a fresh launch, one line per stream creation:

    ALSA period: 441   ALSA buffer: 1764   MMDevice period: 441   MMDevice buffer: 1323
    ALSA period: 256   ALSA buffer: 1024   MMDevice period: 256   MMDevice buffer: 1024

The second is the DDJ, exclusive: **period 256 frames — exactly
`AudioBufferSize` — and buffer 1024.** `winealsa` is faithful; it takes
`bufsize_frames` straight from `params->duration` (`alsa.c:995`). So the
inflation happens above it, in `mmdevapi`.

### And it is ours

`upstream/0002-mmdevapi-exclusive-event-streams.patch`, written by this project
to make event-driven exclusive mode work at all (T03), contains:

    if (*duration != *period)
        return AUDCLNT_E_BUFDURATION_PERIOD_NOT_EQUAL;   /* Windows' own rule */
    ...
    if (*duration < 4 * *period)
        *duration = 4 * *period;

**rekordbox passes `duration == period == 256 frames` — it has to, or the check
on the line above would have rejected it — and our patch then quadruples it.**
The patch's own comment anticipated the objection and dismissed it: *"GetBufferSize
reports the real size, so a client that sizes itself from that stays correct."*
It does not stay correct. rekordbox sizes its **per-device audio block** from
`GetBufferSize()`, so the widening makes the DDJ's callback run at
`44100/1024 = 43 Hz` while the shared PC endpoint, whose block is the requested
256, runs at `44100/256 = 172 Hz`. Phase 34 measured both, and the factor of four
is exactly the ratio of the two widenings.

Independent confirmation from the buffer-size sweep: at `AudioBufferSize=1024`
the same measurement gives 43 Hz for the PC endpoint and **10.8 Hz** for the DDJ
— `44100/4096`. The DDJ's block is always `4 x AudioBufferSize`, i.e. always
`GetBufferSize()`, i.e. always the number our patch chose.

### Why the widening was added, and why it may no longer be needed

The original symptom (T03) was real: with `duration == period`, `held_frames`
pinned at the whole buffer and `get_render_buffer` refused every request —
6,963,363 `GetCurrentPadding` calls against 20 `GetBuffer` calls in 100 s. But
that was measured *before* `0003-winealsa-exclusive-audio` taught the driver to
signal the client event only when a period is actually free, and before the
driver started running its own multi-period ALSA ring
(`alsa_bufsize_frames = mmdev_period_frames * 4`, `alsa.c:920`). The slack the
mmdevapi widening was providing now exists a layer below it, where it belongs
and where the client cannot see it.

### The knob, and the arm

A previous session had already written the experiment into the source and never
built it: `rbw_periods("RBW_EXCL_PERIODS", 4)` and
`rbw_periods("RBW_SHARED_PERIODS", 3)` in `dlls/mmdevapi/client.c`, with the
comment *"whether the inflation is the reason is a measurement, not an
argument"*. Built and installed this session; greppable as `RBW-PERIODS
exclusive` / `RBW_EXCL_PERIODS` in
`prefixes/rb7/drive_c/windows/system32/mmdevapi.dll`. Default 4 reproduces the
shipping behaviour exactly, so the arm is one environment variable:

    RBW_EXCL_PERIODS=1 bin/arm.sh exclperiods1 AudioBufferSize=256 PCSpeakerSelected_23=1
    bin/barrierscope.sh 40

**Prediction, stated before the run:** the DDJ's `GetBufferSize` becomes 256, its
callback rate rises to 172 Hz to match the PC endpoint, the 600-callback
rendezvous opens at ~3.5 s instead of ~14 s, the two queues drain at the same
rate so the trim watchdog never fires, and PC MASTER OUT plays at 1.00x with no
teardowns.

## Phase 36 — the arms, and the quantitative law behind the burst

`RBW_EXCL_PERIODS` built and installed, so the mmdevapi widening is now a
variable. Every arm below is `PCSpeakerSelected_23=1` with the same binary and
the same prefix; the only differences are named.

| arm | excl periods | AudioBufferSize | PC callbacks | DDJ callbacks | ratio | barrier | cycle | engine |
|---|---|---|---|---|---|---|---|---|
| baseline | 4 | 256  | 172 /s | 43 /s   | 4.0 | 13.91 s | 16.02 s | 0.05x |
| A | 4 | 1024 | 43 /s  | 10.8 /s | 4.0 | 12.03 s | 16.58 s | 0.16x |
| B | 1 | 256  | 148 /s | 74 /s   | 2.0 |  8.1 s  |  9.55 s | 0.12x |
| C | 1 | 1024 | 38.6 /s| 19.3 /s | 2.0 | ~11 s   | 12.21 s | 0.40x |

Two laws fall straight out of the table, and together they explain every number
this investigation has ever produced.

### Law 1 — the DDJ's block size is `GetBufferSize()`

`DDJ callbacks/s = 44100 / (EXCL_PERIODS x AudioBufferSize)`, exactly, in the
two arms where Wine can keep up (baseline: 44100/1024 = 43.1; arm A:
44100/4096 = 10.8). rekordbox sizes its per-device audio block from
`GetBufferSize()`, and `GetBufferSize()` is `EXCL_PERIODS x AudioBufferSize`.

The shared PC endpoint does **not** work that way: its block is
`AudioBufferSize` regardless of what Wine reports (172 /s at 256, 43 /s at
1024). That asymmetry is the whole disease.

### Law 2 — the audio burst ends when the DDJ's queue is 101 entries behind

Each callback pops exactly **one** queue entry, whatever its frame count. The
engine tops every device up to three entries. So the DDJ's queue gains

    excess/s = PC callbacks/s - DDJ callbacks/s

and the trim watchdog announces a device change after **101** trims. Arm C:
211 PC pops against 106 DDJ pops in one burst = 105 excess -> announce.
Baseline: 4:1 at 172 /s = 129 excess/s -> the burst can only last 0.8 s.
Arm C: 2:1 at 38.6 /s = 19 excess/s -> the burst lasts 4.9 s. Engine rate is
just `burst / cycle`: 0.87/16.0 = 0.05x, 4.9/12.2 = 0.40x. Every entry in the
table follows.

**So the cure is rate parity.** At a 1:1 ratio the excess is zero, nothing ever
gets trimmed, the watchdog never fires, and the burst never ends.

### Why `RBW_EXCL_PERIODS=1` alone does not get there

It halves the ratio but stops at 2.0, because with a one-period mmdevapi buffer
rekordbox can only fill it every *other* period: it writes the whole buffer and
then waits for `GetCurrentPadding` to reach zero. Arm B also produced ALSA
XRUNs, which is the original T03 starvation coming back. So one period is
necessary but not sufficient.

### The remaining lever, and it is a rekordbox setting

`WasapiPolling` selects between two paths in the writer at `0x140fe7bcf`:

    polling = 0   r14d = bufsize            ; assume the whole buffer is free,
                                            ; GetBuffer(whole buffer), spin on refusal
    polling = 1   padding = GetCurrentPadding()
                  limit   = min(bufsize, period * WasapiBufferThreshold)
                  if (padding > limit) write nothing this pass
                  else r14d = period        ; write ONE PERIOD at a time

**With `WasapiPolling=1` the writer stops demanding an empty buffer**, so a
one-period buffer can be kept full continuously instead of ping-ponged. Next arm:
`RBW_EXCL_PERIODS=1 WasapiPolling=1 AudioBufferSize=256`, whose prediction is a
1:1 ratio, a 3.5 s barrier, no trims and 1.00x.

## Phase 37 — CURED. 1.02x with PC MASTER OUT on, and no teardowns at all

    RBW_EXCL_PERIODS=1        (rebuilt mmdevapi: honour the period rekordbox asked for)
    WasapiPolling=1           (rekordbox setting)
    AudioBufferSize=256
    PCSpeakerSelected_23=1    (PC MASTER OUT ON)

    ENGINE RATE = 1.02x real time      (61 s, Demo Track 1)
    DDJ substream state changes: 0     (baseline: 5 in 40 s)

The first run of this arm played the 2:08 demo track **to its end**, which is
arithmetically impossible at 0.05x.

`bin/barrierscope.sh 40` on the same instance:

    BARRIER OPENS          1
       8592.117    3.465 s after the stream started

    tid 88464   4422 entries   counter++    0   work 4422
    tid 88466   4421 entries   counter++    0   work 4421
    tid 93542   2254 entries   counter++  602   work 1652
    tid 93540   2253 entries   counter++  600   work 1654

Every prediction from phases 34-36 lands:

* the rendezvous opens **once**, at **3.465 s** — 600 callbacks at 172 a second
  is 3.49 s — and never again;
* the two device threads run at **identical** rates (4422 against 4421, 2254
  against 2253), so the excess that feeds the trim watchdog is **zero**;
* `counter++` stops at 600 and the rest of each thread's life is `work`.

### Why both changes are needed (and the third arm that proves it)

`RBW_EXCL_PERIODS=1` alone gives a 2:1 ratio and 0.12-0.40x (phase 36, arms B and
C): with a one-period buffer and `WasapiPolling=0`, rekordbox demands the whole
buffer be empty before it writes, so it can only fill it every other period.
`WasapiPolling=1` makes the writer take the `GetCurrentPadding` path and write
**one period at a time**, which keeps a one-period buffer continuously full.
Together they give a block size of 256 frames on both devices and a sustained
172 callbacks a second on both.

### The audible consequence, and the packaging consequence

The `~14 second silent start` of phase 34 becomes **3.5 seconds**, in both arms —
that is a user-visible improvement to the *working* configuration as well.

For `PACKAGE.md` and the run-and-play script this is two lines: ship the mmdevapi
build with the exclusive widening removed (or default `RBW_EXCL_PERIODS` to 1),
and set `WasapiPolling=1` in `rekordbox3.settings` at first run.

## Phase 38 — variable separated: `WasapiPolling=1` alone is the cure

Same instance, shipping mmdevapi behaviour (`RBW_EXCL_PERIODS` unset, so the 4x
widening is still there), only rekordbox's `WasapiPolling` flipped 0 -> 1:

    ENGINE RATE = 1.02x           DDJ substream state changes: 0
    barrierscope: both device threads at 172.3 /s (6894 and 6892 entries in 40 s)

So **phase 36's Law 1 holds only for `WasapiPolling=0`.** The writer at
`0x140fe7bcf` picks its write size from the polling flag:

    polling = 0   block = GetBufferSize()  -> 1024 with the widening -> 43 /s
    polling = 1   block = mmdev period     ->  256 always            -> 172 /s

With polling on, both devices use the period they asked for, the rates match,
and **no Wine change is required at all**. `RBW_EXCL_PERIODS=1` on its own only
halves the ratio (2:1) because a `polling=0` writer demands an empty buffer.
The rebuilt mmdevapi is kept anyway: its default of 4 reproduces the shipping
behaviour byte for byte, and the knob makes the whole experiment repeatable.

## Phase 39 — the residual: one teardown every ~140 s, and it is clock drift

`WasapiPolling=1` is not the end of it. A 122 s soak: **0.91x, one teardown**.
`bin/queuescope.py` over 150 s says exactly why:

    depths oscillate 2..5 around 3 on BOTH devices, spread never exceeds 3
    trims: dev2 (PC) 55 counted, dev3 (DDJ) 40; last-trim timestamps move ~2.5 /s
    dev2's trim_count reaches 100 after ~140 s  ->  ANNOUNCE  ->  both streams torn down

Two things to correct in the record:

* **Phase 8's "101 trims with less than 100 ms between them" is wrong**, or at
  least incomplete. Here the trims are seconds apart and the counter still
  reaches 100. Whatever the reset rule is, it does not protect a slow leak.
* The fault is no longer a rate *mismatch* — the rates are equal to four
  significant figures — it is **jitter and drift**. The DDJ runs on its own
  44100 Hz crystal; the PC endpoint goes through PipeWire, whose graph is
  running at **48000** and resampling. Two independent clocks under one engine
  loop produce exactly this: a queue that breathes +/-2 around 3 and trims a
  couple of times a second.

Next arm, and it needs no build: force PipeWire's graph to 44100 so the PC
endpoint stops being resampled —

    pw-metadata -n settings 0 clock.force-rate 44100

and re-soak. **Prediction: the trim rate collapses and the ~140 s teardown goes
with it.**

## Phase 40 — the watchdog, read exactly, and why the residual teardown survives

`FUN_140fe3530`, `0x140fe4334`:

    now = now_ms()
    if (now - dev->lastTrimMs(+0x88) >= 100)   goto stamp   ; too long ago: don't count
    ++dev->trimCount(+0x98)
    if (dev->trimCount > 100) { dev->trimCount = 0; announce(); }
    stamp: dev->lastTrimMs = now

and the trim itself, `0x140fe419e`:

    if (depth - min_depth_over_devices <= 3)  no trim
    else                                      unlink the excess

**Phase 8's reading was right and phase 39's doubt was wrong.** The counter only
increments when the *previous* trim was less than 100 ms ago — but it is never
decremented and never decays. So it is a **high-water mark of close-spaced
trims, accumulated over unlimited wall time**. Two trims 50 ms apart once a
second will reach 100 in a couple of minutes just as surely as a storm will in
0.9 seconds. That is exactly the residual: `WasapiPolling=1` removed the storm
(hundreds of trims a second) but not the drizzle (about two a second, of which
some pairs fall inside 100 ms).

### What is left to remove: jitter, not rate

The rates are equal to four significant figures. What still makes a queue run
four entries deeper than its neighbour is **scheduling jitter** — one device's
callback thread being late by four blocks, which at 256 frames is 23 ms.

    $ per-thread scheduling policy, all 194 rekordbox threads
        185 threads  SCHED_OTHER
          9 threads  SCHED_BATCH
          0 threads  SCHED_FIFO / SCHED_RR
    $ ulimit -r
        0

**Not one rekordbox thread has real-time priority.** On Windows its audio
threads run under MMCSS "Pro Audio"; under Wine `AvSetMmThreadCharacteristics`
is a **stub** (already noted in T03's next-action list and never followed up),
so the audio callback threads are ordinary desktop threads competing with the
compositor and with rekordbox's own OpenGL thread — which phase 33's profile
showed burning more CPU than everything else in the process combined.

So the last piece of PC MASTER OUT is a Wine gap with a name, and it is the same
gap that would show up as jog-wheel latency at the DDJ. Two lines of attack, in
order of cost:

1. **Test the hypothesis cheaply**: raise the process's priority from outside
   and count teardowns over the same soak. If the drizzle thins, jitter is
   confirmed as the last term.
2. **Fix it properly in Wine**: implement `AvSetMmThreadCharacteristicsW` so it
   actually raises the calling thread — via RTKit
   (`org.freedesktop.RealtimeKit1`, which is what PipeWire itself uses on this
   machine) or `sched_setscheduler` where `rtprio` is allowed. That is a real
   upstream contribution and it serves the whole mission, not just this bug.

## Phase 42 — the shipping configuration, and a correction to phase 34

### Correction: there is no fourteen-second silent start with one device

Phase 34 wrote down a corollary — "the rendezvous applies with one device too,
so the daily configuration has a ~14 second silent start". **That is wrong, and
it is measured wrong.** `bin/barrierscope.sh 25` against a healthy arm
(`PCSpeakerSelected_23=0`) records **zero events at every one of the four
breakpoints**: `FUN_140fe5de0` is not called at all. This is phase 16's finding
from the other side — with one output device rekordbox builds a different object
graph entirely and none of the multi-device machinery runs. The rendezvous, the
queues, the trim watchdog and the announce are all two-device code.

### The buffer-size sweep, with `WasapiPolling=1` throughout

Measured with `bin/soak.sh`, which reports the deck's own clock (the file-offset
oracle goes VOID once rekordbox has read the whole track into memory, which it
does in polling mode) and counts DDJ substream closes.

| AudioBufferSize | deck rate | teardowns | window |
|---|---|---|---|
| 256  | 0.91 | **1** | 195 s |
| 512  | 1.00 | **0** | 3 x 155 s = 465 s |
| 1024 | 1.00 | **0** | 135 s |

256 frames is 5.8 ms; the residual jitter of phase 40 is a large fraction of
that, so a pair of trims lands inside the watchdog's 100 ms window often enough
to reach 100 in about three minutes. 512 frames is 11.6 ms and the drizzle stops.

### THE GOLD CONFIGURATION, as measured

    WasapiPolling        = 1        (rekordbox setting; this is the fix)
    AudioBufferSize      = 512      (the floor; 256 still drips)
    WasapiExclusive      = 1        (unchanged)
    PCSpeakerSelected_23 = 1        (PC MASTER OUT ON)
    mmdevapi             = the shipping RBW-MMDEV2 build (no Wine change needed)

    deck rate                       1.00 of real time, 465 s continuous
    DDJ substream closes            0
    PC MASTER OUT at the wire       -19.7 to -22.5 dBFS RMS, continuous,
                                    recorded off the sink monitor with parec
    DDJ ALSA substream              RUNNING, delay 2665 frames, avail_max 2011
    MIDI                            unchanged: DDJ-400 MIDI 1 -> WINE ALSA Input,
                                    rekordbox holds /dev/snd/midiC0D0 (rawmidi)
    healthy arm (PC MASTER OUT off) 1.00, 0 teardowns — no regression

`bin/rekordbox-wine` now enforces both settings: it reports them under
**Audio settings** in `--check`, and repairs them in `--setup`/launch with the
application stopped (the file is rewritten every ~15 s while it runs), keeping
`rekordbox3.settings.rbw-backup`. A user who has deliberately chosen a buffer
larger than 512 is left alone.

### What is still open, and it is the reason 256 is not usable

No rekordbox thread runs at real-time priority under Wine, because
`AvSetMmThreadCharacteristics` is a stub (phase 40). Implementing it — via
RTKit, which is what PipeWire already uses on this machine — is what would make
a 256-frame buffer stable, and it is the same gap that will govern jog-wheel
latency at the controller. Raising the priority from outside is **not** a
substitute: `chrt -r` on the callback threads stopped rekordbox's audio and the
process did not survive (phase 41).

## Phase 44 — the same fault, seen from inside Wine: an A/B at the driver boundary

The mmdevapi rebuilt in phase 35 carries a per-second client reporter
(`RBW-CLIENTS`) that had never been read against a *working* arm. Both arms
below are the same binary, the same prefix and the same track; the only
difference is `WasapiPolling`.

**Broken — `WasapiPolling=0`, `AudioBufferSize=512`:**

    dev=plughw:0,0 (DDJ, exclusive)
        pad 241665 calls/s
        GetBuffer ok=21  fail=159314  hr=88890006   askmax=2048
        Release 21 calls  43008 frames  nonzero=0   (all zeros)
    dev=default (PC endpoint, shared)
        pad 263 calls/s
        GetBuffer ok=175 fail=0                      askmax=512
        Release 175 calls 44453 frames nonzero=0     (all zeros)

**Fixed — `WasapiPolling=1`, `AudioBufferSize=256`:**

    dev=plughw:0,0 (DDJ, exclusive)
        pad 114871 calls/s
        GetBuffer ok=172 fail=0                      askmax=256
        Release 172 calls 44032 frames nonzero=172   (signal in every buffer)
        block 256..256 frames
    dev=default (PC endpoint, shared)
        pad 349 calls/s
        GetBuffer ok=261 fail=0                      askmax=256
        Release 261 calls 44218 frames nonzero=261   (signal in every buffer)

Three things are settled by those eight lines:

* **`askmax=2048` at `AudioBufferSize=512`** is Law 1 (phase 36) confirmed a
  third time: with polling off, rekordbox's block is `GetBufferSize()`, which
  our mmdevapi widening makes `4 x AudioBufferSize`. With polling on it is the
  period, 256, on both devices.
* **159,314 refused `GetBuffer` calls a second**, all
  `AUDCLNT_E_BUFFER_TOO_LARGE`, become **zero**. T03 dismissed those refusals as
  harmless and phase 10 refuted them as *the* cause; both were right in their own
  terms — they are a symptom of the oversized block, and they vanish with it.
* **`nonzero=0 (all zeros)` becomes `signal in every buffer`.** The broken arm
  hands *silence* to both devices, which is T03's "silence at the wire" measured
  from the other side of the same API, and the cure puts real audio in every
  single buffer on both.

## Phase 45 — three reproductions: this process does not survive an external RT change

`sudo chrt -r -p 5 <callback tid>` — one thread, modest priority, on a process
whose busiest thread is now at 15% CPU (the 300,000-ioctl-a-second spinner is
gone with `WasapiPolling=1`) — **kills rekordbox within ten seconds. Three times
out of three.** There is no Wine error, no "Program Error" dialog and no exit
message: the `RBW-CLIENTS` reports simply stop mid-second.

**WITHDRAWN 2026-08-20 — see T12.** The cause was `RLIMIT_RTTIME = 0`, set
inside the process by `libpipewire-module-rt` because `rtkit-daemon` was not
installed and the desktop portal therefore advertised no realtime budget. At
zero, any thread on an RT policy is killed by `SIGXCPU` immediately. With rtkit
installed the same `chrt -r` survives 30 s. The rule as originally written --
**do not apply a real-time scheduling policy to this process from outside** -- It is also, in its own right,
something worth understanding before any `AvSetMmThreadCharacteristics` work —
if Wine cannot tolerate a policy change under a running thread, that has to be
fixed first.

### Where that leaves the 256-frame buffer

Measured at `AudioBufferSize=256` with the fix in place, four soaks totalling
660 s: **2 teardowns**. At 512, 465 s: **0**. rekordbox's own Preferences pane
reports 512 samples as **11.6 ms**, mid-range on its own slider — which is what
a DDJ-400 user runs on Windows too. So 512 is the shipping value and 256 is a
known-imperfect option, not a regression against Windows.
