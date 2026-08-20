# Multi-agent audit of the patched Wine stack — 2026-08-16

**Provenance.** Produced by a 13-agent workflow (run `wf_7ed609c5-911`,
2.88M tokens) commissioned to do three things: build a theory of what rekordbox
does with the DDJ-400's USB, MIDI and audio interfaces; build the matching
theory of what Wine does differently; and audit the installed patch set
adversarially, one auditor per patch group with an independent refuter behind
each. Every agent was read-only and forbidden to launch rekordbox or touch the
hardware.

**Read this with three corrections in mind, established at the bench the same
afternoon and recorded in `docs/investigation/THEMES/T05-controller.md`:**

1. **Section 1.6 is right, and it is the most valuable single finding here.**
   `research/probes/authprobe.sh` renamed the MIDI port on every run. Verified and fixed —
   see T05 phase 22g. It invalidated my own race table.
2. **Section 4's H2 (device-state carry-over) deserves promotion.** Measured
   afterwards: the device re-issues `@AuthReq` every 10 s indefinitely when the
   auth is simply left unanswered (`research/probes/authreplay.py observe`), so any
   carry-over would have to be specific to a *completed or attempted* exchange,
   not to being ignored.
3. **Treat section 1.8's "live system state" and the H4 timing numbers with
   suspicion.** The 16:44–16:52 window they were measured in overlaps a period
   when the controller was verified **wedged** (`Tx stuck at 56640`), and a
   wedged DDJ-400 answers nothing. Re-run gated before believing them.

Superseded by the bench work: the framing of the auth as stalling at
`@AuthResponseE`. It does not. The full handshake completed at 16:18 —
`@AuthEnd` received, `enableDevice` ran, LEDs on, user-confirmed. See T05
phase 22.

---

# rekordbox-under-Wine — session deliverable, 2026-08-16 (evening)

**Read this before STATE.md.** Two things in this document overturn parts of `docs/investigation/STATE.md` phase 22/22b that are currently written as settled. Both are measured, both are cheap to re-check, and one of them is an instrument fault of exactly the class this project exists to catch.

**Headline, MEASURED this session (16:44–16:52 BST, commands and outputs below):**

1. `research/probes/authprobe.sh:72` sets `RBW_MIDI_RENAME="Generic MIDI Controller"` on **every** run, with or without `--rename`, because the default is `RENAME=0` and `${RENAME:+word}` expands for any non-empty value including `0`. Every one of the seven "plain launch → generic path" runs in the phase-22 race table was launched by that harness. **The startup race in `docs/investigation/STATE.md` is an instrument artifact.** Ten runs launched by anything else took the native `MidiMapDDJ400` path, including unperturbed ones.
2. The live blocker is not "generic path". It is: native path taken, `@Activate` keep-alives flow for **exactly 8.0 s**, the device never sends `@AuthReq`, and `DeviceMidi::timerCallback` tears the port down at the 8000 ms deadline and retries. **The "8000 ms teardown can no longer fire" claim in `docs/investigation/STATE.md` is wrong** — it cannot fire *once `@AuthReq` has arrived*, and `@AuthReq` has not arrived in any of the last nine runs.

The auth itself is solved (phase 22, run `20260816T161822-gdbwire`): all 66 bytes of `@AuthResponseE` left the wire ending `05 f7`, `@AuthEnd` came back, `enableDevice` ran, LEDs lit. The task brief this session was written against ("the auth stalls at `@AuthResponseE`, the device wedges") describes the frontier as of ~15:54, not as of now. Section 4 ranks hypotheses for what is actually in front of us.

---

## 1. WHAT THE INSTALLATION ACTUALLY IS

### 1.1 System-level footprint — three files, all installed today

Exhaustive `strings | grep RBW-` over `/usr/lib/wine`, `/usr/lib32/wine`, `/opt` hits exactly three files; `pacman -Qkk wine-staging` reports SHA256 mismatch for exactly these three and nothing else (wine-staging 11.15-1, all other package files dated 2026-08-09 15:09:02). [MEASURED]

| file | size | mtime | md5 | stock backup verified |
|---|---|---|---|---|
| `/usr/lib/wine/x86_64-unix/winealsa.so` | 453104 | 2026-08-16 14:39:40 | `a53f6afa2765e75dae4b0e7ce446c56f` | `.rbw-backup` = `9bac4c6c3ebfe6282bda5691fe14baa7`, bit-identical to the file extracted from `/var/cache/pacman/pkg/wine-staging-11.15-1-x86_64.pkg.tar.zst` |
| `/usr/lib/wine/x86_64-unix/wineusb.so` | 99640 | 2026-08-16 14:28:25 | — | `.rbw-backup` 18408 b, package mtime intact |
| `/usr/lib/wine/x86_64-windows/wineusb.sys` | 147456 | 2026-08-16 14:28:25 | `688368f633d6…` | `.rbw-backup` 55332 b = `13ac75c7b908eca9…`, package mtime intact |

A full revert is safe and is one command per component (`research/retired/install-system-wine-patches.sh --revert`, `research/retired/install-wineusb-hcd.sh --revert`). [MEASURED]

The installed `winealsa.so` is byte-identical to the build tree's output at `~/.cache/rbw-wine-build/wine-11.15/dlls/winealsa.drv/winealsa.so` (same md5), so every source line cited anywhere in this document is live code. [MEASURED]

### 1.2 Prefix-level footprint — five DLLs, two of them dead

`prefixes/rb7/user.reg:724` `[Software\Wine\DllOverrides]` contains exactly three entries: `"dxgi"="native"`, `"mmdevapi"="native"`, `"winmm"="native"`. [MEASURED]

| DLL in `system32` | marker | overridden? | actually loads? | evidence |
|---|---|---|---|---|
| `dxgi.dll` | `RBW-PATCH`, `RBW-VBLANK2` | yes | **yes** | `RBW-PATCH` ×2 in `runs/MIDI/20260816T145128-gdbauth/wine.log` |
| `mmdevapi.dll` | `RBW-MMDEV2` (patch 0010) | yes | presumed | md5 `decb5828869dfbea17df248331334bb5` = `artifacts/mmdevapi-patched-native-11.15.dll` |
| `winmm.dll` | **none** | yes | **unverifiable** | `strings … winmm.dll \| grep RBW-` → empty; patch 0007's winmm hunk plants no marker |
| `cfgmgr32.dll` | `RBW-CFGMGR` | **no** | **never** | `RBW-CFGMGR` ×0 in every run log; `loadorder.c:530` skips version heuristics for system-dir DLLs, `loader.c:1287` → `find_builtin_dll` → `/usr/lib/wine/x86_64-windows/cfgmgr32.dll` (stock, 158671 b, zero RBW strings) |
| `d2d1.dll` | `RBW-PAINT` | **no** | **never** | same mechanism; `T01-first-window.md:358` records it independently |

`STATE.md:266` asserts "prefixes/rb7 has cfgmgr32=native plus the patched cfgmgr32.dll (T06)". **That is false** and any reasoning that assumed patch 0005's `CM_Get_Child`/`CM_Get_Sibling` fixes were active in the device-tree walk is unsound. [MEASURED]

`prefixes/rb7/.../drivers/wineusb.sys` is the *stock* file (md5 `13ac75c7b908eca9…`) but is inert — it carries the "Wine builtin DLL" signature, so `loader.c:1263-1266` forces `LO_BUILTIN_NATIVE` and the patched `/usr/lib/wine/x86_64-windows/wineusb.sys` is what loads. `RBW-USBHCD` is emitted in the run logs, so this is confirmed rather than assumed. [MEASURED]

### 1.3 Marker inventory: what is tracked, what is inert

Installed `winealsa.so` carries ten markers. Only **two environment variables** are read by the whole library (`strings` finds exactly `RBW_MIDI_RENAME` and `RBW_MIDI_WIRE`; `objdump -d | grep -c getenv` = 7 call sites, all reaching those two strings at `0x123c5` and `0x1233b`). [MEASURED]

| marker | source | tracked patch | runtime status |
|---|---|---|---|
| `RBW-MIDIIFACE` | `alsamidi.c:376,395` | 0007 | feature unconditional, TRACE-only label |
| `RBW-MIDIENUM` | `alsamidi.c:672-674` | 0006 | feature unconditional, TRACE-only label |
| `RBW-DIAG`, `RBW-RAWFMT` | `alsa.c:2005,2024,2052`, `1979-1981` | 0008 | feature unconditional, WARN/TRACE-only |
| `RBW-EVENT3` | `alsa.c:821-826,1485` | **none** | **unconditional behaviour change** (audio event gating) |
| `RBW-WD`, `RBW-PAD` | `alsa.c:1435-1439`, `2252-2259` | **none** | sampled TRACE, racy static counters, harmless |
| `RBW-RENAME` | `alsamidi.c:424-431` | **none** | env-gated, inert unless `RBW_MIDI_RENAME` is set — **see §1.6** |
| `RBW-WIRE`, `RBW-RAW` | `alsamidi.c:438-458,1200-1221,1481-1536` | **none** | env-gated on `RBW_MIDI_WIRE`, *except* the inbound hex loop, which runs before the gate (`alsamidi.c:1226-1232` builds the string; the `getenv` is inside `rbw_raw` at `:451`) |
| `RBW-USBHCD` | `upstream/patches/rbw-usbhcd.c`, spliced by `bin/build-wineusb-hcd.sh:41-60` | tracked, unversioned | unconditional |

Patch 0004's port-naming change is the other unconditional behaviour change and its marker `RBW-NAME` is a comment only — it does **not** appear in the binary. The task brief's "the installed marker is RBW-EVENT" is wrong; it is `RBW-EVENT3`. Patch 0009 was written, measured, reverted and superseded by EVENT3 (`docs/investigation/THEMES/T03-audio-device.md:452`, `:708`; `JOURNAL.md:737`) — the numbering gap is benign. [MEASURED]

### 1.4 The binaries are not reproducible from this repository

- `DW_AT_comp_dir` in the installed `winealsa.so` is `~/.cache/rbw-wine-build/wine-11.15`. That tree exists, is **not a git repository**, and has no revision. [MEASURED]
- `.gitignore:1` is `artifacts/**`; `git ls-files artifacts/` returns only `.gitkeep`. The only copies of the compiled work are in a gitignored directory. [MEASURED]
- `upstream/patches/0002` and `upstream/patches/0003` are corrupt unified diffs: `patch -p1 --dry-run` → "malformed patch at line 63" / "line 65"; `git apply --check` → "corrupt patch at …:64" / "…:66". Cause confirmed with `cat -A`: hunk bodies contain bare empty lines where a context line needs a leading space. [MEASURED]
- `upstream/patches/0004` is **not a patch at all** — prose, no `---`/`+++` headers, a bare `@@`. `git apply --check` → "No valid patches in input". `research/retired/install-system-wine-patches.sh:13-25` documents it as one of the two patches the script carries. [MEASURED]
- The series does not apply in numeric order: 0007 is cumulative and re-contains 0004's naming hunk and 0006's `SUBS_*` filter verbatim (0007 lines 242-300, 364, 374); applying 0006 then 0007 gives "7 out of 15 hunks FAILED". [MEASURED]
- Applying all nine tracked patches to pristine 11.15 and diffing against the real build tree leaves **241 unaccounted changed lines in `alsamidi.c`** alone (`RBW-WIRE` ×8, `rbw_raw` ×5, `rbw_wire_log` ×3, `rbw_rename` ×3), plus 165 in `alsa.c`, 20 in `winmm.c`, 33 in `mmdevapi/client.c`, 48 in `dxgi/output.c`, 32 in `d2d1/device.c`. [MEASURED]

**Consequence for the mission:** the AUR deliverable cannot be built by anyone, including the next session. If `~/.cache/rbw-wine-build` is deleted, `RBW-WIRE`, `RBW-RENAME`, `RBW-EVENT3`, `RBW-WD`, `RBW-PAD` and the `RBW-VBLANK2` dxgi work are unrecoverable as source.

### 1.5 The packaging path is worse than "unbuilt" — it builds the wrong patch and cannot tell

- `bin/build-patched-dlls.sh:36` maps `[mmdevapi]="0002-mmdevapi-allow-event-driven-exclusive-streams.patch"` — **the superseded patch**, the configuration `docs/investigation/THEMES/T03` phase 12 measured as 6,963,363 `GetCurrentPadding` calls against 20 `GetBuffer` calls and 20 stream rebuilds in 100 s. `packaging/PKGBUILD` `check()` greps for `RBW-MMDEV`, which 0002 itself plants (`0002:57`), so the check **passes on the known-bad build**. `RBW-MMDEV` is also a prefix of `RBW-MMDEV2`, so no grep in the repo can distinguish them. [MEASURED]
- `bin/build-patched-dlls.sh:108` skips a patch when `grep -q "$marker" "$src"` — and the source tree already contains `RBW-MMDEV2`, of which `RBW-MMDEV` is a prefix. The script therefore prints "patch already applied" and builds the hand-edited tree. On a clean machine it would abort at `patch -p1` (0002 is malformed) under `set -euo pipefail`. **Local success is an artifact of the pre-existing edit.** [MEASURED]
- `winealsa` and `winmm` have no entry in the `PATCHFILE` map at all, and `PKGBUILD:108` packages `artifacts/*-patched-native-*.dll`, a top-level glob that does not reach `artifacts/winedll/`. So `bin/rekordbox-wine:133` fires `bad "winmm: no artifact for wine 11.15"`, and the recovery command the launcher prints at `:213` resolves to a file that is never packaged. The launcher's own text at `:210` says "system winealsa.so is stock — the controller CANNOT work without it". [MEASURED]
- `bin/rekordbox-wine:333` is `exec env WINEDEBUG="${WINEDEBUG:--all}" wine "$EXE"`. `-all` disables **err and fixme too**, so no `RBW-*` marker, no `RBW-USBHCD` load line and no genuine Wine diagnostic can appear in any user-reported log. The project's own rule ("a patch is not a fix until it is loaded and greppable") is satisfied on disk and defeated at runtime by the shipping launcher. [MEASURED]
- `research/retired/install-system-wine-patches.sh` has no Wine-version guard, and `winealsa.so` is a unix-side library whose unixlib entry-point table is version-coupled to ntdll. Its guard (`grep -q "RBW-EVENT"`, lines 48/64) is a prefix match that accepts the reverted `winealsa-0009-event2.so`. [MEASURED]

### 1.6 The instrument fault: `authprobe.sh` renames the controller on every run

`research/probes/authprobe.sh:35` — `SECS=45; RUNS=1; LABEL=auth; RENAME=0`
`research/probes/authprobe.sh:72` — `${RENAME:+RBW_MIDI_RENAME="Generic MIDI Controller"} \`

`${var:+word}` expands whenever `var` is set and **non-null**. `0` is non-null. Verified empirically just now:

```
$ RENAME=0; env FOO=1 ${RENAME:+RBW_MIDI_RENAME="Generic MIDI Controller"} printenv RBW_MIDI_RENAME
Generic MIDI Controller
```

The quoting inside the `:+` word suppresses word-splitting, so the value arrives intact and `env` runs `wine` normally — the bug is silent and fully functional. [MEASURED]

`rbw_rename` (`alsamidi.c:424-435`) then returns that string from both enumeration call sites (`:542`, `:632`), so `MIDIOUTCAPS.szPname`/`MIDIINCAPS.szPname` report `Generic MIDI Controller`. rekordbox's 60-entry model factory (`0x1423ab020`) matches on that name; it cannot match, so no `MidiMapDDJ400` is built, no `@Activate` is sent, no USB validation runs and no auth is attempted. **That is precisely the "generic path" signature the project has been chasing as a race.**

Consistency check across every run under `runs/AUTH/` (`grep -c 'len=12'` for `@Activate` keep-alives, `RBW-RAW IN` for inbound):

| harness | runs | native (`@Activate` present) | generic (no `@Activate`) |
|---|---|---|---|
| `authprobe.sh` (dirs ending `-rN`: `wirecount-r1`, `wire3-r1..r3`, `wirefinal-r1..r3`) | 7 | **0** | **7** |
| anything else (`gdbwire`, `hcdrace`, `plain-control`, `slow-taskset`×2, `wineusb1/2`, `gdb-early3`, `gdb-late1`, `helper`, `winmm`, `bothlayers`) | 12 | **12** | **0** |

Fisher exact on 7/7 vs 0/12 is p ≈ 1/C(19,7) — the association is not a coincidence. [MEASURED, this session]

`RBW_MIDI_RENAME` is also set unconditionally by `research/probes/glcensus.sh:49`, `research/probes/fpsmatrix.sh:191`, `bin/rbtest.sh:408` and `research/probes/test-midi.sh:261`. In the FPS/GL scripts it is a constant across arms, so intra-matrix comparisons survive; but none of those numbers is comparable to a run with a real `MidiMapDDJ400` bound.

### 1.7 Everything else the repo says about itself that is not true

- `STATE.md:519` lists `/etc/udev/rules.d/99-pioneer-ddj.rules` as a change to revert. That file does not exist. The installed rule is `/etc/udev/rules.d/60-pioneer-ddj.rules` (1091 b, renamed because `73-seat-late.rules` made the `99-` prefix a no-op). `REGRESSION.md:1063` has the right name; `docs/investigation/STATE.md` and `JOURNAL.md:634` have the stale one. [MEASURED]
- `research/probes/usbwire.sh:6-7`'s original comment about the Tx counter was wrong and has since been corrected in the file — `Tx bytes` counts `__snd_rawmidi_transmit_ack` (bytes packed into a URB), proven by disassembly: `__snd_rawmidi_transmit_ack` 0x57e `add %rsi,0x30(%r10)`; `snd_rawmidi_proc_info_read` 0xe56 reads `+0x30` immediately before the `"Tx bytes : %lu"` format string. Credit for self-correcting; the consequence still needs propagating — **the "Tx froze at 205 bytes" frontier is uninterpretable** (the per-run OUT total to that point was 130 B, and the counter is cumulative since card creation). [MEASURED]
- Root-owned files inside the working tree: `research/probes/.rbbreak_gdb.py`, `runs/MIDI/20260816T145128-gdbauth/hits.tsv{,.gdb}`. `snd_seq_dummy` is unloaded with no `/etc/modprobe.d` blacklist, so it returns on reboot and patch 0006's headline result is not reproducible on a default Arch install. [MEASURED]
- 32 top-level `runs/*.log` files with no run id and no manifest, `runs/index.jsonl` has 9 lines and zero of them; `*.log` is gitignored. `runs/MMDEV-TRACE.log` is the sole evidence behind two audit findings and 0010's entire commit message, and cannot be cited under the project's own rule. [MEASURED]

### 1.8 Live system state at the time of writing (16:44–16:52 BST, 2026-08-16)

- `lsusb -d 2b73:0026` → `Bus 003 Device 035`. `/proc/asound/cards` → `1 [DDJ400]`. `/proc/asound/card1/midi0` → `Tx bytes 56640`, `Rx bytes 13179`. Device is present and MIDI is flowing. [MEASURED]
- **A sibling session is running rekordbox right now**: `pgrep -a rekordbox` → pid 1543834, `wineserver` pid 1543837. Any device measurement taken in this window, including mine, is perturbed. [MEASURED]
- `journalctl -k --since 16:20` shows a repeating triple — `1:0: usb_set_interface failed (-110)` / +5.12 s `1:2: cannot set freq 44100 to ep 0x1` / +5.12 s `1:0: … (-110)` — at 16:33:49, 16:34:56, 16:35:38, 16:36:23, 16:38:53, 16:39:36, 16:42:10, 16:43:14, 16:45:46. Each triple is **~10.2 s of blocked EP0** (three 5 s `USB_CTRL_GET_TIMEOUT`s) and each coincides with a rekordbox launch. The DDJ's **control endpoint is timing out while MIDI still works** — a half-degraded state that the project's 0xFE health gate cannot see. [MEASURED]
- `fuser -v /dev/snd/*` → only `wireplumber` on `controlC1`; `pcm0p/sub0/status` = `closed`; `wpctl` shows sink 127 `DDJ-400 Pro` with no streams. PipeWire is not the opener; winealsa is (it enumerates with `snd_card_next`/`snd_ctl_open("hw:%u")` and never consults alsa-lib config or PipeWire). [MEASURED]

---

## 2. THEORY OF OPERATION — WINDOWS

Reconstructed from `rekordbox.exe` (7.2.17, 100,441,520 b) by disassembly: 168,533 `.pdata` functions, RIP-relative xref index, RTTI/vtable resolution; every address below was read as instructions, not guessed. [MEASURED unless marked]

1. **HID class enumeration at startup.** `DeviceHid::openDevice` (`0x1422e0ab0`) → HidMap factory (`0x1422df410`), 42 model names. **"DDJ-400" is absent**, and there is no `.?AVHidMapDDJ400@djplay@@` RTTI name. The DDJ's HID interface exists only so rekordbox can read a product string. *Depends on:* nothing the DDJ needs. *Consequence:* the DDJ-400 is subject to exactly **one** authentication, the MIDI one.
2. **Audio enumeration, on its own timer.** `0x141ce08d0` logs `audioDeviceListChanged WASAPI/CoreAudio`, `startTimer(3, 1000 ms)` → `0x141ce0a90` (`audioDeviceUpdate plugAndPlay!!`) → Plug&Play sort `0x141cd1830`. `0x141cc1570` canonicalises DDJ-400/FLX6/FLX4/FLX2/GRV6 to `"<model> WASAPI"`. **The DDJ-400 is not an ASIO device**: no `"DDJ-400 ASIO"` string exists, and it is absent from the driver-installer table. *Depends on:* WASAPI endpoint enumeration. *Independent of:* everything in steps 3-11.
3. **MIDI device list.** winmm `midiOutGetDevCaps`/`midiInGetDevCaps`; the model identity used downstream is `szPname`.
4. **Device arrival → `DeviceMidi::openDevice` (`0x1423a5210`).** Guard on `[this+0x340]`; first call is the validation wrapper `0x1423aaf40(deviceId=[this+8], name=[this+0x328])` at `0x1423a5255`; result stored at `[this+0x358]`; NULL → return false at `0x1423a5288`. *Depends on:* the **name** matching one of the 60 entries in factory `0x1423ab020`.
5. **USB validation.** The wrapper builds `MidiMapDDJ400` (vtable `0x143b88430`), `__RTDynamicCast` to `USBDeviceValidation` (`0x145b5a100`/`0x145b59d38`), calls vtable+0x18 = `0x142344af0`, which reads VID (`0x1423864f0` → 0x2B73) and PID (`0x142413990` → 0x0026) and tail-jumps to `0x141d69400` (bcdDevice). That walks `\\.\HCD0..9` with usbview IOCTLs `0x220424`, `0x220408`, `0x22040c`; logs `"bcdVersion = %04X"`; a negative result deletes the object and returns NULL. Results are cached in **globals** `0x145e34910` (18-byte descriptor), `…912` bcdUSB, `…91c` bcdDevice, `…922/923/924` flags, under one mutex `0x145b22170`. *Depends on:* at least one `\\.\HCDn`, correct VID/PID/bcdDevice from `IOCTL_USB_GET_NODE_CONNECTION_INFORMATION`.
6. **Mapping table load.** `0x14230c3c0` resolves `@AuthReq`, `@AuthChallengeA`, `@AuthResponseA`, `@AuthResponseE`, `@AuthEnd` into `DeviceAuth+0x150/0x160/0x168/0x170`. These come from the compiled 527 KB `MidiMapDDJ400` constructor (`0x1423b7e30`), **not** from `DDJ-400.midi.csv` — the shipped CSV (243 rows) has no `@` rows. *Consequence:* the CSV cannot be blamed for, or used to fix, the handshake.
7. **winmm MIDI open**, then `MidiOutputHelper` construction (`0x1423a54ee` → `0x1423a87d0`), which reads `MidiOutInterval` from the CSV (`Value=2`) and clamps to [1,16] — a 2 ms minimum spacing on all outbound MIDI.
8. **Keep-alive thread.** `0x1423a9270`: `sub eax,[rsi+0x260]; cmp eax,0xC8; jbe skip` — `@Activate` (12 B SysEx `F0 00 40 05 00 00 02 06 00 50 01 F7`) every 200 ms, unconditional, no reference to auth state, measured from the previous keep-alive.
9. **The device initiates.** `IN @AuthReq` (0x11, 12 B). `DeviceAuth::onMidiData` (`0x142341940`) sets `DeviceAuth+0x18A = 1` at `0x142341962`, state=1, sends `@AuthChallengeA`, `startTimer(0, 1000 ms)`.
10. **`OUT @AuthChallengeA`** (0x12, 52 B) — `PioneerDJ`, `rekordbox`, a `juce::Random` nonce (`0x1422a6290` → `%016llX`).
11. **`IN @AuthResponseA`** (0x13, 51 B) — TLVs: tag 02 model string `DDJ400`, tag 03 SeedE.
12. **`OUT @AuthResponseE`** (0x14, 66 B), built by `0x14237c9a0`. Four TLVs: tag01 `PioneerDJ`; tag02 `rekordbox`; tag04 = nibble-encoded `FNV-1a-32(SeedE ‖ (SeedE XOR 68 01 31 FB))` (basis `0x811C9DC5` at `0x1422a6528`, prime `0x01000193` at `0x1422a6546`; the adjacent log literal at `0x143b72008` reads `"PioneerDJ table = 68,01,31,FB"`); tag05 = a hard-coded 10-byte per-model constant selected by the **device's own** model string (`0x1422a6a7d`: `07 4A 26 AA 2E BE 92 E3 EF 95` for DDJ400). **Zero import calls anywhere in the seven functions of the call graph** — no clatc.dll, no lsapiw64.dll, no bcrypt, no crypto library. **No host-derived value participates at all.** Verified arithmetically: SeedE `00 00 53 DC` → `0x540855FE`, byte-identical to the wire in a *different* run.
13. **`IN @AuthEnd`** (0x15) → state=5, `"### @Auth Success!! ###"`, `startTimer(2, 1000 ms)`.
14. **`enableDevice`** (`0x1423a5c60`), in order: `settingDevice` (walks the whole mapping tree, `settingMidiMessages count = %d` per node — **this is the LED initialisation**); `dumpDevice` (`@Dump`, r9d=0xC8); `requestVersion` (`@ProductInformationRequest`); `requestSerialNumber` (`0x1423ad740`, regex `([A-Z]{4})(\d{6})([A-Z]{2})`, **after** auth and cosmetic only).

**Deadlines.** Per-step timeouts are 1000 ms and are **log-only** (`0x1423852e0`: `"@AuthResponseA timeout"`, `"@AuthEnd timeout"` — neither closes anything). The one real deadline is in `DeviceMidi::timerCallback` (`0x1423a7380`): elapsed ≥ 8000 ms (`0x1424070a0`: `cmp rdx,0x1f40; setge al; ret`) **AND** `cmp byte [rdi+0x18a], 0` equal — i.e. **only if no `@AuthReq` has ever been seen** — then teardown at `0x1423a748b`; otherwise re-arm at 1000 ms.

---

## 3. THEORY OF OPERATION UNDER WINE — the fidelity ledger

Legend: **(i)** fixed by an existing patch · **(ii)** open defect · **(iii)** unknown/unmeasured.

| # | Windows step | What Wine does differently | Class | Evidence |
|---|---|---|---|---|
| 1 | HID enumeration | Equivalent. Hiding `/dev/hidraw0` changes nothing (T05 phase 8, one variable, replugged first). | — | MEASURED |
| 2 | Audio enumeration on a 1 s Plug&Play timer | winealsa opens the DDJ's PCM directly (`plughw:1,0`, `user.reg:758`), bypassing PipeWire. Each probe cycle issues `SET_INTERFACE` + UAC1 `SET_CUR` on EP0 of the same device, and this firmware **silently ignores** the class sample-rate control instead of stalling it → three 5 s timeouts, **~10.2 s of blocked EP0 per launch**, still happening as of 16:45:56 today. The DDJ is absent from `snd-usb-audio`'s quirk table (`modinfo -F alias snd_usb_audio \| grep 2B73` → 11 entries, all `icFF`, 0026 not among them). | **(ii)** open, kernel-side quirk missing; Wine's contribution is that it probes at all | MEASURED |
| 2b | Windows: shared-mode mix format from the endpoint | Patch 0008 rewrote `alsa_get_mix_format` to query `hw:` unconditionally (`alsa.c:2087`, no share test) while `alsa_create_stream` still opens `plughw:` (`alsa.c:840`). Every explicitly-selected `plughw:C,D` endpoint drops from 32-bit float to 16-bit PCM; the preference ladder at `alsa.c:2107-2124` tests S16 before S32, so it now reports the *lowest*-quality format the hardware offers. `default` is unaffected. | **(ii)** open (half-applied patch + wrong ladder order) | MEASURED |
| 2c | — | `map_channels_for_share` (`alsa.c:1948-1957`) writes `fmt->nChannels` ints into `int[32]` with no bound, on paths stock Wine never reached (capture, plain PCM). Application-controlled overflow. | **(ii)** open, security-relevant, must be clamped before upstreaming 0008 | MEASURED |
| 3 | MIDI device list | Stock Wine enumerated by `CAP_READ`/`CAP_WRITE` and listed PipeWire's non-subscribable ports and Wine's own loopback ahead of the hardware. Patch 0006 filters on `SUBS_*`. | **(i)** fixed — but see 3b/3c | MEASURED |
| 3b | | 0006's self-skip is by **client id** (`alsamidi.c:670,678,694`), so it hides only *this* process's ports. Another Wine process's `WINE midi driver` client (rekordboxAgent runs concurrently) is still enumerated, and 0006's `SUBS_*` filter now admits those ports to **both** lists (cap 0x61/0x62 seen live in `/proc/asound/seq/clients`). `JOURNAL:822` records `MIDI OUT [0]='WINE ALSA Output #1'` — a port with no `CAP_WRITE` that only the patched filter could list. | **(ii)** open regression introduced by our own patch | MEASURED |
| 3c | | `alsa_midi_init` is one-shot (`static BOOL init_done`, `alsamidi.c:646-656`) and sets the flag *before* it can fail (`:656` then `:659`). MIDI hot-plug can never work, and one transient sequencer failure permanently gives the process zero MIDI devices with no error path. Two-pass ordering (`:676-689` non-`PORT` types first) structurally sorts application ports ahead of hardware. | **(ii)** open, upstream bug, AUR-relevant | MEASURED |
| 3d | Windows: `szPname` is the device name | Patch 0004 collapses `"X MIDI 1"` under client `"X"` to `"X"` — correct for the DDJ, produces duplicate names for multi-port devices. `wMid`/`wPid`/`vDriverVersion` remain Wine placeholders (`0x00FF`/`0x0001`/`0x001`) although `dest->card` is in hand. | **(i)** for the DDJ, **(iii)** whether rekordbox reads wMid/wPid | MEASURED / INFERRED |
| **3e** | | **`RBW_MIDI_RENAME` overrides `szPname` when set — and `research/probes/authprobe.sh:72` sets it on every run.** This forces step 4 to fail by construction. | **(ii)** open **instrument** defect, not a Wine defect | MEASURED (§1.6) |
| 4 | `openDevice` name→model match | Faithful *if* the name is `DDJ-400`. Measured in twelve non-authprobe runs: the native path is taken and `@Activate` flows. | — | MEASURED |
| 5 | usbview walk of `\\.\HCDn` | Wine has **no** `\\.\HCDn` at all; `upstream/patches/rbw-usbhcd.c` implements it. Confirmed serving correct data even in failing runs: `RBW-USBHCD: hub 0 port 4 -> VID_2B73 PID_0026 rev 0103` (`runs/AUTH/20260816T163841-wineusb1/wine.log`, t=347112.151), MIDI opened 92 ms later. Struct layouts (18/35/76) verified against rekordbox's own reads. Driver wins the creation race by 14.7 s (phase 22b). | **(i)** fixed | MEASURED |
| 5b | | Residual defects in that driver, none currently firing: `IOCTL_USB_GET_DESCRIPTOR_FROM_NODE_CONNECTION` (0x220410) returns `STATUS_NOT_SUPPORTED` for string descriptors (`:286-290`) — and rekordbox *does* reach that path via the global-flag shortcut at `0x141d69e73`, observed firing in `runs/MIDI/20260816T143942-rawprobe/wine.log:3734`; hub recursion IOCTL 0x220414 unimplemented (it is the hinge of hub topology, not cosmetic — `0x141d6a257` recurses); `ConnectionStatus` and `CurrentConfigurationValue` hard-coded to 1, so a present-but-broken device is reported healthy; 16-port root hub and a 64-device cap applied in `readdir` order **before** the sort; `rbw_read_attr` truncates at 1023 B and `config_desc[512]` truncates again (device 3-7 is 1360 B); unsynchronised function-static scratch buffers shared by all IRP threads; the bus→HCD map is a one-shot `DriverEntry` snapshot; the walk's per-port result is TRACE-only so **no harness run can positively confirm the gate passed** without `+wineusb`. | **(ii)** open, mostly latent | MEASURED |
| 6 | Mapping table from the compiled map | Identical — nothing Wine touches. | — | MEASURED |
| 7 | winmm open | `midi_out_open` reports **success when the ALSA subscription fails** (`alsamidi.c:806-823`, only a WARN); `midi_in_open` returns `MMSYSERR_NOTENABLED` but **leaks** `src->midiDesc.hMidi` and a `seq_refs` reference (`:1474-1477`), so one refused subscription bricks that device for the process lifetime with a misleading `MMSYSERR_ALLOCATED`, and the process-wide `WINE ALSA Input` port survives to be enumerated by every other Wine process. Present in pristine 11.15 → publishable upstream bug. | **(ii)** open, upstream | MEASURED |
| 8 | 200 ms keep-alive | Reproduced exactly: cadence 200-202 ms across 964 messages, undisturbed by the auth (`runs/MIDI/20260816T145128-gdbauth`). All outbound MIDI including the 66-byte SysEx is on **one** thread (0698) — T05's "keep-alives from a different thread" row is refuted. | — | MEASURED |
| 9 | `IN @AuthReq` | Delivered. The earlier "zero inbound events" claim was an instrument artifact (`rec_thread_proc` is a raw pthread with no Wine TEB, so `ERR()`/`TRACE()` print nothing; replaced with `rbw_raw`, a direct `write(2)`). **But in the last nine runs `@AuthReq` never arrives at all** — see §4. | **(iii)** unknown: device-state or host-state | MEASURED |
| 10-12 | Challenge/response | Faithful. Round trip measured at 6 ms (`OUT 52` at t=340664.465, `IN 51` at .468, `OUT 66` at .471). Interleaving from inside Wine is **impossible**: one process-global `seq_mutex` (`alsamidi.c:78`), one `snd_seq_t`, and `snd_seq_event_output_direct` linearises header+payload into one temp buffer and issues a single `write(2)` (libasound 1.2.16.1 disassembly at 0xbae30 → 0xbadd8). | — | MEASURED |
| 12b | Windows: a failed output is reported | Wine **discards** `snd_seq_event_output_direct`'s return (`alsamidi.c:1110`, and `:1014` for short messages) and unconditionally sets `MHDR_DONE` and returns `MMSYSERR_NOERROR` (`:1121-1124`). This is exactly the shape of "308 more `midiOutLongMsg` calls with nothing on the wire". **Prerequisite, not cure**: the kernel's `dump_midi` drop happens *inside* a successful `write(2)` and returns void, so a checked return would still often see 0. | **(ii)** open, upstream; report as prerequisite | MEASURED |
| 12c | | Kernel truncation hazard below Wine: `dump_var_event` (snd-seq.ko, `cmp $0x1f`/`mov $0x20` at 0x4eb3) chunks a userspace SysEx into 32 B, `__dump_midi` (snd-seq-midi.ko 0x11c8) drops a chunk all-or-nothing when `runtime->avail < count`, and the dumper **aborts the remainder** (`js` at 0x4ea0). With 32-63 B free, a 66-byte SysEx goes out as 32 bytes with **no F7** — the exact condition proven to wedge this device. 1781+ `MIDI output buffer overrun` lines in dmesg prove the drop path fires here, and printk rate-limiting makes that a lower bound. **Refuted for the successful run**: phase 22 shows all 66 bytes with `05 f7` at the wire. | **(ii)** open latent; **not** the cause of the observed stall | MEASURED |
| 12d | Windows: no running-status compression | ALSA's seq→rawmidi bridge applies running-status compression (`snd_midi_event_decode` 0xab5-0xac3; `no_status` never called). Harmless for SysEx (auth unaffected); affects the 261 NoteOn + 36 CC of LED init. | **(iii)** unknown whether the DDJ cares | MEASURED mechanism / INFERRED impact |
| 12e | | Zero-length `MIDIHDR` → `data[hdr->dwBufferLength - 1]` at `alsamidi.c:1068` reads `data[-1]` (index `0xFFFFFFFF`), and the repair branch emits a fabricated 2-byte `F0 F7` the app never asked for. The generic path emits exactly "one degenerate 2-byte `F0 F7`" per T05 phase 22 — i.e. **this path is being taken in production**. | **(ii)** open, upstream, memory-safety | MEASURED |
| 13 | `IN @AuthEnd` | Achieved, once (`runs/AUTH/20260816T161822-gdbwire`, `runs/WIRE/20260816T161822-gdbwire.pcap`). | — | MEASURED |
| 14 | `enableDevice` / LEDs | Achieved once: 261 NoteOn + 36 ControlChange, zero URB errors, user confirmed lights and controls at the hardware. Not yet reproduced. | **(iii)** reproducibility unknown | MEASURED |
| — | The 8000 ms teardown | Reachable and **firing**: `runs/AUTH/20260816T164259-gdb-late1` contains two complete cycles of `midi_in_open` → exactly **40** keep-alives (8.0 s) → `RBW-RAW recthread CANCELLED`, on two different threads (0734, 0768), matching two `openDevice` entries in `hits.tsv` at t=2.096 and t=28.809, both returning `rax=0x1` with a non-NULL `MidiMap`. | **(iii)** why no `@AuthReq` | MEASURED, this session |

---

## 4. RANKED HYPOTHESES

**Re-targeted.** The brief's question ("why the auth stalls at `@AuthResponseE`, why the device wedges") is answered and should be retired:

- **Why it wedges: an unterminated SysEx.** `research/probes/authreplay.py`, three arms, one variable, no Wine in the path: *observe* → healthy 25 s; *well-formed but knowingly wrong payload* → healthy 25 s, device retries; *identical message with the F7 removed* → dead from that instant, needs a physical power cycle. Wire-confirmed in `runs/WIRE/20260816T151707-authtrunc.pcap` frame 148: 21 USB-MIDI packets, **every** CIN nibble 0x04, no end packet, then seven consecutive EP 0x03 submits with zero completions from t=9.101. [MEASURED]
- **Why the auth stalled: it does not, when the device answers.** Phase 22 got all 66 bytes out with `05 f7` and `@AuthEnd` back. The Wine-truncation hypothesis is dead for this path. [MEASURED]

What remains is: **the device does not initiate `@AuthReq`, so rekordbox tears down at 8 s and loops.** Ranked below by probability × cheapness.

### H1 — The phase-22 "startup race" does not exist; it is `authprobe.sh`'s always-on rename. **p ≈ 0.9**

*Mechanism.* `research/probes/authprobe.sh:72` exports `RBW_MIDI_RENAME="Generic MIDI Controller"` on every invocation (`${RENAME:+…}` with `RENAME=0`). `rbw_rename` rewrites `szPname` at both enumeration sites, rekordbox's 60-entry model factory cannot match, no `MidiMapDDJ400` is constructed, and the run shows the documented generic signature: no `@Activate`, one degenerate 2-byte `F0 F7`, 248 CSV short messages, zero inbound. Every "plain launch" cell in the phase-22/22b tables was an authprobe run.

*For:* the bash expansion verified empirically; 7/7 authprobe runs generic vs 12/12 non-authprobe runs native, with the split falling exactly on the harness and not on the perturbation; `plain-control` and `wineusb1/2` are unperturbed and native; T05 phase 9/10 already documents this rename as *the* generic-path workaround.
*Against:* nothing found. The only residual is whether some phase-22 "plain launch" runs used a launcher I have not identified — the run directory naming (`-rN` suffix = authprobe) accounts for all seven.
*Prior reasoning:* two independent lines (code semantics + a clean 19-run partition) agree, and the mechanism is already documented elsewhere in the repo as producing exactly this signature.
*Killer experiment:* **N1** — fix line 72, run the identical arm ×3.

### H2 — Device-state carry-over: after an auth attempt the DDJ stops issuing `@AuthReq` until power-cycled. **p ≈ 0.55**

*Mechanism.* The DDJ initiates auth on its own ~10 s clock (STATE phase 21 item 3, measured Wine-free). After a completed or stalled handshake it appears to stop initiating: every run from 16:34 onwards took the native path, sent `@Activate` correctly, and received **zero** inbound bytes. The two runs that got `@AuthReq` (`gdbwire` 16:18, immediately after a physical replug; `hcdrace` 16:32) are the two earliest in the native series, and `hcdrace` ended at the old frontier (`52` and `66` out, 2 inbound, no `@AuthEnd`).

*For:* strict time-ordering of the three regimes; `hcdrace` is the last run to get `@AuthReq` and is also the last run to send `@AuthResponseE`; the concurrent EP0 `-110` timeouts show the device is in a degraded but not dead state; `/proc/asound/card1/midi0` shows Tx moving, so the 0xFE health gate **passes on a device in this state**.
*Against:* confounded with time — a sibling session has been changing the machine throughout; the device has not been replugged since ~16:18 as far as I can tell, so "power-cycle restores it" is untested. INFERRED, not measured.
*Killer experiment:* **N3** then **H-1** — `authreplay.py --observe` (Wine-free) right now: if the device issues `@AuthReq` to a bare Linux writer, the device is fine and the fault is in rekordbox/Wine; if it does not, and a power cycle restores it, H2 is confirmed and every run since 16:33 is VOID.

### H3 — The auth is fine and only the *harness window* was too short. **p ≈ 0.2**

*Mechanism.* In `wineusb1` the HCD walk lands at t=347112.151 — **28.6 s after process start** — and keep-alives run 347112.243→347120.111 (7.87 s) before the log ends. The device's `@AuthReq` cycle is ~10 s. A run whose observable window after MIDI open is under 10 s can miss the first `@AuthReq` by construction.

*For:* the arithmetic; `authprobe`'s default is `--secs 45` against a 28.6 s time-to-MIDI-open.
*Against:* `gdb-late1` shows two *independent* 8.0 s cycles inside one run, each terminated by `recthread CANCELLED` — that is rekordbox's own 8000 ms teardown, not a harness kill, and rekordbox tears down before the device's 10 s clock can fire. So the window is only half the story: **rekordbox and the device have incompatible retry periods (8 s vs 10 s) whenever the device is not already primed.** That sub-mechanism is itself a strong candidate and inherits most of H3's probability.
*Killer experiment:* **N4** — 3 runs at 120 s with `+timestamp`, measuring time-from-`midi_in_open`-to-first-inbound. If `@AuthReq` arrives at 8-10 s and rekordbox has already torn down, the fix is Wine-adjacent only in that the *whole startup* is slow; the real fix is to shorten time-to-MIDI-open.

### H4 — Wine's slow startup loses the race with rekordbox's own 8 s deadline, and the audio EP0 stalls are why startup is slow. **p ≈ 0.35 as a contributor, ≈0.1 as the sole cause**

*Mechanism.* Each launch spends ~10.2 s with the DDJ's EP0 blocked in three 5 s UAC1 timeouts (measured today at 16:33-16:45, nine triples). Patch 0008 made exclusive-mode validation query the raw device, and patch 0010/0002 let `EXCLUSIVE|EVENTCALLBACK` through, so Wine now performs `hw_params`/`prepare`/`hw_free` cycles on the DDJ that stock Wine refused. `T03` phase 12 measured 20 stream rebuilds in 100 s pre-0010. That is a large, patch-introduced perturbation of the same device, concurrent with MIDI bring-up, and it plausibly explains a 28.6 s time-to-MIDI-open.

*For:* the `-110` triples are measured, current, and correlate with launches; the mechanism (`snd_usb_endpoint_prepare`/`_close` → `SET_INTERFACE` + `SET_CUR`) is confirmed by disassembly of `snd-usb-audio.ko` (`init_sample_rate` 0x35a0, `endpoint_set_interface` 0x2f90, both file-static with only in-file callers).
*Against:* the MIDI wedge and the `-110` errors were shown to be independent as *wedge* causes (the two longest overrun bursts, 506 s and 121 s, had zero audio-interface traffic). Independence as a *wedge* cause does not imply independence as a *timing* cause, which is what this hypothesis claims.
*Killer experiment:* **N9** — an `RBW_ALSA_SKIP_CARDS` env-gated skip in `alsa_get_endpoint_ids`, 3 runs each arm, measuring `-110` count and time-to-`midi_in_open`.

### H5 — Enumeration-composition race: foreign Wine loopback ports shuffle MIDI indices between runs. **p ≈ 0.15**

*Mechanism.* 0006 skips only the calling process's client. rekordboxAgent's `WINE midi driver` client (ports `WINE ALSA Output` cap 0x61, `WINE ALSA Input` cap 0x62, both admitted to both lists by 0006's `SUBS_*` filter) exists or not depending on process start order, and `alsa_midi_init` freezes the list one-shot. A shifted index means rekordbox opens the wrong device, or opens a loopback port that swallows output silently (`midi_out_open` reports success on a refused subscription).

*For:* `JOURNAL:822` measured `MIDI OUT [0]='WINE ALSA Output #1'`; the mechanism is real and is our own patch's regression.
*Against:* all 966 `RBW-WIRE OUT` lines in the reference run are `dev=0`, and every native run reaches `@Activate` on `dev=0` — so the DDJ has been at index 0 in every observed run.
*Killer experiment:* one unconditional `ERR` at the end of `alsa_midi_init` printing `num_dests`/`num_srcs` and each `szPname`; correlate across 3 runs per arm. Fold into **N6**.

### H6 — usbview global-cache reuse demands the unimplemented string-descriptor IOCTL. **p ≈ 0.1**

*Mechanism.* A second walk in the same process short-circuits at `0x141d69e73` (`cmp byte [0x145e34922],0; jne 0x141d6a00e`) straight to the serial fetch, issuing IOCTL 0x220410, which `rbw-usbhcd.c:286-290` refuses with `STATUS_NOT_SUPPORTED` → the entry point returns -1 → `openDevice` deletes the `MidiMapDDJ400`.

*For:* the FIXME is observed firing at `runs/MIDI/20260816T143942-rawprobe/wine.log:3734`, 599 s into a run where `enableDevice` never ran — so it is *not* gated behind `@AuthEnd` as previously written.
*Against:* phase 22c's failing run never issued 0x220410, and today's native runs get past validation (`hits.tsv` shows the wrapper returning non-NULL).
*Killer experiment:* implement 0x220410 for string descriptors from `/sys/bus/usb/devices/3-9/serial` (about 30 lines) and re-run. Cheap and it removes a known wrong answer regardless.

### H7 — Concurrent `openDevice` calls clobber the usbview globals. **p ≈ 0.05**

*Mechanism.* The four walk entry points are mutex-guarded per call but write to shared globals `0x145e34910..24`. Two DeviceMidi objects validating concurrently (possible only if Wine presents more than one MIDI device) could read another device's descriptor.
*For:* the design genuinely permits it. *Against:* only one MIDI device is enumerated in every observed run.
*Killer:* subsumed by H5's enumeration log.

### H8 — Small-sample artifact in the original race table. **p ≈ 0.05 as an independent explanation**

Fisher exact on the published 0/10 vs 3/3 gives p ≈ 0.0035, so the *association* was real. H1 explains it as confounding rather than chance, which is why this ranks last rather than being dismissed.

### Residual, for the wedge (not currently blocking)

The kernel 32-byte chunk-drop path (§3, 12c) remains an un-instrumented route to a permanent hardware wedge whenever the 4096-byte rawmidi ring is tight. It did not fire in the successful run, but nothing prevents it during heavy LED/performance traffic. Fixing the discarded `snd_seq_event_output_direct` return is a **prerequisite** (it makes the failure visible); the **cure** is either a larger `output_buffer_size` or per-message flow control. Report them differently.

---

## 5. CRITIQUE OF THE PREVIOUS WORK

### Methodology errors

1. **Instrumented arms and control arms used different harnesses.** The phase-22 race table compares `authprobe.sh` runs against ad-hoc launches and attributes the difference to gdb. The harness *itself* was the variable, and it was the one variable nobody wrote down. This is a one-variable violation dressed as a one-variable experiment, and it produced a headline ("a startup race in rekordbox") that has consumed the last three phases.
2. **`${RENAME:+…}` with `RENAME=0`.** A five-character bug that inverted every result the harness produced. The lesson the project already learned twice (black x11grab captures; TRACE from a non-TEB pthread) applies to *outputs* — this is the same lesson applied to *inputs*: **prove the harness passes the environment you think it does**, e.g. by echoing the child's `/proc/<pid>/environ` into the run directory.
3. **Outcome classification conflated two different failures.** Runs `163443`, `163526`, `163610` are recorded in `docs/investigation/STATE.md` 22b as "generic". They contain 40 `@Activate` keep-alives each; `@Activate` exists only in the compiled `MidiMapDDJ400`. They took the **native** path and failed at a later step. Classifying "no auth" as "generic path" hid a third outcome for three phases.
4. **A frontier number quoted for two days with no baseline.** "Tx froze at 205 bytes" mixes traffic from earlier port sessions; the per-run OUT total at that instant was 130 B. Only Δ(Tx) is meaningful and nobody measured it. The project's own `research/probes/authprobe.sh` captures before/after wire checks and the arithmetic was never done.
5. **Decisions made inside the noise band.** Patch 0009 was rejected on wineserver CPU 46.6% vs 43.5% (`T03:720`), against a stated natural range of 42-47% (`T03:698`) — and the 46.6% figure is now frozen into a source comment at `alsa.c:1491` where the next reader will take it as established.
6. **Evidence not retained.** Patch 0003's headline "343 refusals of 344" cites `upstream/wasapitest-output-event.txt`, which records "periods serviced: 1" from the *superseded* probe. The corrected probe's transcript was never saved. 32 top-level `runs/*.log` files carry the whole audio evidence base with no run id, no manifest and no git.

### Claims still standing as settled that I would reopen

| claim | where | status |
|---|---|---|
| "The 8000 ms teardown can no longer fire" | `docs/investigation/STATE.md` phase 22 | **Wrong as written.** It fires whenever `@AuthReq` never arrives; measured twice in one run (`gdb-late1`). |
| "plain launch: 0 native / 8 generic — a startup race" | `docs/investigation/STATE.md` phase 22/22b, `T05` | **Void.** Confounded with the authprobe rename. |
| "interfaces 0 and 2 = AUDIO" | task brief, `JOURNAL`, themes | **Wrong.** `lsusb -v`: iface 0 and 2 are AudioControl; **iface 1** is the only AudioStreaming interface (EP 0x01 OUT, altsets 0/1/2, 4 ch, 44100 only); iface 3 MIDIStreaming; iface 4 HID. The dmesg field `1:N` is iface:altsetting. |
| "cannot get freq at ep 0x1 recurs every 5 s at idle" | task brief | **Wrong.** It is a fixed three-message burst at probe time (5.04/5.12 s apart = `USB_CTRL_GET_TIMEOUT`), and it stops. Confirmed by `dmesg -c` and 16 minutes of silence. |
| "prefixes/rb7 has cfgmgr32=native" | `STATE.md:266` | **False.** Three overrides only; patch 0005 and the d2d1 `RBW-PAINT` build have never loaded. |
| "full-fidelity wire log, both directions" | `alsamidi.c:1206-1208` comment, `JOURNAL` 14:05 | **False and already retracted in STATE** — 64-byte OUT cap, 32-byte IN cap with no marker. Fix the comment; it is still in the source. |
| "revert `/etc/udev/rules.d/99-pioneer-ddj.rules`" | `STATE.md:519` | Targets a nonexistent file; the real rule is `60-pioneer-ddj.rules`. |
| "The HCD patch is exonerated" | `docs/investigation/STATE.md` phase 21 item 8 | Correct **as a wedge cause**. It is not exonerated as a source of wrong answers: 0x220410 and 0x220414 return `STATUS_NOT_SUPPORTED`, `ConnectionStatus` is fabricated, and the walk has no unconditional positive log. |
| Patch 0006's upstream rationale | `upstream/patches/0006:37-46` | Asserts rekordbox "never reaches index 2", which `T05:265-278` explicitly retracted, and phase 22 disproves outright. The `SUBS_*` half is technically correct — re-justify it on the PipeWire-port grounds alone before submitting. |

### Patches shipped without a control

- **0006** measured against a system with `snd_seq_dummy` manually removed and no blacklist — not reproducible on a default Arch install, and an AUR run-and-play script cannot ship an `rmmod`.
- **0008** changed `GetMixFormat` for every endpoint and left stream *creation* on `plughw:`, so `IsFormatSupported` and `Initialize` now disagree; it also widened an unbounded channel-map write into previously-safe paths. No A/B on the internal card was recorded.
- **0002 vs 0010** are mutually exclusive edits to the same three lines; the AUR build script builds 0002 and the marker guard cannot tell the difference.
- **0004** was shipped as a documentation-only file that is not a patch, and its content was duplicated into 0006 and again into 0007.

### Instrumentation that could not fire

- `ERR`/`TRACE` from `rec_thread_proc` and its callees (raw pthread, no TEB) — found and fixed with `rbw_raw`. Excellent catch, and the right generalisation was written down.
- Every `RBW-*` marker is `TRACE`/`WARN`, and the shipping launcher sets `WINEDEBUG=-all`. The on-disk half of the marker rule is met; the runtime half is not, in the one configuration users will run.
- The 64/32-byte probe caps hid the terminating `F7` — the single byte the whole phase-20/21 argument turned on.
- The RBW-RAW inbound hex loop runs *before* its own env gate (`alsamidi.c:1226-1232` vs `:451`), so it is not free when disabled, on the inbound hot path.

### What was done well and must be kept

- **`research/probes/authreplay.py`'s three-arm wedge experiment** is the best piece of work in the repository: one variable, Wine removed from the path entirely, and it converted "the device wedges" from a symptom into a mechanism (`observe` healthy / `reject` healthy / `truncate` dead). It also proved the scope question empirically — a wrong answer is *not* punished.
- **`research/probes/usbwire.sh` + `usbwire.py`** — the first instrument in the project that can distinguish "packed into a URB" from "the device took it", and it gates every run on device health.
- **The wire-check-before-and-after rule**, and the willingness to declare runs VOID. It is the reason the wedge was not mis-attributed a fourth time.
- **The binary-level reconstruction** (`0x1423a5210`, `0x14237c9a0`, `0x142341940`, `0x1422a6500`) is accurate — I re-derived several addresses independently and every quoted instruction was where it was said to be. Reconstructing `@AuthResponseE`'s last two bytes from the binary and then confirming them at the wire a phase later is exemplary.
- **The retraction culture.** `JOURNAL` 14:41 retracts a headline finding in its own words; `T05:265-278` retracts the index-order reading; the Tx-counter comment was corrected in place. Keep doing this — my §1.6 finding is only possible because the evidence trail was honest enough to contradict itself.
- **`bin/rbclean.sh`** (scoped by `WINEPREFIX` from `/proc/<pid>/environ`, verifies zero survivors) and **`research/probes/damagefps.c`** (calibrated against glxgears and cross-checked in-process) are both instruments built the right way.

---

## 6. THE EVIDENCE PLAN

**Standing gates for every run below.**
- Wire check **before and after**: `research/probes/usbwire.sh check` (0xFE Active Sensing via `amidi -p hw:1,0,0 -S FE`, `research/probes/usbwire.sh:58-78`), Tx must advance at both ends. Either check failing ⇒ the run is **VOID**, not evidence.
- **Strengthen the gate** (do this first, it is 10 minutes): the 0xFE check passes on a device that no longer initiates `@AuthReq` — measured today. Add a liveness arm: `research/probes/authreplay.py --observe --secs 12` must see an inbound `@AuthReq`; if it does not, the device is in the half-degraded state and every run is VOID until a power cycle.
- **≥3 runs per arm** before any attribution. The fault has been intermittent and the repo has already retracted three single-run attributions (`JOURNAL` 14:30).
- Record the child's environment: `tr '\0' '\n' < /proc/<pid>/environ > $dir/env.txt`. Non-negotiable after §1.6.
- Nothing below is run while a sibling session holds the device (`pgrep -a rekordbox` must be empty).

### No human at the hardware

**N0 — Fix the harness and prove the environment.** *Variable:* none (a repair).
`research/probes/authprobe.sh:35` → `RENAME=`; or `:72` → `${RENAME:+…}` guarded by `[ "$RENAME" = 1 ]`. Add the `/proc/<pid>/environ` dump. `grep -rn ':+' bin/*.sh` and audit every other conditional expansion.
*Outcome:* none — it is the precondition for everything else. **10 min.**

**N1 — Re-run the "plain launch" arm with the rename actually off.** *Variable:* `RBW_MIDI_RENAME` present vs absent.
```
research/probes/usbwire.sh check
for i in 1 2 3; do research/probes/authprobe.sh --secs 120 --label norename --runs 1; done   # after N0
RENAME=1-equivalent arm: research/probes/authprobe.sh --secs 120 --label rename --runs 3     # with --rename
research/probes/usbwire.sh check
grep -c 'len=12' runs/AUTH/*norename*/wine.log runs/AUTH/*rename*/wine.log
```
*Expected:* `norename` arm shows `@Activate` in 3/3; `rename` arm shows none in 3/3.
*Kills:* the startup-race hypothesis (H1 confirmed) — or, if `norename` still shows no `@Activate`, H1 is wrong and the race is real, which would be the most valuable negative result available. **20 min.**

**N2 — Device liveness without Wine.** *Variable:* none (measurement of device state).
`research/probes/authreplay.py --observe --secs 30` (sends only `@Activate`; the arm proven healthy for 25 s in phase 21, never sends the final message).
*Expected:* `@AuthReq` inbound within ~10 s ⇒ the device is fine and H2 dies; **no** `@AuthReq` ⇒ H2 stands and every run since 16:33 is VOID.
*Kills:* H2, and it re-validates or invalidates the last nine runs in one shot. **10 min.**

**N3 — Time-to-`@AuthReq` versus rekordbox's 8 s deadline.** *Variable:* observation window only (45 s → 120 s), `WINEDEBUG=+timestamp` (proven non-flipping in combination with `+wineusb`, 2/2).
Measure, per run: `midi_in_open` timestamp, first inbound timestamp, keep-alive count per open cycle, number of `recthread CANCELLED`.
*Expected:* if every cycle is exactly 40 keep-alives and inbound never arrives, the 8 s teardown is the proximate cause and the target becomes "reduce time-to-MIDI-open" or "make the device answer".
*Kills:* H3. **25 min, 3 runs per arm.**

**N4 — Enumeration census.** *Variable:* an unconditional one-line `ERR` at the end of `alsa_midi_init` printing `num_dests`, `num_srcs` and every `szPname` (marker `RBW-ENUM2`).
*Expected:* identical single-device lists across 3 runs ⇒ H5 dies. Any run-to-run variation is the first direct evidence for it.
*Kills:* H5 and H7. **30 min including rebuild; verify with `strings … | grep RBW-ENUM2`.**

**N5 — Audio-probe isolation.** *Variable:* `RBW_ALSA_SKIP_CARDS=1` env-gated skip in `alsa_get_endpoint_ids`'s `snd_card_next` loop, marker `RBW-NOAUDIO`.
*Expected:* count of `-110` triples per launch drops to 0; time-to-`midi_in_open` drops materially. If the native path also becomes reliable, H4 is promoted from contributor to cause.
*Kills:* H4. Note the other levers do not work: `~/.asoundrc` is never consulted (winealsa uses `snd_card_next`/`snd_ctl_open("hw:%u")`); `Drivers\Audio=pulse` also moves MIDI to `winepulse.drv`, which has none; `snd-usb-audio enable=0` and unbinding `3-9:1.0` both take the ALSA card and the rawmidi port with it. **45 min, 3 runs per arm.**

**N6 — Correctness fixes that are prerequisites, not cures.** *Variable:* one per build, each with its own marker.
(a) check `snd_seq_event_output_direct`'s return at `alsamidi.c:1110` and `:1014`, `ERR("RBW-TXFAIL …")`, return `MIDIERR_NOTREADY`, do **not** set `MHDR_DONE`; (b) raise both probe caps to 256 and mark IN truncation; (c) clamp `dwBufferLength == 0` before `data[len-1]`; (d) clear `hMidi` and `seq_close()` on the `midi_in_open`/`midi_out_open` failure paths; (e) `min(fmt->nChannels, 32)` in `map_channels_for_share`; (f) implement 0x220410 string descriptors from sysfs `serial`.
*Expected:* (a) correlates `RBW-TXFAIL` with dmesg overruns, or proves the kernel swallows it. Each is independently publishable upstream. **90 min total; write (a) up explicitly as a prerequisite.**

**N7 — Make the repository able to rebuild itself.** *Variable:* patch provenance.
Extract pristine `wine-11.15`, `git init`, commit, copy the ten modified files from `~/.cache/rbw-wine-build/wine-11.15`, `git format-patch` per logical change, regenerate 0002/0003/0004, add patches for `RBW-RENAME`, `RBW-WIRE`/`RBW-RAW`, `RBW-EVENT3`, `RBW-WD`, `RBW-PAD`, `RBW-VBLANK2`, `RBW-PAINT`. Validate with `git apply --check` in order onto a fresh extract; gate it in a `bin/` script.
*Success criterion:* the rebuilt `winealsa.so` matches md5 `a53f6afa2765e75dae4b0e7ce446c56f`, or the residual delta names exactly what is still untracked. **45-90 min. This is the AUR deliverable's blocker and it is not optional.**

**N8 — Fix the packaging path.** `build-patched-dlls.sh:36` → 0010; make the skip test exact rather than a prefix match; add `winealsa`/`winmm` to the build map and `artifacts/winedll/` to `PKGBUILD`; drop `WINEDEBUG=-all` from `bin/rekordbox-wine:333` in favour of `+err,+fixme` at minimum; add a Wine-version guard to `install-system-wine-patches.sh`; plant a marker in the winmm half of 0007. **60 min.**

### Needs the human at the hardware

**H-1 — Power cycle, then three unperturbed native runs.** *Variable:* device power state.
Unplug 5 s, replug, verify the three-message probe burst then silence, `research/probes/usbwire.sh check`, then 3 × 120 s plain launches with `+timestamp`, wire-captured from t=0.
*Expected:* `@AuthReq` in 3/3 and (if H1 is right) `@AuthEnd` in 3/3 ⇒ **the controller works reproducibly and Gate 1 for the DDJ is passed.** `@AuthReq` in 0/3 ⇒ H2 dies and H4/H5 move up. **20 min.**

**H-2 — Reproduce phase 22 without a debugger.** *Variable:* gdb attached vs not, everything else identical, 3 runs per arm, power cycle between arms.
*Expected:* equal outcomes ⇒ the observer effect was the harness (H1) and the phase-22 tables can be rewritten.

**H-3 — Acceptance test.** After a reproducible `@AuthEnd`: jog wheels, faders, pads, LEDs, and a real performance session with the user at the controller. This is the mission's definition of done, not an afterthought — and it is the first time it will have been reachable.

**Do not do:** `USBDEVFS_RESET` on this VID:PID (measured: hangs a root process in D state ~90 s inside `usb_reset_device`, then destroys the device node and the kernel's own power-cycle fails to re-enumerate); `authorized` 0→1 on a wedged device (measured: `can't set config #1, error -110`, no re-enumeration, recovery only by physical replug). Add both as refusals in `research/probes/usbreset.sh`. Also document that `dumpcap` on usbmon is **not passive** — it issues real `GET_DESCRIPTOR` control transfers at capture start (`usbfs: USBDEVFS_CONTROL failed cmd dumpcap rqt 128 rq 6 len 18 ret -110`).

---

## 7. SCOPE CHECK

**Nothing here has resolved into licence or protection enforcement, and the evidence for that is now positive rather than absent.**

- The `@Auth` exchange's only inputs are the device's own `@AuthResponseA` (SeedE, model string) plus two compile-time constants. The transform is `FNV-1a-32(SeedE ‖ (SeedE XOR 68 01 31 FB))` and a hard-coded 10-byte per-model key selected by the string **the device itself transmitted**. There are **zero import calls** in the seven functions of the call graph — no `clatc.dll`, no `lsapiw64.dll`, no bcrypt, no libcrypto. No machine GUID, volume serial, MAC address, registry value, USB descriptor field or serial number participates. The eleven copies of `wmic csproduct get uuid` in the image are COMDAT duplicates; nine are unreferenced and the two live ones are in unrelated call graphs. [MEASURED]
- The device does **not** punish a wrong answer: `authreplay.py`'s `reject` arm sent a well-formed 66-byte message with a knowingly wrong payload and the device stayed healthy and retried. Only broken framing kills it. This is hardware presence-checking, not licence enforcement. [MEASURED]
- Tag 03 of `@AuthResponseA` is a fresh per-session nonce, so a captured response cannot be replayed to authenticate anything. [MEASURED]

**Where each experiment sits:**

| experiment | side of the line |
|---|---|
| N0-N1 (harness rename fix), N3-N5 (timing, enumeration, audio isolation), N7-N8 (reproducibility, packaging) | **In scope.** Host-side configuration and instrumentation; no device protocol is touched. |
| N2 / `authreplay.py --observe` | **In scope.** Sends only `@Activate` — the same keep-alive rekordbox sends — and *observes* the device's own `@AuthReq`. It never sends a response of any kind. |
| N6 (transport correctness: checked return values, un-truncated probes, bounds fixes, string descriptors) | **In scope.** This is the definition of transporting the user's bytes faithfully. |
| H-1 to H-3 (power cycle, unperturbed runs, acceptance test) | **In scope.** Running the licensed application the user installed against hardware the user owns. |
| **Not proposed, and explicitly out of scope** | Computing an `@AuthResponseE` that the device will accept and sending it from anything other than rekordbox itself. The algorithm is now fully decoded, which makes this *possible* — and that is exactly why it must be stated as a boundary rather than left implicit. `research/probes/authreplay.py` must keep its final-message arms restricted to *knowingly wrong* and *deliberately malformed* payloads, whose purpose is characterising the transport, never authenticating. If a future session finds that the only route to a working controller is to originate a valid proof outside rekordbox, that is **NO-GO, hard wall**, and the project stops there. |

Nothing measured to date requires going near that line. The one run that completed the handshake did so with rekordbox computing its own response, over Wine's own transport, to the user's own hardware — which is precisely the outcome this project exists to produce.