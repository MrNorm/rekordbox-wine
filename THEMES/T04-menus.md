# T04 — The File menu never opens

**Status:** OPEN, and substantially re-scoped 2026-08-19 — it is **not** a menu-bar
bug and the menu is **not** empty. Read the 2026-08-19 section first; the
"leading hypothesis" further down is refuted. · **Opened:** 2026-08-13

## Symptom

Reported by hand: *"'file' and 'help' menu items continue to not load correctly,
but 'view' and 'playlist' seem fine. Could be a clue."*

It is a clue, and it points away from the bug we already fixed.

## Measurement

`bin/menuprobe.sh`, 5 passes, clicking each top-level menu with a full state
reset between attempts (pointer moved off the bar, Escape twice, settle). Scored
by whether a window named `menu` appears, not by pixels — a JUCE popup is a real
top-level window, so its existence is a fact rather than a judgement.

| menu | opened | 
|---|---|
| File | **0/5** |
| View | 5/5 |
| Track | 5/5 |
| Playlist | 5/5 |
| Help | 4/5 — the only miss was the first attempt after launch |

So the reported "File and Help" is really **File, hard and reproducible**, with
Help working once it has warmed up. Worth telling the user, since it changes
what to look at.

## It is not the T01 repaint bug

Clicking File produces **nothing at all**:

- no new X window, mapped **or unmapped** (checked with `xdotool search` without
  `--onlyvisible`; a File click adds 0 windows, a View click adds 5 — the popup
  plus its four JUCE drop-shadow helpers)
- RMSE 0 across the full screen
- no new lines in the Wine log

A repaint failure would still create a window and map it. This is upstream of
window creation, so the patched dxgi is irrelevant here.

## Ruled out

- **Our own aim.** The click coordinates were verified against the pixels: the
  menu-bar labels sit at client x = 24 (File), 72 (View), 129 (Track),
  191 (Playlist), 251 (Help), y = 12, measured off a 300%-magnified crop. The
  popup x-origins of the menus that *do* work (46, 100, 158) are consistent with
  item rects of File 0–46, View 46–100, Track 100–158, so x=24 is inside File's
  rect with room to spare.
- **The COM registration errors in the log**
  (`class {aa509086-5ca9-4c25-8f95-589d3c07b48a} not registered`, ×12). They do
  not move when File is clicked: 12 before three clicks, 12 after. Startup-time
  and unrelated.

## Not yet distinguishing

- **Keyboard route unavailable.** `Alt+F`, `Alt+V`, `Alt+H` all do nothing —
  including for menus that open fine on click — so mnemonics are not wired up in
  this build and cannot be used as a second channel. Arrow-key walking from an
  open menu closes it rather than moving along the bar.

## Leading hypothesis

**The File menu is constructed empty.** JUCE shows no window for an empty
`PopupMenu`, which reproduces every observation exactly: click accepted, no
window, no log activity, no cost. Something rekordbox conditionally populates it
with is evaluating to nothing under Wine.

That predicts the menu is empty for a reason we can find — a missing shell
integration, a device enumeration, or a capability query returning empty. It
also predicts the fault is per-item, so **Help failing once at startup and never
again** fits: whatever it queries had not yet resolved.

## Next test

Trace the click, not the app. `WINEDEBUG=+relay` scoped to a single File click
is too heavy, but `+file,+reg` around one click is cheap and would show whether
rekordbox goes looking for something — a path, a registry key, a device list —
in the instant before deciding the menu is empty. Compare against the same trace
for a View click, which is the natural control.

## Impact

Cosmetic-to-annoying rather than blocking, **provided** nothing important is
File-only. Preferences is reachable from the gear icon and Export from the
top-left control, so the application is usable. Confirm before downgrading the
priority: if "Export Collection in xml" or the library backup lives only under
File, this is on the path to Gold after all.

---

# 2026-08-19 — re-scoped, and the old hypothesis refuted

Re-opened with the instruments T10 developed: LBR call graphs
(`perf --call-graph lbr`, which needs no unwind information) and hardware
execute breakpoints (`perf -e mem:<code addr>:x`, which count how often an
instruction runs). Everything below is a count, not an inference.

## 1. It is not the File menu. It is a class of popups

`bin/popupcensus.sh`, three passes each, with a deliberate slow reset between
attempts — **sequencing is the trap**: once a JUCE menu bar is active, moving
along it switches menus without creating anything, so a probe that follows
another too closely reports a working menu as dead. That is why an earlier run
this session scored View 0/3.

    menu bar: File                     0/3      <-- dead
    menu bar: View                     3/3
    menu bar: Track                    3/3
    menu bar: Playlist                 3/3
    menu bar: Help                     3/3      (T04 recorded 4/5; now reliable)
    toolbar: PERFORMANCE mode selector 0/3      <-- dead, NEW
    deck 1: INT source                 2/3
    deck 1: HOT CUE                    3/3
    track list: right-click a row      3/3

**The view-mode selector is dead in exactly the same way as the File menu**, and
nobody had looked outside the menu bar. That matters well beyond tidiness: the
top-left selector is the only route to **EXPORT mode**, which is where USB export
lives. So T02 is very likely blocked by *this* bug and not only by the absence of
a stick. (Setting `AppMode` in `rekordbox3.settings` to 0 does not switch mode —
tried, no change.)

## 2. The menu is NOT constructed empty — the old leading hypothesis is dead

`FUN_14173b390` (10,312 bytes) is `MenuBarModel::getMenuForIndex`. It is one
function with a block per menu index, called virtually from `0x142a89647` in
JUCE's `MenuBarComponent::showMenu`. Profiling **sliced to the click windows**
(clicks stamped on `CLOCK_MONOTONIC`, `perf record -k CLOCK_MONOTONIC`; without
that slicing the click path is one part in ten thousand of a busy profile) shows:

    FILE click  -> executes 0x14173b5da .. 0x14173baab
    VIEW click  -> executes 0x14173bb26 .. 0x14173c217

Each block is a run of `call 0x142a86ef0` — JUCE's
`PopupMenu::addCommandItem(ApplicationCommandManager*, CommandID, String, icon)`.
That function silently adds **nothing** when the command is not registered, which
was the obvious way to get an empty menu. It is not what happens. Execute
breakpoints inside it, 8 clicks each:

    0x142a86f52  the command list is non-empty      file 128   view 144
    0x142a86f70  searched, command NOT found        file   0   view   0
    0x142a86f75  command FOUND, item added          file 128   view 144

**Sixteen File items are found and added on every click.**

## 3. JUCE builds, positions and shows the popup — at 228x270

`PopupMenu::showWithOptionalCallback` is `0x142a85350`; it calls `createWindow`
at `0x142a853b4` and bails at `0x142a85451` when that returns null. Execute
breakpoints: the "window created" path `0x142a853c8` is taken **8 times out of 8
for File**, exactly as for View.

`WINEDEBUG=+win` then shows the two popups being placed identically in shape:

    FILE:  NtUserSetWindowPos hwnd 0x20016a ...  1,50 (228x270)  flags 0x216
           show_window hwnd=0x20016a, cmd=8, was_visible 0
    VIEW:  NtUserSetWindowPos hwnd 0x1f015c ... 46,50 (239x495)  flags 0x216
           show_window hwnd=0x1f015c, cmd=8, was_visible 0

A popup 270 px tall is a populated menu. Wine creates the same **35 windows per
click** in both arms, and `WINEDEBUG=+x11drv` shows the same function mix
(`X11DRV_create_win_data` 7x, `destroy_whole_window` 12x, `window_set_wm_state`
10x …) for both.

## 4. And yet the File popup never reaches the X server

Sampling the X root's children at 25 Hz for two seconds after the click:

    FILE click  new X windows: 0 0 0 0 0 0 0 ... 0     (never, not even transiently)
    VIEW click  new X windows: 5 5 5 5 5 5 5 ... 5

`xwininfo -root -tree` says what those five are — the menu plus JUCE's four
drop-shadow strips:

    0x1a0006a "menu"      239x495+46+50
    0x1a00064 (no name)   239x14 +46+36     top shadow
    0x1a00062 (no name)   239x14 +46+545    bottom shadow
    0x1a00066 (no name)    14x523+285+36    right shadow
    0x1a00068 (no name)    14x523 +32+36    LEFT shadow, at x = 46 - 14

## 5. Refuted the same day: the negative-x drop shadow

Every popup that works opens at x >= 32; both dead ones would open at x = 0..1,
putting that left shadow at **x = -13**. Sharp, and wrong.
`upstream/popupxy.c` (new; freestanding, built by the `build-probes.sh` recipe)
creates the exact four shapes — the menu at (1,50) 228x270, a shadow at
(-13,36) 14x300, and the working pair at x=46/x=32 — with the same styles
(`WS_POPUP | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE`, `SW_SHOWNA`):

    menu-at-x1       : hwnd ok  visible=1  rect 1,50 228x270
    shadow-left-x-13 : hwnd ok  visible=1  rect -13,36 14x300
    menu-at-x46      : hwnd ok  visible=1  rect 46,400 239x200
    shadow-left-x32  : hwnd ok  visible=1  rect 32,386 14x230

    xwininfo: 0x2e00003 (has no name) 14x300+-13+36     <-- the negative one is there

**All four get X windows and all four are visible.** Wine maps popups at
negative coordinates perfectly well. That hypothesis is dead.

## Where this leaves it

The popup is built with items, sized, positioned, shown with `SW_SHOWNA`, and
torn down again without ever being mapped — and Wine's own window layer does the
same work it does for the menu that succeeds. Two candidates remain:

1. **Something dismisses the modal immediately.** JUCE popups die on a mouse
   event outside their bounds or on `dismissAllActiveMenus()`. The instrument is
   an execute breakpoint on JUCE's dismissal path, counted per arm.
2. **`create_whole_window` declines for these particular windows.** The counts
   above are aggregates over a whole click; the next capture should follow **one
   popup hwnd** from `X11DRV_create_win_data` to `destroy_whole_window` and read
   the reason.

Nothing here is cosmetic any more: the same bug takes out the view-mode
selector, and with it the route to EXPORT mode.

---

# 2026-08-19, later — SOLVED. It is a Wine bug, in `is_window_managed()`

## The mechanism, end to end, every step measured

1. rekordbox's File menu is built correctly and **populated** — 16 command items,
   popup sized **228x270** (section 2 above).
2. JUCE surrounds every popup with four drop-shadow windows. For a menu opening
   at x = 1, the **left shadow is placed at x = -13**.
3. JUCE's popup style is **`0x86080000`**, which contains **`WS_SYSMENU`
   (0x00080000)**. `winex11.drv`'s `is_window_managed()` says:

        if (style & WS_POPUP)
        {
            /* popup with sysmenu == caption are managed */
            if (style & WS_SYSMENU) return TRUE;

   so Wine hands the popup **and its shadows to the window manager**.
4. KWin then enforces its keep-on-screen policy and **moves the shadow from
   x = -13 to x = 0**. Wine reports it back: `handle_state_change window
   0x1e0162/1a00035 WM_NORMAL_HINTS { pos 0,36 ... }`.
5. Immediately after that, JUCE hit-tests the pointer, finds it over the main
   window rather than the menu, and **dismisses the entire menu 11 ms after it
   was mapped**:

        FILE  map at +0.019 s  ->  hide at +0.030 s     (11 ms)
        VIEW  map at +0.014 s  ->  hide at +2.102 s     (my Escape)

## Two controlled experiments that nail it

**`upstream/popupxy.c`** builds the exact shapes JUCE builds and reports where
each one ends up after settling:

    shadow-left-x-13   WS_POPUP, TOOLWINDOW|NOACTIVATE            -13,36  ->  -13,36   stays
    LAYERED shadow-x-13  + WS_EX_LAYERED                          -13,586 ->  -13,586  stays
    SYSMENU shadow-x-13  + WS_SYSMENU  (JUCE's actual style)      -13,800 ->    0,800  MOVED
    SYSMENU shadow-x32   + WS_SYSMENU, on-screen                   32,800 ->   32,800  stays

**Only the window carrying `WS_SYSMENU` is moved**, and only when it is
off-screen. That is `is_window_managed()` handing it to KWin.

**The positional sweep** — move rekordbox's window and click File:

    window x   File menu   the left shadow would be at
        0        0/2          x = -13
        4        0/2          x =  -9
        8        0/2          x =  -5
       12        0/2          x =  -1
       14        1/2          x =  +1     <-- transition
       16        1/2          x =  +3
       24        1/2          x = +11
       60        1/2          x = +47

The cliff is exactly at the 14-pixel shadow width. With the window at x = 400
both dead popups come alive, 3/3 each, and X shows them properly:

    "menu" 228x270+400+50   shadows +400+320, +400+36, +628+36, and +386+36

So: **rekordbox maximized at x = 0 permanently loses its File menu and its
view-mode selector**, because their left drop shadow falls off the left edge of
the screen. Move the window 14 px right and both work. That is why View, Track,
Playlist and Help were always fine — they open far enough right that their
shadow stays on-screen.

## The Wine defect, stated for upstream

`dlls/winex11.drv/window.c`, `is_window_managed()` treats any `WS_POPUP` with
`WS_SYSMENU` as a window the window manager should own. Menus, tooltips and drop
shadows are not application windows on Windows and are never WM-managed there;
handing them over lets the WM reposition them, and a toolkit that positions its
own chrome relative to a popup then sees its geometry change underneath it.

Wine already knows these windows are chrome — `get_mwm_decorations_for_style()`
returns 0 immediately for `WS_EX_TOOLWINDOW` and for `WS_EX_LAYERED`. The same
test belongs in `is_window_managed()`.

## What this unblocks

The view-mode selector is the only route to **EXPORT mode**, so T02's USB export
has been unreachable for the same reason. Fixing this fixes both.
