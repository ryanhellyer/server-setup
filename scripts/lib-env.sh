#!/usr/bin/env bash
# =============================================================================
# lib-env.sh — tiny helpers for editing KEY=value files (source, don't run).
#
#   get_env FILE KEY    print the value (quotes stripped), non-zero if absent
#   set_env FILE KEY V  replace or append KEY=V (creates the file)
#   ensure_secret FILE KEY [BYTES]
#                       ensure KEY has a non-empty value; if missing/blank,
#                       generate BYTES random bytes (hex, default 32) and write
#                       it to FILE. Prints the value only when it generated one.
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

# Ensure KEY in FILE holds a non-empty value. Generates a hex secret if the key
# is missing OR present-but-blank. Idempotent: an existing non-empty value is
# left untouched (important — rotating these secrets invalidates sessions and
# encrypted data). Echoes the value only when it had to generate one, so callers
# can report it.
ensure_secret() { # FILE KEY [BYTES]
  local file="$1" key="$2" bytes="${3:-32}" val
  val="$(get_env "$file" "$key" 2>/dev/null || true)"
  if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
  val="$(openssl rand -hex "$bytes")"
  set_env "$file" "$key" "$val"
  printf '%s' "$val"
}
