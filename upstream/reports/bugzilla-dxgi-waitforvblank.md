# WineHQ Bugzilla draft — dxgi: WaitForVBlank returns E_NOTIMPL, starving vblank-driven repaint

**Attachments to upload with this report:**
`0001-dxgi-implement-WaitForVBlank.patch`, `vblanktest.c`, `build-vblanktest.sh`.

**Status:** draft, NOT yet submitted. bugs.winehq.org sits behind Anubis and
refuses automated fetches, so the duplicate search must be done by hand in a
browser before filing. Search at least: `WaitForVBlank`, `dxgi vblank`,
`JUCE repaint`, `IDXGIOutput`.

---

**Product:** Wine
**Component:** directx-dxgi
**Summary:** dxgi: `IDXGIOutput::WaitForVBlank` returns E_NOTIMPL instead of blocking, so vblank-driven repaint never ticks (JUCE 8 apps render one frame and freeze)
**Severity:** normal
**Keywords:** download, source

## Description

`dxgi_output_WaitForVBlank` (`dlls/dxgi/output.c`) is a stub that returns
`E_NOTIMPL` immediately. Any application that drives its frame clock from this
call is starved: the call never blocks, so the caller's vblank thread spins, and
because the call *failed* the caller never treats it as a vblank tick and never
requests a repaint.

JUCE 8 does exactly this. It does not repaint from `WM_PAINT`; it attaches a
`VBlankAttachment` and repaints from that callback. The visible result is an
application that paints one perfect frame at window creation and then freezes
permanently — while remaining fully alive and responsive.

**What is verified vs. inferred**, so you can weigh it: the API defect is
demonstrated directly by the attached reproducer, independent of any toolkit.
The end-to-end application symptom and its fix are verified on one JUCE 8 app
(rekordbox 7.2.17). That the same applies to *other* JUCE 8 applications is an
inference from JUCE's shared `VBlankAttachment` repaint path — consistent with
the two independent AppDB reports on different GPU vendors, but I have not
tested a second JUCE application myself.

**The symptom is badly misleading, and has been misreported as an input bug.**
The window still receives and processes input; it simply never redraws. Typed
text lands in the text field and is not displayed. Buttons work. Two AppDB
entries for rekordbox 7.2.x (iId=43369, iId=43000), on Nvidia and AMD
respectively, describe "text boxes accept no keystrokes", which I believe is
this bug seen from the outside.

## Minimal reproducer

`vblanktest.c` (attached) calls `WaitForVBlank` 200 times and reports the
achieved rate. It needs no application, no toolkit and no GUI. Build it with
clang against Wine's own headers and import libraries — `build-vblanktest.sh`
is attached too, and needs neither mingw-w64 nor root.

Measured here on a 60 Hz panel:

    $ wine vblanktest.exe                         # Wine as shipped
    calling IDXGIOutput::WaitForVBlank 200 times...
    last HRESULT      : 0x80004001  (200 of 200 calls failed)
    elapsed           : 0 ms
    achieved rate     : 999999 calls/second
    VERDICT: BROKEN — WaitForVBlank does not block.

    $ WINEDLLOVERRIDES=dxgi=n wine vblanktest.exe  # with the attached patch
    calling IDXGIOutput::WaitForVBlank 200 times...
    last HRESULT      : 0x00000000  (0 of 200 calls failed)
    elapsed           : 3331 ms
    achieved rate     : 60 calls/second
    VERDICT: OK — rate is consistent with a real display refresh.

200 calls returning in **0 ms** is the whole bug in one line.

## Steps to reproduce in a real application

Any JUCE 8 application. Observed with rekordbox 7.2.17:

1. Launch the app. The sign-in window renders correctly.
2. Click into the email field and type.
3. Nothing appears. The window never changes again — not on typing, hover,
   button press, minimise/restore, or occlude/expose.
4. Click Cancel. **The application exits**, proving input was being delivered
   and acted on the whole time.

To show the keystrokes really did arrive, read the field back out of the app
rather than looking at it — select-all, copy, and inspect the clipboard. The
typed text is there.

## Diagnosis

- `WINEDEBUG=+msg`: **zero** `WM_PAINT` in any slice — idle, on click, on
  keystroke — while `WM_USER` and `WM_SYSTIMER` traffic shows the message pump
  alive and busy. Nothing ever asks the window to redraw.
- `WINEDEBUG=+key`: Wine's keyboard path is intact end to end, through
  `PostMessageW(hwnd, WM_CHAR, ...)`. Input is not the problem.
- `WINEDEBUG=+dxgi`: `WaitForVBlank` is called **8,615 times in 10 seconds**
  while the app is idle (~860/s). The vblank thread is not dead, it is spinning
  on a call that returns instantly.
- Disabling Direct2D (`WINEDLLOVERRIDES=d2d1=d`) changes nothing, because
  `VBlankAttachment` is renderer-independent in JUCE 8 — the software renderer
  starves identically. So this is not a D2D presentation bug.

Note when reading logs: both `dxgi_output_WaitForVBlank` and
`DwmGetCompositionTimingInfo` log behind a `static once` guard, so at default
debug levels a million calls are indistinguishable from one. `+dxgi` is needed
to see the real rate. (`DwmGetCompositionTimingInfo` is *not* a stub — it
returns real values — and JUCE calls it once without using it as a clock.)

## Patch

Attached: `0001-dxgi-implement-WaitForVBlank.patch`.

It sleeps until the next estimated refresh boundary — refresh rate from
`EnumDisplaySettingsW`, period from `QueryPerformanceCounter` — instead of
returning `E_NOTIMPL`. This is an approximation, not a real hardware vblank; it
is offered as a starting point, and a proper implementation should presumably
come from the display driver. But it is enormously closer to the documented
contract than returning immediately, and it is sufficient to make the entire
class of applications usable.

One implementation note in case it saves someone the debugging: the wait must
round **up**. Truncating the millisecond conversion wakes the caller just before
the boundary, so the following call finds almost no time remaining and returns
at once — which yields ~109 calls/s on a 60 Hz panel instead of 60, i.e. the
app repaints at roughly twice the refresh rate and burns CPU doing it. Measured,
not theorised.

## Verification

Only `dxgi.dll` was rebuilt, from the wine 11.15 tree. Both DLLs below are the
same local build loaded through an identical path, differing only in the patch:

| dxgi build | vblanktest | rekordbox 7.2.17 |
|---|---|---|
| unpatched | `E_NOTIMPL`, 200 calls in 0 ms | one frame, never repaints |
| patched | `S_OK`, 60 calls/s | **repaints normally; typed text appears; app fully usable** |

Environment: wine-staging 11.15, Arch Linux, kernel 7.1.8, Intel Iris Xe /
Mesa 26.1.6, KDE Plasma / Wayland with XWayland, x11 driver.
