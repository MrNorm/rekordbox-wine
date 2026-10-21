# T15 — PRO DJ LINK to an XDJ-XZ over the router LAN

**Status:** VERIFIED (run 20260912) · **Opened:** 2026-09-12 · **Closed:** 2026-09-12

The XDJ-XZ also speaks rekordbox's **PRO DJ LINK**: it streams the library and
tracks from the computer over the network. This is the *network* result on the
same player T02 used for USB export — T02 is "the stick was read", T15 is "the
computer's library was streamed". The answer: yes, rekordbox under Wine streams
to a real Pioneer player over a home LAN.

## Topology

Both machines on the router's `192.168.0.0/24`, plain DHCP, no static IPs:

| side | interface | address | role |
|---|---|---|---|
| PC (rekordbox, Fedora) | `eno1` | `192.168.0.174/24` | source |
| XDJ-XZ | (LAN port, via router) | `192.168.0.164` | player |

## The firewall rule

firewalld was active with `eno1` in the `public` zone, which drops inbound by
default. With PRO DJ LINK the **player** initiates the connection to the
computer, so the computer has to accept it. Applied and verified working:

    firewall-cmd --zone=public --add-rich-rule='rule family="ipv4" source address="192.168.0.0/24" accept' --permanent
    firewall-cmd --reload

Scoping the rule to the LAN subnet, rather than to any source, is the
load-bearing part. It accepts **all** protocols and ports from that subnet, which
is more than the link needs; the narrower rule limited to the PRO DJ LINK ports
is untested here, so it is not offered as the verified configuration.

## Evidence

`runs/T15-prodjlink-xz-20260912.jpg` — the player in **LINK** mode: the header reads
the computer's hostname, **`fedora`**, the browse tree is the computer's rekordbox
library, and a track is playing on deck 1. The player is pulling the library over
the network, not from a stick.

## The dual-path trap

The XDJ-XZ's USB port is a **CDC-ECM USB-LAN bridge** (Pioneer `2b73:0007`).
Cabled to the PC it acts as a transparent forwarder to the player's LAN, so
cabling the PC to that port adds a **second interface on the same `/24`** as the
player's router-side port. Two local interfaces on one subnet, both claiming to
reach `192.168.0.164`, breaks PRO DJ LINK's unicast streaming. The working
configuration: **the player on the router LAN, with its USB port not cabled to
the PC** (no `2b73` device present). Check it in two seconds — `lsusb | grep -i
2b73` empty, and `ip -br addr` showing exactly one interface on
`192.168.0.0/24`. USB cabling does work for the *direct* path (the
`05-usb-lan.sh` experiment), but it cannot coexist with the router path. (T02's
readback was USB-*stick* mode — a mass-storage stick, not the `2b73` bridge.)

## Related themes

- **T02** — the same player, USB-*stick* export and readback. Different path.
- **T05** — the DDJ-400 controller (MIDI/HID). PRO DJ LINK is a network
  relationship to a *player*, not a controller.
