# T12 — Why no rekordbox thread can be real-time, and why forcing it kills the process

**Opened 2026-08-20**, splitting off from T10's last open item. T10 phase 45
recorded a hard rule: `sudo chrt -r -p 5 <callback tid>` **kills rekordbox
within ten seconds, three times out of three**, silently — no Wine error, no
dialog, the per-second reports just stop. It also named the prerequisite: *if
Wine cannot tolerate a policy change under a running thread, that has to be
fixed first.*

**It is not Wine, and it is not rekordbox.** The cause is now measured.

## Root cause — `libpipewire-module-rt` sets `RLIMIT_RTTIME` to zero, hard

Captured with `strace -f -k -e trace=prlimit64` on a normal launch:

    443867 prlimit64(0, RLIMIT_RTTIME, {rlim_cur=0, rlim_max=0}, NULL) = 0
     > /usr/lib/libc.so.6(setrlimit+0x15)
     > /usr/lib/pipewire-0.3/libpipewire-module-rt.so() [0x305a]
     > /usr/lib/pipewire-0.3/libpipewire-module-rt.so() [0x32bc]
     > /usr/lib/spa-0.2/support/libspa-support.so()
     > /usr/lib/libpipewire-0.3.so.0.1608.0()

The chain that puts PipeWire *inside* rekordbox's address space is our own
configuration: the prefix uses the **ALSA** driver (winepulse has no exclusive
mode), ALSA routes through `libasound_module_pcm_pipewire.so`, and that pulls in
`libpipewire-0.3.so` and its modules. Confirmed present in
`/proc/<pid>/maps`.

### Why zero is fatal, and irreversible

`RLIMIT_RTTIME` bounds the CPU time a thread may consume **under a real-time
policy without blocking**. Exceed it and the kernel raises `SIGXCPU`, whose
default action is to terminate. At **zero**, any RT execution at all exceeds it
immediately — so the moment `chrt` puts a thread on `SCHED_RR`, the process is
killed. Silently, because nothing installs a `SIGXCPU` handler.

The **hard** limit is set to zero too, and lowering a hard limit is a one-way
door without `CAP_SYS_RESOURCE`. The trace shows the main thread discovering
exactly this and failing to undo it:

    prlimit64(0, RLIMIT_RTTIME, {rlim_cur=RLIM64_INFINITY, ...}, NULL) = -1 EPERM

354 `RLIMIT_RTTIME -> 0` calls in one startup.

### Timing

Polled from process start: `unlimited` at 1-2 threads, then **`0 0` at ~1.6 s**
as the pool reaches ~22 threads — i.e. when audio initialises and the ALSA
plugin loads. A plain `wine notepad` in the **same prefix** keeps
`unlimited unlimited`, which is the control that rules out Wine and the prefix.

## A correction to T10's premise

T10 proposed implementing `AvSetMmThreadCharacteristics` "via RTKit, which is
what PipeWire already uses on this machine". Both halves are wrong here:

- **rtkit-daemon is not installed at all** on this system.
- **PipeWire's own audio threads are not real-time either.** Measured:
  `pipewire`, `pipewire-pulse` and `wireplumber` `data-loop.0` threads all run
  `SCHED_OTHER|SCHED_RESET_ON_FORK` at nice 0. The config asks for `rt.prio = 88`
  and does not get it, because `RLIMIT_RTPRIO = 0` and there is no rtkit to ask.

So "rekordbox gets no real-time priority" is **parity with every audio
application on this machine**, not a Wine-specific deficit. That materially
weakens the case that the missing MMCSS implementation is what makes a
256-frame buffer unstable — the reference implementation manages without it.

## What this changes

1. **T10's rule "never apply an RT policy to this process from outside" is
   retired as a law of nature and restated as a consequence of a fixable
   limit.** It remains correct advice *while* `RLIMIT_RTTIME` is zero.
2. **Implementing `AvSetMmThreadCharacteristics` to grant real RT priority is
   pointless until this is fixed** — and actively dangerous, because it would
   move the SIGXCPU kill from a manual experiment into the shipping path.
3. There is an existing `RBW-MMCSS` block in `dlls/avrt/main.c` gated on
   `RBW_MMCSS=1` which raises the thread to `THREAD_PRIORITY_TIME_CRITICAL`.
   Like the wineusb unixlib before it, **it exists only in the working tree and
   is in no patch** (see T11 for that class of error).

## The fix: install `rtkit` — and the proof

`rtkit-daemon` was not installed, so `xdg-desktop-portal`'s Realtime interface
advertised **`MaxRealtimePriority = 0`, `MinNiceLevel = 0`** and no
`RTTimeUSecMax` at all. `libpipewire-module-rt` asks that interface, gets
nothing, and sets `RLIMIT_RTTIME` to zero. Installing the daemon changes what
the portal answers (it must be restarted to re-read it):

| | before | after |
|---|---|---|
| portal `MaxRealtimePriority` | 0 | **20** |
| portal `MinNiceLevel` | 0 | **-15** |
| rtkit `RTTimeUSecMax` | (absent) | **200000 µs** |
| `RLIMIT_RTTIME` in any PipeWire ALSA client | **0 / 0** | **200000 / 200000** |
| PipeWire `data-loop.0` in that client | `SCHED_OTHER` | **`SCHED_RR` prio 20** |

### The phase 45 kill is retired, with evidence

The exact operation that killed rekordbox three times out of three —
`sudo chrt -r -p 5 <busiest callback tid>` — was repeated with rtkit installed:

    BEFORE: SCHED_OTHER
    applied SCHED_RR prio 5
      t+5s  ALIVE  policy=SCHED_RR
      t+10s ALIVE  policy=SCHED_RR
      ...
      t+30s ALIVE  policy=SCHED_RR

**T10's rule "never apply a real-time scheduling policy to this process from
outside" is withdrawn.** It was never a property of Wine or of rekordbox; it was
`SIGXCPU` against a zero budget.

## What rtkit did NOT fix

Measured immediately afterwards, `AudioBufferSize=256`, PC MASTER OUT on:
**1 teardown in 260 s** — indistinguishable from the ~1 per 195-330 s recorded
before. Real-time scheduling reached PipeWire's `data-loop`, **not rekordbox's
own callback threads**, which are still `SCHED_OTHER`.

So rtkit is a **prerequisite, not the cure** — exactly the distinction CLAUDE.md
insists on reporting. It makes real-time priority *possible and survivable*; it
does not by itself hand it to the threads that need it. That remains
`AvSetMmThreadCharacteristics`, which is now unblocked and, importantly, no
longer dangerous to implement.

### A measurement trap this produced

The same run reported **0.686x** from `bin/deckclock.sh`, which reads as a badly
struggling engine. It was not: the track (2:52) **ended at 172 s of a 240 s
window** and the clock sat at its length for the rest. `deckclock` now reads the
midpoint as well and reports VOID when the first half advances and the second
does not. Two-point arithmetic over a window longer than the track is exactly
the "confident wrong answer" shape T00 exists to catch.

## The decisive result: real-time and `WasapiPolling=1` are mutually exclusive

Before writing a `unixlib` and D-Bus code for `AvSetMmThreadCharacteristics`,
the cheaper question was asked first: **does making rekordbox's callback threads
real-time actually help?** `chrt` answers it without a Wine patch.

`AudioBufferSize=256`, PC MASTER OUT on, rtkit active, `sudo chrt -r -p 5` on
the busiest callback thread — **the process died**, and the teardown count was
unchanged at 1.

### The mechanism, isolated from rekordbox

A twenty-line C program, no Wine involved:

    $ sudo prlimit --rttime=200000:200000 chrt -r 5 ./rttest spin
    Killed
    $ sudo prlimit --rttime=200000:200000 chrt -r 5 ./rttest block
    RLIMIT_RTTIME soft=200000 hard=200000
    now SCHED_RR, mode=block (sleeps often)
      -> survived 6.0s with no signal

A real-time thread that **never blocks** exhausts any finite `RLIMIT_RTTIME`.
And because rtkit sets **soft equal to hard** (200000:200000), the kernel does
not deliver the catchable per-second `SIGXCPU` at all — it goes straight to
**`SIGKILL`**, which is why the death is silent and why installing a `SIGXCPU`
handler does not help.

### Why that is fatal for this application specifically

`WasapiPolling=1` is *the* PC MASTER OUT fix (T10). It makes rekordbox poll
`GetCurrentPadding` — measured at 114,871 calls/s — instead of waiting on an
event. That is precisely a thread that never blocks.

**So the fix that made PC MASTER OUT work and real-time scheduling cannot
coexist under any finite RT time budget.** Implementing
`AvSetMmThreadCharacteristics` to grant `SCHED_RR`/`SCHED_FIFO` would not
improve latency; it would kill rekordbox in the shipping configuration.

Earlier, the same `chrt` at `AudioBufferSize=512` survived 30 s — that thread
blocks often enough to stay under budget. The danger is a function of how hard
the thread spins, which makes it worse at exactly the small buffers real-time
priority is wanted for.

## The nice-level arm: no effect either

The one remaining safe form of the API was a **nice boost** — rtkit advertises
`MinNiceLevel = -15`, and nice has no `RLIMIT_RTTIME` interaction, so it cannot
kill anything. Measured with `bin/niceprobe.sh`, which runs both arms through an
**identical** protocol (the earlier numbers used different window lengths and
were not comparable): same buffer, same track, same 330 s window, reloading the
track when the 2:52 demo runs out.

| arm | buffer | nice | window | teardowns | alive |
|---|---|---|---|---|---|
| `baseline-256` | 256 | none | 330 s | **2** | yes |
| `nice15-256` | 256 | **-15** | 330 s | **2** | yes |

`runs/T12-nice/`. No difference.

## Verdict on defect 11 — implemented, it would not help

`AvSetMmThreadCharacteristics` is a Wine stub, and it should stay one for this
application. Both forms it could take have now been measured:

- **Real-time policy** — *fatal*. `WasapiPolling=1`, the fix that makes PC
  MASTER OUT work, makes the audio thread a 114,871-call/s spinner, and a
  non-blocking RT thread is `SIGKILL`ed against any finite `RLIMIT_RTTIME`.
- **Nice boost** — *no measurable effect*. 2 teardowns either way.

So the T10 line that this stub is "the ceiling on how low the latency can go"
is **not supported**. The 256-frame teardowns have some other cause, still
unidentified, and 512 samples remains the shipping configuration — which is
what a DDJ-400 user runs on Windows regardless.

The `RBW-MMCSS` block that lived only in the working tree has been **deleted**
rather than turned into a patch: `dlls/avrt/main.c` is now byte-identical to
pristine. Shipping an implementation this evidence says is useless-or-harmful
would have been the wrong way to close the T11 class of error.

## Open

- Can the limit be prevented? Candidates, cheapest first: a PipeWire client
  drop-in setting `rt.time.soft`/`rt.time.hard`, or `rlimits.enabled = false`,
  **scoped to rekordbox** rather than system-wide.
- Once RT is *possible*, does it actually help? The honest test is a 256-frame
  buffer soak with and without, counting teardowns — not an argument from
  first principles.
- Whether any of this is needed at all, given 512 samples is what a DDJ-400
  user runs on Windows.
