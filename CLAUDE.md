# rekordbox-under-Wine — session protocol

Long-running investigation. Sessions will be cut short by usage limits at
arbitrary points, so **context lives on disk, not in the conversation.**

## The mission — do not renegotiate this

Stated by the user, 2026-08-13. These are standing requirements, not one-off
asks. Read them at the start of every session and treat them as the definition
of done.

1. **Gold-level rekordbox under Wine.** "Gold" in the AppDB sense: installs and
   runs with no workarounds the user has to discover for themselves. Not
   "renders a window", not "plays a file" — the whole application.
2. **Full function and feature.** Library, analysis, USB export, preferences,
   menus, and **real performance use**. A feature that is broken is a theme to
   open, not a caveat to write down and move past.
3. **The DDJ-400 is the test bench.** Hardware performance is the acceptance
   test. If jog wheels, faders, pads and LEDs do not behave as they do on
   Windows, the project is not finished.
4. **Patch Wine.** Bug hunting in Wine source and shipping custom builds is
   expected and encouraged, not a last resort. When Wine is wrong, fix Wine and
   write the patch up for upstream.
5. **Ship it as an AUR package** with a **single run-and-play script**. Someone
   who has never read this repository must be able to install and DJ with it.
   Every finding is recorded with packaging in mind: see `PATH-TO-GOLD.md`.

### Working style the user has asked for, explicitly

- **Do not stop at a milestone to check in.** Keep going until the work is done
  or the tokens are gone. Pauses for approval on work already authorised have
  been called out as unacceptable delay. Ask only when genuinely blocked on
  something only the user can decide or do (credentials, physical hardware,
  a judgement call about scope).
- **Be context tolerant.** Assume this session dies mid-sentence. Write findings
  to disk *as they are found*, not at the end.
- **Every issue becomes a theme or an experiment.** A symptom that is noticed
  and not written into `THEMES/T*.md` is a symptom that will be rediscovered
  from scratch in three sessions' time. Open a new theme file rather than
  appending an unrelated finding to an existing one.
- Standing permission is on record for `sudo` steps needed to install patched
  Wine components, udev rules, and module changes. Record every system-level
  change in `PATH-TO-GOLD.md` with its exact reversal command.

## Start of every session, in this order

1. Read `STATE.md` — current hypothesis, what is proven, the single next action.
2. Read the last two entries of `JOURNAL.md`.
3. Read the open theme file(s) named in `STATE.md` under "Active themes".
4. `./bin/rbw status` — reconciles STATE.md against what actually ran.

Do not re-derive anything already recorded as settled in `THEMES/`. If you
disagree with a settled finding, reopen it explicitly with new evidence rather
than quietly relitigating it.

## End of every session, without exception

Even if the session is ending mid-thought, spend the last tokens on this:

1. `./bin/rbw journal "<what happened, what it means, run ids>"`
2. Update `STATE.md`: hypothesis, proven/disproven, **Next action** (one concrete
   command or decision), and Blocked-on.
3. Update the relevant `THEMES/T*.md` if evidence moved a hypothesis.
4. `git add -A && git commit` — the commit message is the timeline entry.

A session that produced evidence but left no breadcrumb has produced nothing.

## Rules

- **One variable per run.** Two changes at once forfeits the result.
- **Every claim cites a run id.** "It seems to work" is not a finding;
  `20260812T2010-rb7-baseline → window-ok` is.
- **Never store credentials.** The harness must never be given the AlphaTheta
  account password, and it must not be typed into a logged terminal. When a run
  needs real sign-in, stop and hand the keyboard to the user. Synthetic input
  probes use a throwaway token, never real credentials.
- **Wine logs are evidence, not context.** Never paste a full log into the
  conversation. Run `rbw classify` and read the summary; open the raw log only
  at specific line numbers.
- **Scope.** Fixing Wine bugs, prefix configuration, and the documented
  `HideWineExports` compatibility shim are in scope. Defeating licence or
  subscription enforcement is not. If the blocker resolves to protection
  enforcement, the finding is "NO-GO, hard wall" and the project stops there.
- **Publish what we learn.** Drafts live in `upstream/`. A WineHQ Bugzilla
  report for the 7.2.x first-window failure does not currently exist anywhere;
  filing it is a project deliverable in its own right, independent of whether
  rekordbox ever runs here.
- **A patch is not a fix until it is loaded and greppable.** Every Wine patch
  must plant a marker string (`RBW-*`) that a `strings`/log grep can find, so
  "is my build actually running" is a measurement rather than an assumption.
  A comment-only change does not survive compilation and has fooled us before.
- **Report the cure and the prerequisite differently.** A correctness fix that
  is necessary but not sufficient must be written up as such. Announcing a
  prerequisite as the cure wastes the next session.

## Layout

    bin/rbw            harness CLI — see `rbw` with no args
    bin/classify.py    wine log triage + normaliser (for diffing runs)
    bin/verdict.py     adjudicator: maps a run onto the failure taxonomy
    recipes/*.recipe   declarative prefix definitions (hashed into manifests)
    runs/<id>/         per-run evidence: manifest, wine.log, shots/, verdict
    runs/index.jsonl   one line per run, append-only
    THEMES/T*.md       one investigation theme each, with RCA
    STATE.md           read-first: where we are
    JOURNAL.md         append-only timeline
    upstream/          Bugzilla / AppDB report drafts

## Verdict taxonomy

Deliberately mapped onto the two published AppDB failures so our results are
directly comparable to them:

| verdict | meaning |
|---|---|
| `early-exit` | died before mapping a window |
| `no-window` | alive, never mapped a window |
| `blank-window` | window mapped, uniform fill — matches AppDB 7.2.8 (Dec 2025) |
| `no-input` | window renders, keystrokes not echoed — matches AppDB 7.2.14 (Jun 2026) |
| `window-ok` | renders **and** accepts input — past Gate 1, new ground |
