#!/usr/bin/env bash
# rbexe — print the Windows path of the installed rekordbox, whatever its version.
#
# WHY. Thirteen scripts hardcoded `rekordbox 7.2.17\rekordbox.exe`. The user
# updated to 7.2.18 on 2026-08-18 and the 7.2.17 directory was removed, so every
# one of them would have launched nothing and reported it as a failure of
# whatever it was measuring. Version numbers do not belong in a harness.
#
# Prints the C:\ path on stdout; exits 2 if no install is found.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PREFIX="${RBW_PREFIX:-$PWD/prefixes/rb7}"
DIR="$PREFIX/drive_c/Program Files/rekordbox"
# Newest first, so a machine with two versions installed uses the current one.
while IFS= read -r d; do
  [ -f "$d/rekordbox.exe" ] || continue
  printf 'C:\\Program Files\\rekordbox\\%s\\rekordbox.exe\n' "$(basename "$d")"
  exit 0
done < <(find "$DIR" -maxdepth 1 -mindepth 1 -type d -name 'rekordbox *' -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
echo "rbexe: no rekordbox.exe under $DIR" >&2
exit 2
