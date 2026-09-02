# What has actually been published, and what has not

**Status 2026-09-02: the GitHub repository is the only thing published. Every
upstream and AppDB report is written and none is filed.**

## Published

| where | what it says | current? |
|---|---|---|
| `README.md` | install, what works, what does not, what a Wine upgrade costs, what a rekordbox update costs | yes — rewritten 2026-09-02 |
| `docs/GOLD-STATUS.md` | capability-by-capability verdict, every row a measurement | yes, but see its version caveat |
| GitHub **Releases** | installable package, Wine version in every asset name | v0.2.1, wine 11.16 |
| GitHub **Actions** | daily build against Arch's current Wine; the failing patch is named in the log | live |
| `upstream/patches/*.patch` | the Wine fixes themselves, in the repo and in the package under `/usr/share/doc/rekordbox-wine/patches` | yes |

Reachable only by someone who finds the repository.

## Written, not filed

Complete drafts in `upstream/reports/`. Each needs an account; none can be
automated.

| draft | needs | why it matters |
|---|---|---|
| `bugzilla-dxgi-waitforvblank.md` | WineHQ Bugzilla account; **a manual duplicate search** (bugs.winehq.org is behind Anubis and refuses automated fetches — try `WaitForVBlank`, `dxgi vblank`, `JUCE repaint`, `IDXGIOutput`); a decision on also sending the patch to wine-devel | `IDXGIOutput::WaitForVBlank` is an `E_NOTIMPL` stub. This is the fix without which **no JUCE 8 application paints a second frame**. It is the single most valuable thing this project found, it is reproducible with `upstream/vblanktest.c` — no GUI, no toolkit, no proprietary software — and it is the one CLAUDE.md names as a deliverable in its own right. |
| `bugzilla-mmdevapi-session-notification.md` | WineHQ Bugzilla account | Wine returns a lying `S_OK` from an unimplemented session-notification path. |
| `bugzilla-winealsa-sysex-split.md` | WineHQ Bugzilla account | winealsa splits SysEx across USB transfers. **0 successful DDJ-400 handshakes** without the fix, and it can leave USB MIDI hardware unusable until physically power-cycled. |
| `wireplumber-alsa-node-error-handler.md` | a WirePlumber issue tracker account | WirePlumber 0.5.15's ALSA error handler crashes on its own error message, deleting a device from PipeWire for the rest of the session. Reproduced **Wine-free**, so it is not our bug to carry. |
| `appdb-rekordbox-7217.md` | a logged-in AppDB account | Two submissions: a test report, and **a correction to iId=43369**, whose "accepts no keystrokes" diagnosis this project disproved. Until it is filed, AppDB's public record of rekordbox 7.2.x is two "Garbage" reports and nothing else. |

### The AppDB draft is stale

Written for **rekordbox 7.2.17 on wine-staging 11.15**. The project is now on
11.16, where only "launches and repaints" has been re-measured. Either re-measure
on 11.16 first, or file it with the versions it names and add a second report.
Do not retarget the version numbers — the measurements behind them were made on
11.15.

## Why filing is not automated

- **Bugzilla** sits behind Anubis, which exists to stop automated submissions.
- **AppDB** needs a logged-in account and a judgement about rating.
- Both put a name against a claim.

The drafts are done. What remains is an account and about an hour.

## What CI cannot cover

CI watches Wine: Arch publishes versions in a JSON API and the package builds in
a container. It cannot watch rekordbox — proprietary, a 660 MB installer behind
a JavaScript download page, sign-in needs a real account. That axis is measured
by hand and recorded in `upstream/supported-rekordbox.txt`; the launcher warns
rather than refuses on an unlisted version, so a stale file costs a warning
rather than a broken install.
