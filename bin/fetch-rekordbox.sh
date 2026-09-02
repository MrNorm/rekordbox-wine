#!/usr/bin/env bash
# fetch-rekordbox — find, choose and download a rekordbox Windows x64 installer.
#
# The download page lists the installer URL in its HTML:
#   https://cdn.rekordbox.com/files/<stamp>/Install_rekordbox_x64_<v>.zip
# recipes/rb7.recipe used to say the page was JS-driven and the installer had to
# be supplied by hand. Not true for the installer link.
#
# WHAT IS ACTUALLY AVAILABLE. AlphaTheta publishes exactly ONE installer: the
# current release. There is no archive page, and the CDN path carries an opaque
# timestamp directory that cannot be guessed -- an older filename under a known
# stamp returns 403. So the version menu offers the current release plus any
# installer already on this machine. It does not pretend to offer more.
#
# Downloads only. rekordbox is proprietary; sign in with your own account.
#
# Usage:
#   fetch-rekordbox.sh [-o outdir]     choose interactively when there is a
#                                      choice and a terminal; newest otherwise
#   fetch-rekordbox.sh --latest        never prompt, take the newest
#   fetch-rekordbox.sh --list          show what is available, download nothing
#   fetch-rekordbox.sh --url-only      print the current release URL
set -uo pipefail

PAGE="https://rekordbox.com/en/download/"
OUT="${RBW_DOWNLOAD_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/rekordbox-wine}"
MODE=auto
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)    OUT="${2:?-o needs a directory}"; shift 2 ;;
    --latest|-y|--yes|--non-interactive) MODE=latest; shift ;;
    --list)      MODE=list; shift ;;
    --url-only)  MODE=url; shift ;;
    -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "usage: $(basename "$0") [-o dir] [--latest|--list|--url-only]" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null || { echo "fetch-rekordbox: curl is required" >&2; exit 1; }

# ------------------------------------------------------------------ discovery
# Highest version wins rather than last-on-page: the page also carries older
# installers in help links and the ordering is not guaranteed.
REMOTE_URL="$(curl -fsSL --max-time 60 "$PAGE" 2>/dev/null \
  | grep -oE "https://cdn\.rekordbox\.com/files/[0-9]+/Install_rekordbox_x64_[0-9_]+\.zip" \
  | sort -t_ -k4,4V | tail -1)"
REMOTE_VER=""
[[ -n "$REMOTE_URL" ]] && REMOTE_VER="$(sed -E 's/.*Install_rekordbox_x64_([0-9_]+)\.zip/\1/; s/_/./g' <<<"$REMOTE_URL")"

if [[ "$MODE" == url ]]; then
  [[ -n "$REMOTE_URL" ]] || { echo "fetch-rekordbox: no installer link found" >&2; exit 1; }
  echo "$REMOTE_URL"; exit 0
fi

# Installers already here. Searched in the download cache, the working
# directory and the source tree's artifacts/, because re-downloading 660 MB of
# something already on the disk is the kind of thing that makes people give up.
declare -a L_VER=() L_PATH=()
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  v="$(basename "$f" | sed -E 's/.*Install_rekordbox_x64_([0-9_]+)\.(zip|exe)/\1/; s/_/./g')"
  [[ "$v" =~ ^[0-9.]+$ ]] || continue
  dup=0; for i in "${!L_VER[@]}"; do [[ "${L_VER[$i]}" == "$v" ]] && dup=1; done
  [[ $dup -eq 1 ]] && continue
  L_VER+=("$v"); L_PATH+=("$f")
done < <(find "$OUT" "$PWD" "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../artifacts" \
              -maxdepth 1 -name 'Install_rekordbox_x64_*' 2>/dev/null | sort -V)

if [[ -z "$REMOTE_URL" && ${#L_VER[@]} -eq 0 ]]; then
  cat >&2 <<MSG
fetch-rekordbox: no installer link found on $PAGE, and none cached locally.

The page layout has changed, or the network blocked the request. Download the
Windows 64-bit installer by hand and pass it straight to the launcher:

  rekordbox-wine --install /path/to/Install_rekordbox_x64_*.exe
MSG
  exit 1
fi

# ---------------------------------------------------------------------- list
show_list() {
  echo "Available:"
  [[ -n "$REMOTE_VER" ]] && printf '  %-10s %s\n' "$REMOTE_VER" "current release (download, ~660 MB)"
  for i in "${!L_VER[@]}"; do printf '  %-10s already downloaded: %s\n' "${L_VER[$i]}" "${L_PATH[$i]}"; done
  [[ ${#L_VER[@]} -eq 0 ]] && echo "  (nothing cached locally)"
  echo
  echo "AlphaTheta publishes only the current release; older versions are not"
  echo "downloadable from rekordbox.com."
}
[[ "$MODE" == list ]] && { show_list; exit 0; }

# ------------------------------------------------------------------- choosing
# Options: the remote release, then each cached installer.
declare -a O_LABEL=() O_KIND=() O_VAL=()
if [[ -n "$REMOTE_VER" ]]; then
  O_LABEL+=("$REMOTE_VER  (current release — download)"); O_KIND+=(remote); O_VAL+=("$REMOTE_URL")
fi
for i in "${!L_VER[@]}"; do
  [[ "${L_VER[$i]}" == "$REMOTE_VER" && "${L_PATH[$i]}" == *.zip ]] && continue
  O_LABEL+=("${L_VER[$i]}  (already here — ${L_PATH[$i]})"); O_KIND+=(local); O_VAL+=("${L_PATH[$i]}")
done

CHOICE=0
if [[ "$MODE" == auto && ${#O_LABEL[@]} -gt 1 && -t 0 && -t 1 ]]; then
  echo "Which version?"
  for i in "${!O_LABEL[@]}"; do printf '  %d) %s\n' $((i+1)) "${O_LABEL[$i]}"; done
  echo
  read -r -p "Choice [1]: " reply
  reply="${reply:-1}"
  if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#O_LABEL[@]} )); then
    CHOICE=$((reply-1))
  else
    echo "Not a listed choice — taking 1." >&2
  fi
elif [[ ${#O_LABEL[@]} -gt 1 ]]; then
  # Unattended: newest. Explicit rather than implicit, because "no terminal" is
  # exactly when a wrong silent default is hardest to notice.
  echo "Unattended: taking the newest (${O_LABEL[0]%% *})."
fi

KIND="${O_KIND[$CHOICE]}"; VAL="${O_VAL[$CHOICE]}"

# ------------------------------------------------------------- already local
# The caller needs to know WHICH installer was chosen. Writing it to a file
# beats parsing stdout: an older version picked deliberately is not the newest
# file on disk, so "find the newest .exe" would quietly override the choice.
record_choice() { [[ -n "${RBW_PICK_FILE:-}" ]] && printf '%s\n' "$1" > "$RBW_PICK_FILE"; return 0; }

if [[ "$KIND" == local ]]; then
  if [[ "$VAL" == *.exe ]]; then
    record_choice "$VAL"
    echo "installer: $VAL"; echo; echo "Install it with:"; echo "  rekordbox-wine --install \"$VAL\""
    exit 0
  fi
  ZIP="$VAL"
else
  # ------------------------------------------------------------------ download
  ZIP="$OUT/$(basename "$VAL")"
  # content-length decides "already complete", so a truncated earlier download
  # resumes instead of being trusted.
  LEN="$(curl -fsSLI --max-time 60 "$VAL" 2>/dev/null | tr -d '\r' \
         | awk 'tolower($1)=="content-length:"{n=$2} END{print n}')"
  echo "version : $REMOTE_VER"
  echo "url     : $VAL"
  echo "size    : ${LEN:-unknown} bytes"
  mkdir -p "$OUT" || { echo "fetch-rekordbox: cannot create $OUT" >&2; exit 1; }
  if [[ -f "$ZIP" && -n "$LEN" && "$(stat -c%s "$ZIP")" == "$LEN" ]]; then
    echo "already downloaded: $ZIP"
  else
    echo "downloading to $ZIP"
    curl -fL --retry 3 --retry-delay 2 -C - -o "$ZIP" "$VAL" \
      || { echo "fetch-rekordbox: download failed" >&2; exit 1; }
    if [[ -n "$LEN" && "$(stat -c%s "$ZIP")" != "$LEN" ]]; then
      echo "fetch-rekordbox: size mismatch — got $(stat -c%s "$ZIP"), expected $LEN" >&2
      exit 1
    fi
  fi
  echo "sha256  : $(sha256sum "$ZIP" | cut -d' ' -f1)"
fi

# --------------------------------------------------------------------- unpack
EXE=""
if command -v unzip >/dev/null; then
  inner="$(unzip -Z1 "$ZIP" 2>/dev/null | grep -m1 -E '\.exe$')"
  if [[ -n "$inner" ]]; then
    unzip -o -q -d "$(dirname "$ZIP")" "$ZIP" "$inner" && EXE="$(dirname "$ZIP")/$inner"
  fi
fi

echo
if [[ -n "$EXE" && -f "$EXE" ]]; then
  record_choice "$EXE"
  echo "installer: $EXE"
  echo; echo "Install it with:"; echo "  rekordbox-wine --install \"$EXE\""
else
  echo "Downloaded: $ZIP"
  echo "unzip it, then: rekordbox-wine --install <the .exe inside>"
fi
