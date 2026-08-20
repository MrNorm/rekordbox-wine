#!/usr/bin/env bash
# rbset — set one rekordbox setting in rekordbox3.settings, with the app closed.
#
# rekordbox rewrites this file while it runs, so an edit made against a running
# app is silently discarded. This refuses to run unless rekordbox is stopped,
# keeps a backup, and prints the before/after so an arm can never be recorded
# against a setting that did not actually change.
#
# Usage: bin/rbset.sh <KeyName> <value>
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
K="${1:?key}"; V="${2:?value}"
pgrep -x rekordbox.exe >/dev/null && { echo "rbset: rekordbox is running — close it first"; exit 2; }
S=$(ls prefixes/rb7/drive_c/users/*/AppData/Roaming/Pioneer/rekordbox6/rekordbox3.settings)
cp "$S" "$S.rbset-backup"
python3 - "$S" "$K" "$V" <<'PY'
import re, sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
d = open(path, 'rb').read()
pat = ('name="%s" val="' % key).encode()
i = d.find(pat)
if i < 0:
    sys.exit('rbset: key %s not found' % key)
j = d.index(b'"', i + len(pat))
old = d[i+len(pat):j].decode()
d = d[:i+len(pat)] + val.encode() + d[j:]
open(path, 'wb').write(d)
print('rbset: %s  %s -> %s' % (key, old, val))
PY
