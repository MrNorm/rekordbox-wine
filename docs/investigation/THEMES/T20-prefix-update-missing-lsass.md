# T20 — A prefix updated to Wine 11.18 has a SamSs service and no lsass.exe

**Status:** FIXED in the launcher (2026-10-17); upstream root cause open · **Opened:** 2026-10-17

## Symptom
First launch of rekordbox on the vendored runtime (T19), probe prefix
`prefixes/rb7-runtime-probe` (a reflink copy of rb7), `WINEDEBUG=err+all`:

    err:secur32:start_samss Failed to start SamSs service          (x6)
    err:secur32:load_auth_packages Failed to get security packages list   (x6)

Neither line appears in any of the 34 logs under runs/. Those all ran on
11.15/11.16, before lsass existed, so they are not a baseline for this.

## Evidence
- `programs/lsass` exists in the 11.18 source and not in 11.15 or 11.16.
- The SamSs service key (`ImagePath = C:\windows\system32\lsass.exe`) is in
  rb7's system.reg. **rb7's system32 has no lsass.exe.** rb7 was last updated by
  the system wine-staging 11.18 (`.update-timestamp` = wine.inf mtime 2026-09-22).
  So the problem predates the runtime: the user's working prefix has had it since
  the 11.18 upgrade.
- Fresh prefix, runtime, `wineboot -i`: lsass.exe IS created (98 exes).
- A reflink copy of rb7, runtime, an uninterrupted `wineboot -u`, then
  `wineserver -w`: the stamp updates and lsass.exe is **not** created.
  Hypothesis "our launcher killed the update half-way" is refuted. Wine's update
  path registers the new service but does not place the new program.

## Hypotheses
| # | Hypothesis | Status |
|---|---|---|
| 1 | The launcher's rbclean interrupted wineboot | refuted (uninterrupted update, same result) |
| 2 | setupapi's fake-dll install skips programs on update that a fresh install places | open; read dlls/setupapi/fakedll.c install_lib_dir |
| 3 | The missing LSA explains the "Free" badge | refuted: badge identical with lsass present (20261017T1446) |

## Evidence log
| Date | Run | Change | Verdict | Moves |
|---|---|---|---|---|
| 2026-10-17 | probe launch 1 (runtime, rb7 copy) | runtime | window-ok; SamSs errors x6 | found |
| 2026-10-17 | rb7-update-probe `wineboot -u` | none | no lsass.exe | H1 refuted |
| 2026-10-17 | 20261017T1446-runtime-rb7copy-lsass | lsass.exe copied in | SamSs + auth-package errors 6 → 0 | cause confirmed |

## Fix
The launcher reads every service `ImagePath` under system32 from system.reg and
restores any missing program from the runtime (only service programs: a fresh
prefix keeps powershell, regedit and the rest elsewhere, so a blanket copy into
system32 would be wrong). `--check` reports it as FAIL. Verified on
rb7-update-probe: FAIL, then `--setup` restores it, then ok.

## Upstream
- [ ] Wine bug: `wineboot -u` on a pre-11.17 prefix registers SamSs without
  placing lsass.exe. Find the skip in dlls/setupapi/fakedll.c, then file it.
