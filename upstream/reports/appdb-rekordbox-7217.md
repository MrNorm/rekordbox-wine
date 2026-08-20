# AppDB drafts — rekordbox 7.2.17

Two submissions. Both **unfiled**; AppDB needs a logged-in account.

---

## 1. New test report — rekordbox 7.2.17, wine-staging 11.15

**Application:** rekordbox
**Version:** 7.2.17
**Rating:** Garbage on Wine as shipped. **With one Wine stub implemented, the
application is fully usable** — see below; provisional Silver/Gold pending USB
export testing.
**Distribution:** Arch Linux
**Wine version:** wine-staging 11.15
**Installs:** Yes
**Runs:** No on Wine as shipped (renders one frame, then frozen). **Yes with the
linked dxgi patch** — signed in, full UI, playback with waveform and audio.

### Installation

Installs cleanly and **unattended**. The installer is NSIS v3.09, so `/S` works,
but note that `/S` does **not** suppress the "Please select a language" dialog —
send it a single Return and the rest completes without any clicks. 1.4 GB
installed. No winetricks verbs, no overrides and no `HideWineExports` shim were
needed; wine-mono and wine-gecko are installed in the prefix so .NET is not a
confound.

### What happens

The sign-in window renders **correctly and completely** — 682×562, all text
legible, no visual corruption. It then never redraws again. Typing produces
nothing on screen. Hovering a button produces nothing. Minimise/restore produces
nothing.

**This is not an input failure, despite looking exactly like one.** The
application is receiving and acting on input the whole time:

- Clicking [Cancel] closes the application. Clicking dead space does not.
- Text typed blind into the email field can be recovered with Ctrl+A / Ctrl+C
  and read out of the clipboard. It is in the field; it is simply never drawn.

### Cause and fix

Wine's `IDXGIOutput::WaitForVBlank` (`dlls/dxgi/output.c`) is a stub returning
`E_NOTIMPL`. JUCE 8 — which is what rekordbox's sign-in UI is built with —
drives every repaint from a VBlank listener rather than from `WM_PAINT`. The
call never blocks, so the vblank thread spins (~860 calls/second, measured) and
never dispatches a tick, so nothing is ever told to repaint.

With `WaitForVBlank` implemented, the same build **renders, accepts input and
repaints normally**. Bug report and patch filed upstream; see the linked bug.

### With the patch applied

Signed in successfully and reached the full application. A demo track imported,
played, drew its waveform, and produced audio. The AppDB 7.2.8 failure mode
("main window opens blank grey, process dies after an Importing… dialog") did
**not** occur here.

One dialog appeared on the way in — *"The configuration file cannot be read.
Restart with a backup file."* — after which the app restarted itself and
recovered cleanly. This is very likely self-inflicted rather than a Wine fault:
the prefix had been through many automated runs terminated with `kill -9`, which
can truncate the settings file mid-write. Noted here for honesty rather than as
a defect; retest from a clean prefix before treating it as one.

So the honest rating is: **Garbage on Wine as shipped, and the blocker is a
single Wine stub rather than anything about the application.** Patched, it
works.

### Notes

- Not GPU-specific. This is the first published result on an Intel iGPU (Iris Xe
  / Mesa 26.1.6) and it matches the existing Nvidia and AMD reports exactly,
  which is what you would expect from a bug in `dxgi` rather than in a driver.
- Disabling Direct2D (`WINEDLLOVERRIDES=d2d1=d`) does **not** help — JUCE's
  vblank repaint path is renderer-independent, so its software renderer starves
  in the same way.

---

## 2. Correction to test report iId=43369 (7.2.14, Wine 11.8)

That report says the sign-in text boxes "accept no keystrokes". I believe that
diagnosis is wrong, through no fault of the reporter — the two states are
completely indistinguishable on screen.

The keystrokes **are** accepted. The window never repaints, so they are never
displayed. Anyone can check this in about a minute without any special tooling:
click into the email field, type something, then press Ctrl+A and Ctrl+C and
paste the clipboard somewhere. The text is there.

The same applies to the "disabling winewayland.drv changes nothing" observation:
it would not, because the fault is in `dxgi`, which is driver-independent.

Root cause and patch: see the linked Wine bug. Worth correcting because "app
does not accept input" and "Wine stub starves the app's repaint clock" lead
investigators in completely different directions — and the second one is fixable
in a few dozen lines.

---

## 3. Updated test report — 2026-08-17, after five sessions of work

Supersedes §1 on everything except the `WaitForVBlank` root cause, which stands.
**One correction to §1: rekordbox is JUCE 7.0.9, not JUCE 8, and has no Direct2D
renderer.** The vblank patch is still necessary and load-bearing — it is the
frame clock — but the "JUCE 8" attribution was wrong.

### Honest rating today

**Silver, with one broken feature and one untested one.** Everything a DJ needs
to play a set works: library, analysis, waveforms, playback, and a DDJ-400
controller with working jog wheels, pads and LEDs. Two gaps are documented
below, and neither is a crash.

### What it takes (all four patches are in the linked bug reports)

| piece | why |
|---|---|
| `dxgi` `IDXGIOutput::WaitForVBlank` implemented | without it the app paints one frame and freezes |
| `mmdevapi` exclusive event-driven streams | without it the Sample Rate list is empty for every device |
| `winealsa` exclusive-mode event timing | without it playback does not sustain |
| `winealsa` MIDI via **rawmidi** instead of the ALSA sequencer | without it the controller hangs — see below |
| a user-mode USB host-controller shim (`\\.\HCD0`) | rekordbox validates the controller by walking HCD devices |
| `HKCU\Software\Wine\Drivers` `Audio=alsa` | winepulse implements no exclusive mode at all |
| `/dev/ntsync` | without it wineserver burns 43-65% of a CPU on this app's sync traffic |

### The controller — a Wine transport bug worth knowing about

A Pioneer DDJ-400 hangs, hard, if a MIDI SysEx is split across two USB
transfers. Wine's `midi_out_long_data` sends every SysEx through the ALSA
**sequencer**, which delivers userspace SysEx to the rawmidi port in 32-byte
chunks; the USB MIDI packetiser emits whole 3-byte packets only, so a 66-byte
authentication response goes out as 63 bytes and then 3, and whether the last
packet catches the same URB is a race. When it does not, the device stops
responding until it is physically power-cycled. Windows delivers a
`midiOutLongMsg` SysEx as one transfer; native Linux MIDI applications write to
rawmidi. Sending to rawmidi in Wine fixes it, and the controller then completes
its handshake and lights up every time.

This is not licence enforcement: the response is `FNV-1a-32` over the device's
own nonce and two compile-time constants, with no host-derived input.

### What works, measured rather than eyeballed

- Install: unattended, NSIS `/S` plus one Return on the language dialog.
- Sign-in, library, analysis, waveform display, playback with audio.
- **Frame rate 58 fps with a track playing, stable over ten minutes** (X DAMAGE
  counting, not a guess). The 30 fps you see idle is rekordbox's own limiter.
- The DDJ-400: authentication, LEDs, jog wheels, faders — on a plain launch.

### What does not work

- **PC MASTER OUT (playing to the controller and the computer's speakers at the
  same time) is broken.** With it on, the playback engine runs at **0.05x real
  time** and both output streams are destroyed and rebuilt every 15.8 s; track
  loads take 3-9x longer. With it off, everything runs at 1.00x. The fault is
  *not* in Wine's WASAPI path: a standalone test program opening the same two
  clients (one exclusive, one shared, both event-driven) keeps both fed at 100%
  of real time indefinitely. Still under investigation.
- **USB export to a DJ-ready stick: untested.** Nothing is known about it either
  way; do not read this report as evidence for or against it.
- Menus: the File menu never opens.

### One environment interaction worth flagging to anyone testing DJ software

Exclusive-mode WASAPI means Wine opens ALSA `hw:` devices directly. If PipeWire
tries to start a node on the same card at that moment, its open fails with
`EBUSY` — and on WirePlumber 0.5.15 the error handler then throws on its own
error message, so the node is never retried and **the device disappears from the
desktop until wireplumber is restarted**. That is a WirePlumber bug rather than
a Wine one (reproducible with `aplay -D hw:` and no Wine at all), but it will
bite anyone testing exclusive-mode audio under Wine, and it presents as "my
speakers vanished".
