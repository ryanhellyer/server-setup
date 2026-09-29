#!/usr/bin/env bash
# =============================================================================
# backup.sh — off-site backup to the "pressabl-backups" Hetzner Storage Box.
#
#   sudo bash scripts/backup.sh [--dry-run] [--db-only|--files-only] [--force]
#
# For each source below, rsyncs a dated, hardlinked snapshot (--link-dest) to
# the storage box, once per day (skip a source if today's dir already exists):
#
#   ~/www          -> $BACKUP_REMOTE_BASE/www
#   ~/tools        -> $BACKUP_REMOTE_BASE/tools
#   ~/mariadbs     -> $BACKUP_REMOTE_BASE/mariadbs   (MySQL dumps written here)
#   ~/gmail        -> $BACKUP_REMOTE_BASE/gmail
#   ~/server-setup -> $BACKUP_REMOTE_BASE/server-setup
#
# MySQL: one gzipped dump per database into ~/mariadbs. Dumps run on
# $BACKUP_WEEKLY_DAY (default Monday) with the legacy retention (last 4 weekly +
# first-of-month); `--force` dumps on any day. File snapshots run every time.
#
# Scheduled daily by scripts/install-systemd.sh (server-backup.timer); set
# BACKUP_ENABLED=0 in .env to disable. See BACKUP_PLAN.md.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-storage.sh
source scripts/lib-db.sh
source scripts/lib-backup.sh

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

DO_FILES=1; DO_DB=1; DRY=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY=1; shift ;;
    --files-only) DO_DB=0; shift ;;
    --db-only)    DO_FILES=0; shift ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[ "$BACKUP_ENABLED" = "1" ] || { say "BACKUP_ENABLED=$BACKUP_ENABLED — backups disabled."; exit 0; }
[ -n "$BACKUP_USER" ] && [ -n "$BACKUP_HOST" ] \
  || die "BACKUP_USER / BACKUP_HOST are not set (see .env / .env.example)."

run() { if [ "$DRY" = 1 ]; then printf '    DRY: %s\n' "$*"; else "$@"; fi; }

LOG_DIR=/var/log/server-setup
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/backup.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG" 2>/dev/null || true; }

# Single-instance lock (a slow run must not overlap the next).
LOCK=/run/server-setup-backup.lock
[ -w /run ] 2>/dev/null || LOCK=/tmp/server-setup-backup.lock
exec 9>"$LOCK"
if ! flock -n 9; then
  log "another backup is already running — exiting."
  exit 0
fi

DATE="$(date +%Y-%m-%d)"
ADMIN_USER="$(resolve_admin_user)"
ADMIN_GROUP="$(id -gn "$ADMIN_USER" 2>/dev/null || id -gn)"
SRC_WWW="$(resolve_www_root)"
SRC_TOOLS="$(resolve_tools_root)"
SRC_MARIADBS="$DB_DUMP_DIR"
SRC_GMAIL="${GMAIL_MAILDIR:-$(resolve_admin_home)/gmail}"
SRC_REPO="${SERVER_SETUP_ROOT:-$PWD}"

DRY_LABEL=""; [ "$DRY" = 1 ] && DRY_LABEL=", dry-run"
log "=== backup started (date $DATE$DRY_LABEL) ==="

# ---- 1. MySQL dumps ---------------------------------------------------------
if [ "$DO_DB" = 1 ]; then
  DOW="$(date +%u)"
  if [ "$FORCE" = 1 ] || [ "$DO_FILES" = 0 ] || [ "$DOW" = "$BACKUP_WEEKLY_DAY" ]; then
    if ! db_running; then
      warn "mariadb (${CONTAINER_MARIADB}) is not running — skipping DB dumps."
    else
      log "dumping databases -> $SRC_MARIADBS"
      run install -d -m 775 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$SRC_MARIADBS"
      for db in $(db_list); do
        [ -n "$db" ] || continue
        if [ "$DRY" = 1 ]; then
          printf '    DRY: mariadb-dump %s -> %s/%s-%s.sql.gz\n' "$db" "$SRC_MARIADBS" "$db" "$DATE"
          continue
        fi
        if podman exec "$CONTAINER_MARIADB" sh -c \
             'exec mariadb-dump --single-transaction --quick -uroot -p"$MARIADB_ROOT_PASSWORD" "$1"' _ "$db" \
             | gzip > "$SRC_MARIADBS/$db-$DATE.sql.gz"; then
          chown "$ADMIN_USER:$ADMIN_GROUP" "$SRC_MARIADBS/$db-$DATE.sql.gz" 2>/dev/null || true
          log "  dumped $db"
        else
          warn "dump failed for $db"
          rm -f "$SRC_MARIADBS/$db-$DATE.sql.gz"
        fi
      done
      if [ "$DRY" != 1 ]; then
        prune_db_dumps "$SRC_MARIADBS" | while IFS= read -r line; do log "$line"; done
      fi
    fi
  else
    log "not the DB backup day ($DOW != $BACKUP_WEEKLY_DAY) — skipping DB dumps."
  fi
fi

# ---- 2. file snapshots ------------------------------------------------------
snapshot() { # local_dir  remote_name
  local src="$1" name="$2"
  if [ ! -d "$src" ]; then warn "$name: source '$src' missing — skipped"; return 0; fi
  local base dest
  base="$BACKUP_REMOTE_BASE/$name"; dest="$base/$DATE"
  if backup_snapshot_exists "$name" "$DATE"; then
    log "$name: $DATE already backed up — skipped"
    return 0
  fi
  local prev link=()
  prev="$(backup_newest_snapshot "$name")"
  [ -n "$prev" ] && link=(--link-dest="$base/$prev")
  log "snapshot: $src -> $BACKUP_USER@$BACKUP_HOST:$dest${prev:+  (link-dest $prev)}"
  run backup_ssh "mkdir -p '$dest'" || { warn "$name: could not create $dest"; return 1; }
  if ! run rsync -az --delete "${link[@]}" \
      --no-p --no-g --no-o --omit-dir-times \
      --exclude='.Trash*' --exclude='.cache' --exclude='lost+found' \
      -e "ssh -i $BACKUP_KEY -p $BACKUP_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
      "$src/" "$BACKUP_USER@$BACKUP_HOST:$dest/"; then
    warn "$name: rsync failed — removing the partial snapshot $DATE so it is"
    warn "never treated as a complete backup (retry: sudo bash scripts/backup.sh)"
    run backup_ssh "rm -rf '$dest'"
    return 1
  fi
  backup_prune_snapshots "$name"
}

if [ "$DO_FILES" = 1 ]; then
  snapshot "$SRC_WWW"      www         || warn "backup of www failed"
  snapshot "$SRC_TOOLS"    tools       || warn "backup of tools failed"
  snapshot "$SRC_MARIADBS" mariadbs    || warn "backup of mariadbs failed"
  snapshot "$SRC_GMAIL"    gmail       || warn "backup of gmail failed"
  snapshot "$SRC_REPO"     server-setup || warn "backup of server-setup failed"
fi

log "=== backup finished ==="
