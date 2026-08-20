# research/

Investigation tooling. **Nothing here ships**, and nothing here is needed to
install or run rekordbox — that is `bin/` and `packaging/`.

It is kept because the findings in `docs/investigation/THEMES/` cite these
scripts by name, and a claim whose instrument has been deleted is not
reproducible. If you are reviewing a theme and want to re-run what produced a
number, it is probably here.

## `probes/`

One-off scripts written to answer a single question, in the shape the question
had that day. They are not general tools, they are not maintained, and several
only make sense against a specific Wine build or a specific rekordbox version.

Examples of what they do: read the USB wire, count Direct2D frame completions,
walk a stripped PE for call sites, drive the UI to a specific pane, sample
thread scheduling state, and dump PipeWire's view of a stream.

## `matrix/`

Sweep definitions for `bin/rbw matrix` — one variable per row, run unattended.

## `retired/`

Tools that were correct once and are now superseded, kept because the
documentation still cites them for reversal:

- `install-system-wine-patches.sh` and `install-wineusb-hcd.sh` overwrote Wine
  libraries owned by the distribution's `wine` package. That approach was
  withdrawn — see `docs/investigation/THEMES/T13-coexistence.md` — and replaced
  by `bin/make-private-wine.sh`, which touches nothing outside its own tree.
  **If you ever ran the old scripts, these are how you undo them:**

      sudo research/retired/install-system-wine-patches.sh --revert
      sudo research/retired/install-wineusb-hcd.sh --revert

  Verify with `bin/verifyloaded.sh` and by checking that no `RBW-` marker
  appears in your system Wine.
