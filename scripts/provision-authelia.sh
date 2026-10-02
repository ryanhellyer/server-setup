#!/usr/bin/env bash
# =============================================================================
# provision-authelia.sh — generate the Authelia user database from .env and
# (re)start the `authelia` container.
#
#   sudo bash scripts/provision-authelia.sh [--dry-run] [--no-hash]
#
# Authelia is the forward-auth / SSO gate in front of protected vhosts
# (chat.hellyer.kiwi today). It is its own container, config in ./authelia,
# data (SQLite DB + user database + notifier) under ~/www/auth.hellyer.kiwi.
#
# The initial user is created from AUTHELIA_ADMIN_USER / AUTHELIA_ADMIN_EMAIL /
# AUTHELIA_ADMIN_PASSWORD in .env. The password is hashed with the Authelia
# binary itself (`authelia crypto hash generate argon2`, falling back to the
# legacy `authelia hash-password`); the plaintext never lands on disk beyond
# .env, and the generated users_database.yml is gitignored and snapshot-backed.
#
# This script is the STANDALONE entry point: it creates its own data dir, fills
# in any missing AUTHELIA_* secrets in .env, and starts the container, so it
# does not require a (destructive) full deploy.sh. The admin user/email default
# to ryan / admin@hellyer.kiwi; only AUTHELIA_ADMIN_PASSWORD must be supplied.
# Needs a running podman/compose stack. Run from anywhere; re-running is safe.
#
# Idempotent: re-running regenerates users_database.yml from the current .env
# values and restarts the container. Existing secrets are never rotated. Pass
# --no-hash to skip re-hashing (only rewrites file/metadata).
#
# Options: --dry-run, --no-hash
#
# Config: AUTHELIA_* in .env (see .env.example / compose.yaml).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-env.sh

WWW_ROOT="$(resolve_www_root)"
DATA_DIR="$WWW_ROOT/auth.hellyer.kiwi"
ADMIN_USER_RESOLVED="$(resolve_admin_user)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

DRY=0; DO_HASH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --no-hash) DO_HASH=0; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
run() { if [ "$DRY" = 1 ]; then printf '    DRY: %s\n' "$*"; else "$@"; fi; }

USERS_FILE="$DATA_DIR/users_database.yml"

# ---- validate / complete settings ------------------------------------------
# .env is the source of truth. The three secrets are auto-generated here if
# missing (so this script is a self-contained, NON-destructive alternative to
# running the full, destructive deploy.sh). The admin identity defaults to the
# repo's ryan account; only the password must be supplied by the operator.
ENV_FILE="$PWD/.env"
[ -f "$ENV_FILE" ] || die ".env not found — run scripts/deploy.sh once to create it (or copy .env.example)."

AUTHELIA_ADMIN_USER="${AUTHELIA_ADMIN_USER:-ryan}"
AUTHELIA_ADMIN_EMAIL="${AUTHELIA_ADMIN_EMAIL:-admin@hellyer.kiwi}"
AUTHELIA_IMAGE="docker.io/authelia/authelia:4.39"

# In a dry run, do not modify .env — just report what would happen and continue
# with whatever is already loaded, so the preview is side-effect free.
if [ "$DRY" = 1 ]; then
  say "DRY RUN — .env will not be modified"
  [ -n "$(get_env "$ENV_FILE" AUTHELIA_SESSION_SECRET 2>/dev/null || true)" ] \
    || warn "AUTHELIA_SESSION_SECRET would be generated"
  [ -n "$(get_env "$ENV_FILE" AUTHELIA_STORAGE_ENCRYPTION_KEY 2>/dev/null || true)" ] \
    || warn "AUTHELIA_STORAGE_ENCRYPTION_KEY would be generated"
  [ -n "$(get_env "$ENV_FILE" AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET 2>/dev/null || true)" ] \
    || warn "AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET would be generated"
else
  # Persist the admin identity defaults if they aren't already in .env.
  [ -n "$(get_env "$ENV_FILE" AUTHELIA_ADMIN_USER 2>/dev/null || true)" ] \
    || { set_env "$ENV_FILE" AUTHELIA_ADMIN_USER "$AUTHELIA_ADMIN_USER"; say "Defaulted AUTHELIA_ADMIN_USER=$AUTHELIA_ADMIN_USER in .env"; }
  [ -n "$(get_env "$ENV_FILE" AUTHELIA_ADMIN_EMAIL 2>/dev/null || true)" ] \
    || { set_env "$ENV_FILE" AUTHELIA_ADMIN_EMAIL "$AUTHELIA_ADMIN_EMAIL"; say "Defaulted AUTHELIA_ADMIN_EMAIL=$AUTHELIA_ADMIN_EMAIL in .env"; }

  # Generate any missing secrets (idempotent — never rotates existing values).
  for _var in AUTHELIA_SESSION_SECRET AUTHELIA_STORAGE_ENCRYPTION_KEY \
              AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET; do
    _before="$(get_env "$ENV_FILE" "$_var" 2>/dev/null || true)"
    ensure_secret "$ENV_FILE" "$_var" >/dev/null
    [ -n "$_before" ] || say "Generated $_var in .env"
  done
  unset _var _before
  # Re-read .env so the values above reach `podman compose`.
  set -a; source "$ENV_FILE"; set +a
fi

AUTHELIA_ADMIN_USER="${AUTHELIA_ADMIN_USER:-}"
AUTHELIA_ADMIN_EMAIL="${AUTHELIA_ADMIN_EMAIL:-}"
AUTHELIA_ADMIN_PASSWORD="${AUTHELIA_ADMIN_PASSWORD:-}"

[ -n "$AUTHELIA_ADMIN_USER" ]     || die "AUTHELIA_ADMIN_USER is not set in .env."
[ -n "$AUTHELIA_ADMIN_EMAIL" ]    || die "AUTHELIA_ADMIN_EMAIL is not set in .env."
if [ "$DRY" = 1 ]; then
  [ -n "$AUTHELIA_ADMIN_PASSWORD" ] || warn "AUTHELIA_ADMIN_PASSWORD is not set (dry run — nothing to hash)"
else
  [ -n "$AUTHELIA_ADMIN_PASSWORD" ] || die "AUTHELIA_ADMIN_PASSWORD is empty in .env — set it (to the password you want to log in with), then re-run."
fi

if [ "$DRY" != 1 ]; then
  [ -n "${AUTHELIA_SESSION_SECRET:-}" ] && [ -n "${AUTHELIA_STORAGE_ENCRYPTION_KEY:-}" ] \
    || die "AUTHELIA_SESSION_SECRET / AUTHELIA_STORAGE_ENCRYPTION_KEY could not be set in .env."
fi

# ---- 1. data dir + hash the password ---------------------------------------
say "Ensuring data dir $DATA_DIR"
run mkdir -p "$DATA_DIR"

HASH="$AUTHELIA_ADMIN_PASSWORD"
if [ "$DO_HASH" = 1 ]; then
  say "Hashing the admin password with the Authelia binary"
  if [ "$DRY" = 1 ]; then
    echo "    DRY: podman run --rm $AUTHELIA_IMAGE authelia crypto hash generate argon2 --password <redacted>"
    HASH='$argon2id$REDACTED'
  else
    # Authelia prints a version banner (e.g. "v4.39.28") before the digest, and
    # the digest line is prefixed "Digest: ". Never take a fixed line number —
    # extract the $argon2... token wherever it appears. Prefer the current
    # `crypto hash generate argon2` subcommand; fall back to the legacy
    # `hash-password` for older images. `|| true` is essential: with
    # `set -o pipefail`, a grep with no match would otherwise abort the script
    # before the fallback is tried.
    hash_digest() { # podman args... (stdin ignored)
      podman run --rm "$@" 2>/dev/null \
        | grep -oE '\$argon2[^[:space:]]+' | tail -1 || true
    }
    HASH="$(hash_digest "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password "$AUTHELIA_ADMIN_PASSWORD")"
    case "$HASH" in
      \$argon2*) : ;;
      *)
        warn "The primary hash command returned no digest — retrying with the legacy interface."
        HASH="$(hash_digest -i "$AUTHELIA_IMAGE" authelia hash-password)"
        ;;
    esac
    case "$HASH" in
      \$argon2*) : ;;
      *)
        # A bare version string here is the signature of an OLD copy of this
        # script that parsed the wrong line. Detect it to save a confusing debug.
        if printf '%s' "$HASH" | grep -qE '^v?[0-9]+\.[0-9]+'; then
          die "Got a version string ('$HASH') instead of a hash — this script is STALE.
     Update it, then re-run:
       cd ~/server-setup && rm -f .last-sha
       sudo env SERVER_SETUP_ADMIN_USER=ryan bash <(curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup/master/install/setup.sh)
     (or: git pull). Then: sudo scripts/provision-authelia.sh"
        fi
        die "Could not hash the password (got '$HASH'). Is the image pullable? Try: podman pull $AUTHELIA_IMAGE"
        ;;
    esac
  fi
fi

# ---- 2. write users_database.yml -------------------------------------------
# Quote the hash: it contains $ and would otherwise be mangled by YAML/shell.
say "Writing $USERS_FILE"
if [ "$DRY" = 1 ]; then
  echo "    DRY: write users_database.yml for '$AUTHELIA_ADMIN_USER' <$AUTHELIA_ADMIN_EMAIL>"
else
  cat > "$USERS_FILE" <<EOF
# Generated by scripts/provision-authelia.sh — DO NOT EDIT BY HAND.
# Rewritten from AUTHELIA_ADMIN_* in .env every time provisioning runs.
# This file lives under ~/www so it is included in the nightly snapshot.
users:
  ${AUTHELIA_ADMIN_USER}:
    displayname: '${AUTHELIA_ADMIN_USER}'
    password: '${HASH}'
    email: '${AUTHELIA_ADMIN_EMAIL}'
    groups:
      - 'admins'
EOF
  chmod 600 "$USERS_FILE"
  # Container runs as root (user: "0:0"); keep the dir usable by the admin user too.
  chown -R "$ADMIN_USER_RESOLVED:$ADMIN_USER_RESOLVED" "$DATA_DIR" 2>/dev/null || true
  ok "Wrote user database for '$AUTHELIA_ADMIN_USER'."
fi

# ---- 3. bring up the container ---------------------------------------------
say "Bringing up the authelia service"
if [ "$DRY" = 1 ]; then
  echo "    DRY: podman compose up -d authelia"
else
  if podman compose version >/dev/null 2>&1; then podman compose up -d authelia; else podman-compose up -d authelia; fi
fi

# ---- 4. wait for health -----------------------------------------------------
if [ "$DRY" != 1 ]; then
  say "Waiting for Authelia on http://127.0.0.1:9091/api/health (via the container network)"
  up=0
  for _ in $(seq 1 30); do
    if podman exec "$CONTAINER_AUTHELIA" wget -qO- http://127.0.0.1:9091/api/health >/tmp/authelia-health.json 2>/dev/null; then
      ok "Authelia is up: $(cat /tmp/authelia-health.json)"; up=1; break
    fi
    sleep 3
  done
  [ "$up" = 1 ] || warn "Authelia did not answer in 90s — check: podman logs authelia"
fi

# ---- 5. reload nginx --------------------------------------------------------
if [ "$DRY" != 1 ]; then
  podman exec "$CONTAINER_NGINX" nginx -t >/dev/null 2>&1 \
    && podman exec "$CONTAINER_NGINX" nginx -s reload >/dev/null 2>&1 || true
fi
ok "Done: authelia"
