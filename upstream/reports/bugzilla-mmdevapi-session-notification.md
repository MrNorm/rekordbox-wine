# mmdevapi: RegisterAudioSessionNotification is a stub that reports success

**Status:** draft, NOT filed. Needs a WineHQ Bugzilla account.
**Component:** `mmdevapi` (`dlls/mmdevapi/session.c`)
**Version:** observed on wine-11.15 (Staging); the code is long-standing.

## Summary

`IAudioSessionControl::RegisterAudioSessionNotification` returns `S_OK` and
never delivers a single callback. A client that registers and waits is told the
registration succeeded and then waits forever.

## Why this is worse than returning an error

An unimplemented function that **fails** is something a caller can handle: the
documented contract lets an application fall back to polling
`IAudioSessionControl::GetState`. An unimplemented function that **claims to
have succeeded** removes that option, because the application has no way to
learn it is never going to be called back.

rekordbox 7.2.18 registers on both of its audio clients and never polls
`GetState` afterwards — a reasonable thing to do against the documented
behaviour, and it means the application cannot observe session state changes at
all under Wine.

The same reasoning appears in Wine's own guidelines: a stub that lies about
success is a bug in a way that an honest `E_NOTIMPL` is not.

## Affected functions

| function | current behaviour |
|---|---|
| `RegisterAudioSessionNotification` | `FIXME` + returns `S_OK`, stores nothing |
| `UnregisterAudioSessionNotification` | `FIXME` + returns `S_OK` |
| `RegisterDuckNotification` | same shape |

## Suggested fix

Either:

1. **Honest refusal** — return `E_NOTIMPL` (or `AUDCLNT_E_NOT_INITIALIZED` where
   appropriate) so that callers with a documented fallback can take it. This is
   a one-line change and strictly improves on the current behaviour.
2. **Implement it** — hold the `IAudioSessionEvents *` on the session and call
   `OnStateChanged` from the existing `client_Start` / `client_Stop` /
   `client_Reset` paths, and `OnSimpleVolumeChanged` from the volume setters.
   The session object already exists and already has the lifetime needed.

## Reproduction

An experiment carrying all three arms from one binary exists in this project's
working tree (`RBW-SESSION`, selected by `RBW_SESSION_NOTIFY=fail|impl`); it is
diagnostic scaffolding rather than a submittable patch and is deliberately not
shipped. A minimal reproducer for the bug report is a program that calls
`RegisterAudioSessionNotification`, starts and stops a stream, and observes that
`OnStateChanged` is never invoked while the call reported `S_OK`.

## Impact assessment, stated honestly

**Not measured.** rekordbox works under Wine today with this stub in place, so
nothing in this project is currently known to be broken *by* it. It is reported
because a lying stub is a defect regardless of whether it happens to bite here,
and because the next application to rely on the callback will lose a day to it.
