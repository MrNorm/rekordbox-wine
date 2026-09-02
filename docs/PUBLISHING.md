# What has actually been published, and what has not

**Status: 2026-09-02. Honest answer — the GitHub repository is the only thing
published. Every upstream and AppDB report is written and none is filed.**

This document exists because "we documented it" and "the world can find it" are
different claims, and this project had been quietly making the first while
sounding like the second.

## Published, and reachable by a user who has never met this repository

| where | what it says | current? |
|---|---|---|
| `README.md` | install, what works, what does not, what a Wine upgrade costs, what a rekordbox update costs | yes — rewritten 2026-09-02 |
| `docs/GOLD-STATUS.md` | capability-by-capability verdict, every row a measurement | yes, but see its version caveat |
| GitHub **Releases** | installable package, Wine version in every asset name | v0.2.1, wine 11.16 |
| GitHub **Actions** | daily build against Arch's current Wine; the failing patch is named in the log | live |
| `upstream/patches/*.patch` | the Wine fixes themselves, in the repo and in the package under `/usr/share/doc/rekordbox-wine/patches` | yes |

That is genuinely useful to somebody who finds the repository. It is invisible
to everybody who does not — which, for a Linux DJ searching "rekordbox linux",
is almost everybody.

## Written, NOT published — and each is a deliverable

These are complete drafts sitting in `upstream/reports/`. Every one needs a
human with an account; none can be automated, and two are actively blocked from
automation by design.

| draft | needs | why it matters |
|---|---|---|
| `bugzilla-dxgi-waitforvblank.md` | WineHQ Bugzilla account; **a manual duplicate search** (bugs.winehq.org is behind Anubis and refuses automated fetches — try `WaitForVBlank`, `dxgi vblank`, `JUCE repaint`, `IDXGIOutput`); a decision on also sending the patch to wine-devel | `IDXGIOutput::WaitForVBlank` is an `E_NOTIMPL` stub. This is the fix without which **no JUCE 8 application paints a second frame**. It is the single most valuable thing this project found, it is reproducible with `upstream/vblanktest.c` — no GUI, no toolkit, no proprietary software — and it is the one CLAUDE.md names as a deliverable in its own right. |
| `bugzilla-mmdevapi-session-notification.md` | WineHQ Bugzilla account | Wine returns a lying `S_OK` from an unimplemented session-notification path. |
| `bugzilla-winealsa-sysex-split.md` | WineHQ Bugzilla account | winealsa splits SysEx across USB transfers. **0 successful DDJ-400 handshakes** without the fix, and it can leave USB MIDI hardware unusable until physically power-cycled. |
| `wireplumber-alsa-node-error-handler.md` | a WirePlumber issue tracker account | WirePlumber 0.5.15's ALSA error handler crashes on its own error message, deleting a device from PipeWire for the rest of the session. Reproduced **Wine-free**, so it is not our bug to carry. |
| `appdb-rekordbox-7217.md` | a logged-in AppDB account | Two submissions: a test report, and **a correction to iId=43369**, whose "accepts no keystrokes" diagnosis this project disproved. Until it is filed, AppDB's public record of rekordbox 7.2.x is two "Garbage" reports and nothing else. |

### The AppDB draft is now stale in one specific way

It is written for **rekordbox 7.2.17 on wine-staging 11.15**. The project has
since moved to **11.16**, and on 11.16 only "launches and repaints" has been
re-measured. Filing it as-is would be accurate about what it claims and would
describe a stack nobody is running. Either re-measure on 11.16 first, or file it
with the versions it actually names and add a second report later. Do not
silently retarget the version numbers on a report whose measurements were made
elsewhere.

## Why none of this is automated

Filing is deliberately a human act here:

- **Bugzilla** sits behind Anubis specifically to stop automated submissions.
- **AppDB** needs a logged-in account and a human judgement about rating.
- Both put a **name** against a claim. This project's rule is that every claim
  cites a run id; a report filed by a harness has nobody standing behind it.

The drafts are the part that can be prepared without an account, and they are
done. What remains is an account and about an hour.

## The one axis CI cannot cover

`.github/workflows/` watches Wine, because Arch publishes Wine versions in a
JSON API and the package can be built in a container. **It cannot watch
rekordbox**: proprietary, a 660 MB installer behind a JavaScript download page,
and sign-in needs a real AlphaTheta account. So the rekordbox axis is measured
by a human and recorded in `upstream/supported-rekordbox.txt`, and the launcher
warns rather than refuses on a version that is not in it.

If that file is ever out of date, the failure mode is a warning a user can act
on, not a broken install — which is the right way round.
