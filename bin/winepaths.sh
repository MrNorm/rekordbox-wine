#!/usr/bin/env bash
# winepaths — locate the installed Wine's library directories, on any distro.
#
# Sourced, not executed. Sets:
#   WINE_PE_DIR    the PE builtins   (ntdll.dll lives here)
#   WINE_UNIX_DIR  the unix libraries (ntdll.so lives here)
#
# WHY THIS EXISTS. Every script here used to hardcode /usr/lib/wine/..., which
# is the Arch layout and only the Arch layout. Debian puts Wine under
# /usr/lib/x86_64-linux-gnu/wine, Fedora under /usr/lib64/wine, and the WineHQ
# builds under /opt/wine-staging/lib/wine. A hardcoded path does not fail
# loudly on those systems -- install-system-wine-patches.sh would report "no
# system winealsa.so" and stop, which reads as "your Wine is broken" rather
# than "this script only knows one distro".
#
# Detection order: an explicit override, then the directory belonging to the
# `wine` binary actually on PATH (which is what will run), then the usual
# suspects. Each candidate must contain the marker file, so a stale empty
# directory cannot win.
rbw_find_wine_dirs() {
  local pe_marker=ntdll.dll unix_marker=ntdll.so
  local -a roots=()

  # The wine binary on PATH is the one that matters -- follow it home. A distro
  # that ships /usr/bin/wine as a symlink into /opt lands here and nowhere else.
  local w; w="$(command -v wine 2>/dev/null)"
  if [[ -n "$w" ]]; then
    w="$(readlink -f "$w")"
    local b; b="$(dirname "$w")"
    roots+=( "$b/../lib/wine" "$b/../lib64/wine" )
    # Debian and its derivatives put Wine under a multiarch triplet --
    # /usr/lib/x86_64-linux-gnu/wine -- which is NOT reachable from the loader by
    # the two paths above. Globbing one level keeps this working on a derivative
    # with a different triplet or a non-standard prefix, rather than relying on
    # the hardcoded absolute path in the fallback list below.
    local m
    for m in "$b"/../lib/*/wine "$b"/../lib64/*/wine; do
      [[ -d "$m" ]] && roots+=( "$m" )
    done
  fi
  roots+=(
    /usr/lib/wine /usr/lib64/wine
    /usr/lib/x86_64-linux-gnu/wine
    /opt/wine-staging/lib/wine /opt/wine-stable/lib/wine /opt/wine-devel/lib/wine
    /usr/local/lib/wine
  )

  local r pe unix
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    r="$(readlink -f "$r")"
    [[ -z "${pe:-}"   && -f "$r/x86_64-windows/$pe_marker" ]] && pe="$r/x86_64-windows"
    [[ -z "${unix:-}" && -f "$r/x86_64-unix/$unix_marker"  ]] && unix="$r/x86_64-unix"
    [[ -n "${pe:-}" && -n "${unix:-}" ]] && break
  done

  WINE_PE_DIR="${RBW_WINE_PE_DIR:-${pe:-}}"
  WINE_UNIX_DIR="${RBW_WINE_UNIX_DIR:-${unix:-}}"
  [[ -n "$WINE_PE_DIR" && -n "$WINE_UNIX_DIR" ]]
}

if ! rbw_find_wine_dirs; then
  echo "rekordbox-wine: cannot find Wine's library directories." >&2
  echo "  Looked for x86_64-windows/ntdll.dll and x86_64-unix/ntdll.so under the" >&2
  echo "  usual prefixes. Set RBW_WINE_PE_DIR and RBW_WINE_UNIX_DIR to point at" >&2
  echo "  them, or install Wine." >&2
  return 1 2>/dev/null || exit 1
fi
export WINE_PE_DIR WINE_UNIX_DIR
