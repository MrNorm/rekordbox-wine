# WirePlumber: a failed ALSA node permanently removes the device, because the error handler throws

**Status:** draft, unfiled. **Component:** WirePlumber 0.5.15 (with PipeWire 1.6.8), `scripts/monitors/alsa.lua`.
**Reported by:** rekordbox-under-Wine project, 2026-08-17. Reproducer included, does not involve Wine.

## Summary

When creating an ALSA node fails — the ordinary case being another process
holding the PCM open, so `snd_pcm_open` returns `EBUSY` — WirePlumber's error
branch dereferences a property that does not exist on a node that never bound.
The Lua handler throws before it can log anything, the node is never stored, and
**nothing ever retries**. The sink or source disappears from the session for the
rest of the session, even after the other process has released the device.

On a desktop this presents as *"my speakers vanished and did not come back"*.

## The code

`/usr/share/wireplumber/scripts/monitors/alsa.lua`, `createNode`:

```lua
  local node = Node("adapter", properties)
  parent:set_managed_pending(id)
  node:activate(Feature.Proxy.BOUND, function (n, err)
      if err then
        log:warning ("Failed to create ALSA node " ..
            n:get_property ("node.name") .. ": " .. tostring(err))   -- line 425
      else
        monitorNodeError (n)
        parent:store_managed_object(id, n)
      end
  end)
```

`n:get_property("node.name")` returns nil for a node whose proxy never bound, so
the concatenation raises. The warning is never printed, `store_managed_object`
is never reached, and the id stays in the "pending" state.

Two independent problems:

1. **The message is built from an unavailable property.** The name is already in
   `properties["node.name"]`, which the function has in scope and which is
   always populated.
2. **A failed activation is terminal.** `EBUSY` is a transient condition by
   nature — the other client will close the device. There is no retry and no
   path back, so a momentary conflict costs the device permanently.

## Reproducer (about 30 seconds, no Wine, no special hardware)

Any card whose PCM can be opened directly. Here `hw:1,0` is a USB audio
interface; the built-in card behaves identically.

```sh
pactl list short sinks | grep -i <card>        # 1. the sink exists

aplay -D hw:1,0 -f S24_3LE -r 44100 -c 4 -t raw /dev/zero &   # 2. hold the PCM
sleep 2
head -1 /proc/asound/card1/pcm0p/sub0/status   # confirm: RUNNING

pw-play --target=<that sink> tone.wav          # 3. make PipeWire open it too

kill %1                                        # 4. release the PCM
sleep 3
pactl list short sinks | grep -i <card>        # 5. the sink is GONE, and stays gone
pw-play --target=<that sink> tone.wav          # a second attempt does not revive it

systemctl --user restart wireplumber           # only this brings it back
```

Observed journal output at step 3:

```
pipewire[…]: spa.alsa: 'hw:1,0': playback open failed: Device or resource busy
pipewire[…]: spa.alsa: 'hw:1,0': playback open failed: Device or resource busy
pipewire[…]: spa.alsa: 'hw:1,0': playback open failed: Device or resource busy
pipewire[…]: pw.node: (alsa_output.usb-…-00.pro-output-0-41) suspended -> error
             (Start error: Device or resource busy)
wireplumber[…]: wplua: [string "alsa.lua"]:425: attempt to concatenate a nil value
                stack traceback:
                        [string "alsa.lua"]:425: in function <[string "alsa.lua"]:422>
```

Note what is missing: the `Failed to create ALSA node …` warning the code
intends to emit. It cannot be emitted, which is why this has been hard to see in
the wild — the only trace is a Lua backtrace with no context.

## How it was found

An application using WASAPI exclusive mode under Wine opens ALSA `hw:` devices
directly, and does so repeatedly — the application under test tears its stream
down and rebuilds it every 15.8 s. On this machine that eventually coincided with
PipeWire starting its own node on the same card, and **every audio sink on the
system disappeared at once** (built-in speakers, three HDMI outputs and the USB
interface), leaving only the dummy fallback, for the rest of the login session.
The journal shows all eight opens failing with `EBUSY` within two seconds, and
fourteen consecutive `alsa.lua:425` Lua faults.

Any application that opens an ALSA device directly can trigger this: JACK
clients, `aplay -D hw:`, ALSA-native DAWs, and Wine or Proton games using
exclusive-mode audio.

## Suggested fix

Minimally, do not build the message out of a property that may not exist:

```lua
      if err then
        log:warning ("Failed to create ALSA node " ..
            tostring(properties["node.name"]) .. ": " .. tostring(err))
```

That restores the diagnostic. It does **not** fix the durability problem: the
device is still lost until wireplumber restarts. A complete fix should either
retry activation with a backoff, or return the id to the unmanaged state so a
later `udev`/profile event can recreate it. Contention over an ALSA PCM is
normal on a machine that also runs non-PipeWire audio software, and it should
cost a stream, not a device.

## Environment

    wireplumber 0.5.15, pipewire 1.6.8, Arch Linux, kernel 7.1.8-arch1-3
    card 0: sof-hda-dsp (ThinkPad E15 Gen 4), profile HiFi (…Speaker)
    card 1: Pioneer DDJ-400 USB audio, profile pro-audio
