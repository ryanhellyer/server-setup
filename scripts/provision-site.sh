#!/usr/bin/env bash
# =============================================================================
# provision-site.sh — restore ONE site from the newest storage snapshot.
#
#   sudo bash scripts/provision-site.sh <snapshot-dir> [options]
#
# Always fresh: files are rsynced with --delete, and the database is dropped,
# recreated and re-imported from the newest dump. The app is then pointed at
# the containers with its OWN database user (named after the DB) and a freshly
# generated password.
#
# Everything is derived from the site's own files (no manifest):
#   Laravel  -> .env  (DB_CONNECTION / DB_DATABASE / DB_USERNAME / DB_PASSWORD)
#   Symfony  -> .env  (DATABASE_URL)
#   WordPress-> wp-config.php
#   sqlite   -> just ensure the database file exists
#
# Sites with a package.json also get their front-end assets rebuilt
# (scripts/build-assets.sh, inside the node container) when the restored Vite
# manifest/assets are missing or inconsistent.
#
# Options:
#   --to DIR        local dir name (default: SNAPSHOT_RENAMES mapping, else the
#                   snapshot dir name)
#   --domain DOMAIN canonical domain (sets APP_URL; default: the local dir name)
#   --files-only    only sync files
#   --db-only       only provision the database
#   --dry-run       print actions, change nothing
#
# Config: see scripts/lib-storage.sh (STORAGE_*, SNAPSHOT_ROOT, DB_DUMP_DIR,
# SNAPSHOT_RENAMES) and scripts/lib-db.sh.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-storage.sh
source scripts/lib-db.sh
source scripts/lib-env.sh
WWW_ROOT="$(resolve_www_root)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

SITE=""; TO=""; DOMAIN=""; DO_FILES=1; DO_DB=1; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO="${2:?}"; shift 2 ;;
    --domain) DOMAIN="${2:?}"; shift 2 ;;
    --files-only) DO_DB=0; shift ;;
    --db-only) DO_FILES=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) [ -z "$SITE" ] || die "Only one site supported."; SITE="$1"; shift ;;
  esac
done
[ -n "$SITE" ] || die "Usage: provision-site.sh <snapshot-dir> [options]"
case "$SITE" in *[!A-Za-z0-9._-]*) die "Invalid site name: $SITE" ;; esac

SNAPSHOT="$(newest_snapshot "$SITE")"
[ -n "$SNAPSHOT" ] || die "No snapshot containing '$SITE' under $SNAPSHOT_ROOT."
REMOTE_DIR="$SNAPSHOT/$SITE"
LOCAL_NAME="${TO:-$(apply_rename "$SITE")}"
LOCAL_DIR="$WWW_ROOT/$LOCAL_NAME"
DOMAIN="${DOMAIN:-$LOCAL_NAME}"

TMP_SUFFIX="$$"
trap 'rm -f "/tmp/ps-env.$TMP_SUFFIX" "/tmp/ps-wp.$TMP_SUFFIX" 2>/dev/null || true' EXIT
run() { if [ "$DRY" = 1 ]; then printf '    DRY: %s\n' "$*"; else "$@"; fi; }

# ---- point the app at the container services --------------------------------
# Runs BEFORE any migration attempt so `artisan migrate` / doctrine migrate can
# actually reach MariaDB (the snapshot's .env still has the OLD server's
# DB_HOST=localhost). Safe to call once DB_USER/DB_PASS are known (or empty for
# apps with no database). Credentials/APP_URL are only written when relevant.
rewrite_app_env() {
  if [ "$APP_TYPE" = "symfony" ]; then
    if [ "$DB_DRIVER" = "mariadb" ] && [ "$DO_DB" = 1 ]; then
      say "Rewriting DATABASE_URL for the container network"
      new_url="mysql://$DB_USER:$DB_PASS@mariadb:3306/$DB_NAME"
      [ -n "$DB_QUERY" ] && new_url="$new_url?$DB_QUERY"
      [ "$DRY" != 1 ] && set_env "$ENV_FILE" DATABASE_URL "\"$new_url\""
    fi
    [ "$DRY" != 1 ] && {
      # REDIS_URL, not just REDIS_HOST: Symfony apps wire Predis / the cache
      # provider off a DSN (`%env(REDIS_URL)%`), and the snapshot's value still
      # points at the old host's localhost — which inside the container is the
      # container itself, so the app 500s with "Connection refused".
      set_env "$ENV_FILE" REDIS_URL "redis://valkey:6379"
      set_env "$ENV_FILE" REDIS_HOST valkey
      set_env "$ENV_FILE" REDIS_PASSWORD ""
    }
  elif [ -f "$LOCAL_DIR/.env" ]; then
    say "Rewriting app .env for the container network"
    set_env "$LOCAL_DIR/.env" DB_HOST mariadb
    set_env "$LOCAL_DIR/.env" DB_PORT 3306
    set_env "$LOCAL_DIR/.env" REDIS_URL "redis://valkey:6379"
    set_env "$LOCAL_DIR/.env" REDIS_HOST valkey
    set_env "$LOCAL_DIR/.env" REDIS_PASSWORD ""
    if [ "$DB_DRIVER" = "mariadb" ] && [ "$DO_DB" = 1 ]; then
      set_env "$LOCAL_DIR/.env" DB_USERNAME "$DB_USER"
      set_env "$LOCAL_DIR/.env" DB_PASSWORD "$DB_PASS"
    fi
    set_env "$LOCAL_DIR/.env" APP_URL "https://$DOMAIN"
  elif [ -f "$LOCAL_DIR/wp-config.php" ]; then
    say "Rewriting wp-config.php for the container network"
    if [ "$DRY" != 1 ]; then
      sed -i -E "s/(define\(\s*'DB_HOST'\s*,\s*')[^']*(')/\1mariadb\2/"     "$LOCAL_DIR/wp-config.php"
      if [ "$DB_DRIVER" = "mariadb" ] && [ "$DO_DB" = 1 ]; then
        sed -i -E "s/(define\(\s*'DB_USER'\s*,\s*')[^']*(')/\1$DB_USER\2/"     "$LOCAL_DIR/wp-config.php"
        sed -i -E "s/(define\(\s*'DB_PASSWORD'\s*,\s*')[^']*(')/\1$DB_PASS\2/" "$LOCAL_DIR/wp-config.php"
      fi
    fi
  fi
}

say "Provisioning $SITE  ->  $LOCAL_NAME   (snapshot $SNAPSHOT)"
[ "$DRY" = 1 ] && warn "dry-run: no changes will be made"

# ---- 1. files (always fresh) ------------------------------------------------
if [ "$DO_FILES" = 1 ]; then
  if ! box_ssh "ls '$REMOTE_DIR'" >/dev/null 2>&1; then
    warn "snapshot dir '$REMOTE_DIR' missing on the box — skipping file sync."
  else
    say "Syncing files -> $LOCAL_DIR"
    run mkdir -p "$LOCAL_DIR"
    run rsync -az --delete --exclude='*.log' --exclude='/logs' --exclude='.cache' --exclude='lost+found' \
      -e "ssh -i $STORAGE_KEY -p $STORAGE_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
      "$STORAGE_USER@$STORAGE_HOST:$REMOTE_DIR/" "$LOCAL_DIR/"
    run bash "$PWD/scripts/fix-perms.sh" "$LOCAL_DIR" >/dev/null
  fi
fi

# ---- 2. detect the app + its database ---------------------------------------
APP_TYPE=""; DB_DRIVER=""; DB_NAME=""; DB_QUERY=""
ENV_REWRITTEN=0
ENV_FILE="$LOCAL_DIR/.env"; WPCONF="$LOCAL_DIR/wp-config.php"
if [ ! -f "$ENV_FILE" ] && [ ! -f "$WPCONF" ]; then
  box_cat "$REMOTE_DIR/.env"          > "/tmp/ps-env.$TMP_SUFFIX" 2>/dev/null || true
  box_cat "$REMOTE_DIR/wp-config.php" > "/tmp/ps-wp.$TMP_SUFFIX"  2>/dev/null || true
  [ -s "/tmp/ps-env.$TMP_SUFFIX" ] && ENV_FILE="/tmp/ps-env.$TMP_SUFFIX"
  [ -s "/tmp/ps-wp.$TMP_SUFFIX" ]  && WPCONF="/tmp/ps-wp.$TMP_SUFFIX"
fi

if [ -f "$ENV_FILE" ] && grep -qE '^[[:space:]]*DATABASE_URL=' "$ENV_FILE"; then
  APP_TYPE="symfony"
  DB_URL="$(get_env "$ENV_FILE" DATABASE_URL || true)"
  parsed="$(python3 - "$DB_URL" <<'PY'
import sys, urllib.parse as u
url = sys.argv[1].strip().strip('"').strip("'")
p = u.urlsplit(url)
print(p.scheme)
print(p.path.lstrip('/'))
print(p.query)
PY
)"
  DB_DRIVER="$(printf '%s\n' "$parsed" | sed -n 1p)"
  DB_NAME="$(printf '%s\n' "$parsed" | sed -n 2p)"
  DB_QUERY="$(printf '%s\n' "$parsed" | sed -n 3p)"
  case "$DB_DRIVER" in
    sqlite*) DB_DRIVER="sqlite" ;;
    mysql|mariadb) DB_DRIVER="mariadb" ;;
    *) DB_DRIVER="" ;;
  esac
  say "Detected Symfony app (DATABASE_URL: ${DB_DRIVER:-unknown})"
elif [ -f "$ENV_FILE" ] && grep -qE '^[[:space:]]*DB_CONNECTION=' "$ENV_FILE"; then
  APP_TYPE="laravel"
  DB_DRIVER="$(get_env "$ENV_FILE" DB_CONNECTION || true)"
  # Laravel's default driver is "mysql"; normalise it (like the Symfony branch
  # below) so the credential rewrite and the DB import both recognise it —
  # otherwise a DB_CONNECTION=mysql app keeps its OLD credentials and breaks.
  case "$DB_DRIVER" in
    mysql|mariadb) DB_DRIVER="mariadb" ;;
    sqlite)       DB_DRIVER="sqlite" ;;
  esac
  DB_NAME="$(get_env "$ENV_FILE" DB_DATABASE || true)"
  say "Detected Laravel app (DB_CONNECTION=${DB_DRIVER:-mariadb})"
elif [ -f "$WPCONF" ]; then
  APP_TYPE="wordpress"; DB_DRIVER="mariadb"
  DB_NAME="$(sed -nE "s/.*define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]([^'\"]+)['\"].*/\1/p" "$WPCONF" | head -1)"
  say "Detected WordPress site (DB_NAME=${DB_NAME:-?})"
elif [ -f "$ENV_FILE" ]; then
  APP_TYPE="env"; say "Detected .env app (no database configured)"
else
  warn "No .env or wp-config.php found — static site."
fi

# ---- 3. database ------------------------------------------------------------
if [ "$DO_DB" = 1 ] && [ -n "$DB_DRIVER" ]; then
  if [ "$DB_DRIVER" = "sqlite" ]; then
    if [ "$APP_TYPE" = "symfony" ]; then
      # Symfony resolves %kernel.project_dir% at runtime; just make sure var/ exists.
      [ "$DRY" != 1 ] && mkdir -p "$LOCAL_DIR/var"
      ok "SQLite (Symfony) — no import needed."
    else
      case "$DB_NAME" in
        ""|*/)              sqlite_path="$LOCAL_DIR/database/database.sqlite" ;;
        "$CONTAINER_WWW"/*) sqlite_path="$(www_host_path "$DB_NAME")" ;;
        /*)                 sqlite_path="$DB_NAME" ;;
        *)                  sqlite_path="$LOCAL_DIR/$DB_NAME" ;;
      esac
      say "SQLite database: $sqlite_path"
      if [ "$DRY" != 1 ]; then
        mkdir -p "$(dirname "$sqlite_path")"
        [ -e "$sqlite_path" ] || : > "$sqlite_path"
      fi
    fi
  else
    [ -n "$DB_NAME" ] || die "No database name detected."
    case "$DB_NAME" in *[!A-Za-z0-9_]*) die "Unsafe DB name: $DB_NAME" ;; esac
    DB_USER="$DB_NAME"
    DB_PASS="$(openssl rand -hex 16)"
    db_running || die "$CONTAINER_MARIADB is not running — start the stack first."

    say "Creating database '$DB_NAME' + user '$DB_USER' (fresh password)"
    [ "$DRY" != 1 ] && db_provision "$DB_NAME" "$DB_USER" "$DB_PASS"

    # Point the app at the containers NOW, so migrations below can connect.
    rewrite_app_env
    ENV_REWRITTEN=1

    dump="$(db_latest_dump "$DB_NAME" || true)"
    if [ -n "$dump" ]; then
      say "Importing $(basename "$dump") (drop + recreate)"
      [ "$DRY" != 1 ] && db_import "$DB_NAME" "$dump"
      ok "Imported $DB_NAME."
    else
      warn "No dump in $DB_DUMP_DIR for '$DB_NAME' — leaving it empty."
      if [ "$DRY" != 1 ] && { [ -f "$LOCAL_DIR/artisan" ] || [ -f "$LOCAL_DIR/bin/console" ]; }; then
        say "Running migrations"
        if [ -f "$LOCAL_DIR/artisan" ]; then
          podman exec -u www-data -w "$CONTAINER_WWW/$LOCAL_NAME" "$CONTAINER_PHP_FPM" php artisan migrate --force || warn "migrate failed."
        else
          podman exec -u www-data -w "$CONTAINER_WWW/$LOCAL_NAME" "$CONTAINER_PHP_FPM" php bin/console doctrine:migrations:migrate --no-interaction || warn "migrate failed."
        fi
      fi
    fi
  fi
fi

# ---- 4. clear caches so the new connection settings take effect ------------
# Ensure the app points at the containers even when section 3 didn't run the
# rewrite (--files-only, SQLite, or a static/no-DB site).
[ "$ENV_REWRITTEN" = 1 ] || rewrite_app_env
if [ "$APP_TYPE" = "symfony" ]; then
  if [ "$DRY" != 1 ]; then
    rm -rf "$LOCAL_DIR/var/cache"/* 2>/dev/null || true
    podman exec -u www-data -w "$CONTAINER_WWW/$LOCAL_NAME" "$CONTAINER_PHP_FPM" php bin/console cache:clear >/dev/null 2>&1 || true
  fi
elif [ -f "$LOCAL_DIR/.env" ]; then
  if [ "$DRY" != 1 ]; then
    rm -f "$LOCAL_DIR"/bootstrap/cache/*.php 2>/dev/null || true
    podman exec -u www-data -w "$CONTAINER_WWW/$LOCAL_NAME" "$CONTAINER_PHP_FPM" php artisan config:clear >/dev/null 2>&1 || true
    podman exec -u www-data -w "$CONTAINER_WWW/$LOCAL_NAME" "$CONTAINER_PHP_FPM" php artisan cache:clear  >/dev/null 2>&1 || true
  fi
fi

# ---- 4b. build front-end assets if the restored output is broken ------------
# Snapshots can capture a site's Vite manifest.json and its hashed assets/
# from different builds; after a restore the manifest points at files that no
# longer exist, so CSS/JS 404 and the site looks unstyled. build-assets.sh is
# a no-op for healthy sites (and for non-Vite sites), so this is cheap.
if [ "$DO_FILES" = 1 ] && [ "$DRY" != 1 ] && [ -f "$LOCAL_DIR/package.json" ]; then
  bash "$PWD/scripts/build-assets.sh" "$LOCAL_NAME" || warn "asset build failed for $LOCAL_NAME"
fi

# ---- 5. permissions + reload ------------------------------------------------
if [ "$DO_FILES" = 1 ]; then
  run bash "$PWD/scripts/fix-perms.sh" "$LOCAL_DIR" >/dev/null \
    || warn "fix-perms failed for $LOCAL_DIR (run: sudo bash scripts/fix-perms.sh $LOCAL_DIR)"
fi
if [ "$DRY" != 1 ]; then
  podman exec "$CONTAINER_NGINX" nginx -s reload >/dev/null 2>&1 || true
fi
ok "Done: $SITE -> $LOCAL_NAME"
