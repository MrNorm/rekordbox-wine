# Searching the device-interface path format rekordbox will accept

Staged fallback for if the workflow's recommendation does not land first try.
Not yet applied.

## Why a search harness rather than one guess at a time

Each candidate format currently costs a full cycle: edit `alsamidi.c`, rebuild
`winealsa.so`, `sudo install`, restart rekordbox, wait ~95 s, grep. Call it four
minutes. A dozen plausible formats is the better part of an hour, and the format
space is bigger than a dozen.

But rekordbox *polls*: it issued 376 `DRV_QUERYDEVICEINTERFACE` pairs in one
90-second run. Every one of those is a free experiment we are currently
throwing away by answering identically each time.

So: return a **different candidate on each call**, log which was returned with
its index, and watch for the call sequence to diverge — the tell being a
`midiInOpen` that was never there before. One run then tests hundreds of
formats instead of one.

## The tension with "one variable per run", and how to keep it honest

The project rule exists because two simultaneous changes forfeit the result.
A cycling harness looks like it breaks that rule. It does not, provided:

- every returned string is logged with its call index, so the winning format is
  identified rather than guessed;
- the moment a divergence appears, the result is **re-run with that format
  pinned and nothing else changing**, and only the pinned run is citable.

The cycling run is a search. The pinned run is the evidence. Do not cite the
search run as the finding — that is exactly the mistake the rule guards against.

## Implementation sketch

In `midi_device_interface()`, replace the single `snprintf` with a table and a
selector:

    /* RBW_MIDI_IFACE=<n> pins one format (evidence runs).
     * RBW_MIDI_IFACE=cycle rotates per call (search runs). */
    static const char *fmt[] = {
        /* 0: what we return today */
        "\\\\?\\usb#vid_%04x&pid_%04x&mi_%02d#%s#{6994ad04-93ef-11d0-a3cc-00a0c9223196}",
        /* 1: winebus instance convention, mirroring the HID devnode */
        "\\\\?\\usb#vid_%04x&pid_%04x&mi_%02d#259&%s&0&0&0#{6994ad04-93ef-11d0-a3cc-00a0c9223196}",
        /* 2: Windows-shaped composite instance, interface in the last field */
        "\\\\?\\usb#vid_%04x&pid_%04x&mi_%02d#7&%s&0&%04d#{6994ad04-93ef-11d0-a3cc-00a0c9223196}",
        /* 3: same but claiming the HID interface number, in case it keys on
         *    the interface it already found rather than the MIDI one */
        "\\\\?\\usb#vid_%04x&pid_%04x&mi_04#259&%s&0&0&0#{6994ad04-93ef-11d0-a3cc-00a0c9223196}",
        /* 4: KSCATEGORY_RENDER rather than KSCATEGORY_AUDIO */
        "\\\\?\\usb#vid_%04x&pid_%04x&mi_%02d#%s#{65e8773e-8f56-11d0-a3b9-00a0c9223196}",
        /* 5: no \\?\ prefix — some callers store the interface without it */
        "usb#vid_%04x&pid_%04x&mi_%02d#%s#{6994ad04-93ef-11d0-a3cc-00a0c9223196}",
        /* 6: uppercase, as SetupDi tends to report device IDs */
        "\\\\?\\USB#VID_%04X&PID_%04X&MI_%02d#%s#{6994AD04-93EF-11D0-A3CC-00A0C9223196}",
    };

and `TRACE("RBW-IFACE[%d] -> %s\n", which, buf);` on every call so the log is
the experiment record.

## What "a hit" looks like

Grep the run for `midiInOpen`. Today it is absent entirely. If it appears,
find the `RBW-IFACE[n]` immediately preceding it, then pin `n` and re-run.

Secondary tells worth grepping for, in case binding is signalled some other way:

    aconnect -l                    a subscription appearing under client 20
    /proc/asound/card1/midi0       Tx bytes moving off 0 (it has never moved)

Tx is the strongest signal available: it has been 0 for the entire
investigation, and rekordbox lighting the controller's LEDs requires MIDI out.

## If nothing in the table hits

The assumption that a string format is the blocker is wrong, and the next step
is the debugger — breakpoint on the return from `midiInMessage` and watch what
the caller does with the buffer. See STATE.md.
