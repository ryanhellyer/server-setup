#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore site files and databases from backups.
#
#   sudo bash scripts/restore.sh
#       Legacy local restore: the newest mysql-all-*.sql.gz + www-*.tar.gz in
#       $BACKUP_DIR (default /var/databases), as written by the old backup.sh.
#
#   sudo bash scripts/restore.sh --from-backup [DATE] [SOURCE...]
#       Restore from the off-site storage-box snapshot chains under
#       $BACKUP_REMOTE_BASE/<name>/<YYYY-MM-DD>/.
#         SOURCE = www | tools | mariadbs | gmail | server-setup | all
#                  (default: all = www tools mariadbs server-setup)
#         DATE   = snapshot date (default: newest available for the sources)
#       Restores mariadbs first-class: after the files, each <db>-<DATE>.sql.gz
#       is imported (drop + recreate) via lib-db.sh.
#
# See BACKUP_PLAN.md.
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

FROM_BACKUP=0; DATE=""; SOURCES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --from-backup) FROM_BACKUP=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) DATE="$1"; shift ;;
    www|tools|mariadbs|gmail|server-setup|all) SOURCES+=("$1"); shift ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "Run as root (sudo bash scripts/restore.sh)."

# =============================================================================
# Legacy local restore (no --from-backup)
# =============================================================================
if [ "$FROM_BACKUP" != 1 ]; then
  WWW_ROOT="$(resolve_www_root)"
  BACKUP_DIR="${BACKUP_DIR:-/var/databases}"
  DB_DUMP="$(ls -1t "$BACKUP_DIR"/mysql-all-*.sql.gz 2>/dev/null | head -1 || true)"
  WWW_ARCHIVE="$(ls -1t "$BACKUP_DIR"/www-*.tar.gz 2>/dev/null | head -1 || true)"

  [ -n "$DB_DUMP" ] || [ -n "$WWW_ARCHIVE" ] || {
    echo "No legacy backups found in $BACKUP_DIR — nothing to restore."
    echo "To restore from the off-site backups: sudo bash scripts/restore.sh --from-backup"
    exit 0
  }

  if [ -n "$DB_DUMP" ]; then
    podman ps --format '{{.Names}}' | grep -q "^$CONTAINER_MARIADB$" \
      || die "$CONTAINER_MARIADB container not running — start the stack first."
    echo "==> Restoring databases from: $DB_DUMP"
    gunzip -c "$DB_DUMP" | podman exec -i "$CONTAINER_MARIADB" sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
  fi
  if [ -n "$WWW_ARCHIVE" ]; then
    echo "==> Restoring site files under $WWW_ROOT from: $WWW_ARCHIVE"
    tar xzf "$WWW_ARCHIVE" -C /
  fi
  echo
  echo "Restore complete."
  echo "Next: sudo ./scripts/deploy.sh (to rebuild + reload nginx against the data)."
  exit 0
fi

# =============================================================================
# Off-site restore (--from-backup)
# =============================================================================
[ -n "$BACKUP_USER" ] && [ -n "$BACKUP_HOST" ] \
  || die "BACKUP_USER / BACKUP_HOST are not set (see .env / .env.example)."

# Expand "all" (gmail is deliberately NOT part of all — it can lose mail).
EXPANDED=()
[ "${#SOURCES[@]}" -gt 0 ] || SOURCES=(all)
for s in "${SOURCES[@]}"; do
  if [ "$s" = "all" ]; then EXPANDED+=(www tools mariadbs server-setup); else EXPANDED+=("$s"); fi
done

local_dir_for() {
  case "$1" in
    www)          resolve_www_root ;;
    tools)        resolve_tools_root ;;
    mariadbs)     printf '%s' "$DB_DUMP_DIR" ;;
    gmail)        printf '%s' "${GMAIL_MAILDIR:-$(resolve_admin_home)/gmail}" ;;
    server-setup) printf '%s' "${SERVER_SETUP_ROOT:-$PWD}" ;;
  esac
}

# Pick the newest snapshot date across the chosen sources (unless given).
# NOTE: an empty/partial dir left by a killed backup run looks like a valid
# snapshot here — see the accepted-risk note on backup_newest_snapshot()
# (lib-backup.sh). If the newest date restores nothing, retry with the
# previous day's DATE.
if [ -z "$DATE" ]; then
  for s in "${EXPANDED[@]}"; do
    d="$(backup_newest_snapshot "$s")"
    [ -n "$d" ] || continue
    if [ -z "$DATE" ] || [[ "$d" > "$DATE" ]]; then DATE="$d"; fi
  done
fi
[ -n "$DATE" ] || die "No snapshots found on $BACKUP_HOST for: ${EXPANDED[*]}"
say "Restoring date: $DATE  (${EXPANDED[*]})"

SSH_E="ssh -i $BACKUP_KEY -p $BACKUP_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

ADMIN_USER="$(resolve_admin_user)"
ADMIN_GROUP="$(id -gn "$ADMIN_USER" 2>/dev/null || id -gn)"

needs_db=0
for name in "${EXPANDED[@]}"; do
  dir="$(local_dir_for "$name")"
  base="$BACKUP_REMOTE_BASE/$name"
  if ! backup_snapshot_exists "$name" "$DATE"; then
    warn "$name: no snapshot for $DATE — skipped"
    continue
  fi
  say "Restore $name -> $dir"
  # ~/mariadbs and ~/gmail are usually sshfs mounts of the PRIMARY storage box
  # (storage-mounts.sh). --delete therefore propagates to that box: restoring
  # an OLDER date deletes dumps/mail newer than $DATE on it. Make that loud.
  if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$dir" 2>/dev/null; then
    warn "$name: '$dir' is a MOUNT — --delete will remove anything newer than"
    warn "$name: $DATE on the box behind it. This cannot be undone."
  fi
  install -d "$dir"
  if [ "$name" = "server-setup" ]; then
    # Merge rather than --delete: the repo contains this running script.
    warn "server-setup: merging (no --delete) so the running repo isn't removed"
    rsync -az --no-o --no-g -e "$SSH_E" "$BACKUP_USER@$BACKUP_HOST:$base/$DATE/" "$dir/"
  else
    rsync -az --delete --no-o --no-g -e "$SSH_E" "$BACKUP_USER@$BACKUP_HOST:$base/$DATE/" "$dir/"
  fi
  case "$name" in
    www|tools)    bash "$PWD/scripts/fix-perms.sh" "$dir" >/dev/null 2>&1 || true ;;
    mariadbs|gmail|server-setup) chown -R "$ADMIN_USER:$ADMIN_GROUP" "$dir" 2>/dev/null || true ;;
  esac
  [ "$name" = "mariadbs" ] && needs_db=1
done

if [ "$needs_db" = 1 ]; then
  MARIADBS_DIR="$DB_DUMP_DIR"
  if ! podman ps --format '{{.Names}}' | grep -q "^$CONTAINER_MARIADB$"; then
    warn "$CONTAINER_MARIADB not running — dumped databases are NOT imported."
  else
    say "Importing databases from dumps dated $DATE"
    for dump in "$MARIADBS_DIR"/*-"$DATE".sql.gz; do
      [ -e "$dump" ] || continue
      db="${dump##*/}"; db="${dump%-"$DATE".sql.gz}"
      case "$db" in *[!A-Za-z0-9_]*) warn "skipping '${dump##*/}' (unexpected name)"; continue ;; esac
      if db_import "$db" "$dump"; then say "  imported $db"; else warn "  import failed for $db"; fi
    done
  fi
fi

echo
echo "Restore complete."
echo "Next: sudo ./scripts/deploy.sh (rebuild + reload nginx against the data)."
