#!/usr/bin/env bash
# =============================================================================
# lib-env.sh — tiny helpers for editing KEY=value files (source, don't run).
#
#   get_env FILE KEY    print the value (quotes stripped), non-zero if absent
#   set_env FILE KEY V  replace or append KEY=V (creates the file)
# =============================================================================

get_env() { # FILE KEY
  [ -f "$1" ] || return 1
  grep -E "^[[:space:]]*$2=" "$1" | tail -1 | cut -d= -f2- | sed -E "s/^['\"]//; s/['\"]\$//"
}

set_env() { # FILE KEY VALUE
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
found = False
for i, ln in enumerate(lines):
    if ln.startswith(key + "="):
        lines[i] = f"{key}={val}"; found = True
if not found:
    lines.append(f"{key}={val}")
open(path, "w").write("\n".join(lines) + "\n")
PY
}
