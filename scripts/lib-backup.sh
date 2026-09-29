#!/usr/bin/env bash
# =============================================================================
# lib-backup.sh — off-site backup config + helpers (source, don't run).
#
#   source scripts/lib-paths.sh scripts/lib-storage.sh scripts/lib-db.sh
#   source scripts/lib-backup.sh      # after .env is loaded
#
# The off-site backup target is the "pressabl-backups" Storage Box (u676107),
# written with rsync --link-dest dated snapshots — one chain per
# source under $BACKUP_REMOTE_BASE/<name>/<YYYY-MM-DD>/.
#
# This is deliberately independent of the STORAGE_* snapshot source (u513410):
# the new server READS snapshots from u513410 but WRITES backups to u676107.
# Do not fall back to STORAGE_* here or backups would land on the old server's
# box — a missing BACKUP_HOST must be a hard error, not a silent redirect.
#
# Provides:
#   $BACKUP_ENABLED $BACKUP_USER $BACKUP_HOST $BACKUP_PORT $BACKUP_KEY
#   $BACKUP_REMOTE_BASE $BACKUP_WEEKLY_DAY $BACKUP_KEEP_DAYS $BACKUP_KEEP_MONTHLY
#   backup_ssh ...              run a command on the backup box (batch mode)
#   backup_newest_snapshot NAME newest dated snapshot dir (or empty)
#   backup_snapshot_exists NAME DATE
#   backup_prune_snapshots NAME delete dated snapshots older than KEEP_DAYS
#   db_list                     MariaDB databases to dump (excludes system ones)
#   prune_db_dumps DIR          legacy retention: last 4 weekly + first-of-month
# =============================================================================

BACKUP_ENABLED="${BACKUP_ENABLED:-1}"
BACKUP_USER="${BACKUP_USER:-}"
BACKUP_HOST="${BACKUP_HOST:-}"
BACKUP_PORT="${BACKUP_PORT:-23}"
BACKUP_REMOTE_BASE="${BACKUP_REMOTE_BASE:-/home}"
BACKUP_WEEKLY_DAY="${BACKUP_WEEKLY_DAY:-1}"
BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-}"
BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-}"

# Key: prefer BACKUP_KEY, then the storage key lib-storage resolved, then the
# admin user's standard id_ed25519 (scripts run as root, so $HOME is /root).
if [ -z "${BACKUP_KEY:-}" ]; then
  if [ -n "${STORAGE_KEY:-}" ]; then
    BACKUP_KEY="$STORAGE_KEY"
  else
    _bk_admin="${STORAGE_ADMIN_USER:-${SUDO_USER:-ryan}}"
    [ "$_bk_admin" = "root" ] && _bk_admin="ryan"
    _bk_home="$(getent passwd "$_bk_admin" 2>/dev/null | cut -d: -f6)"
    [ -n "$_bk_home" ] || _bk_home="/home/${_bk_admin:-ryan}"
    BACKUP_KEY="$_bk_home/.ssh/id_ed25519"
  fi
fi
unset _bk_admin _bk_home 2>/dev/null || true

backup_ssh() {
  ssh -n -i "$BACKUP_KEY" -p "$BACKUP_PORT" -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new "$BACKUP_USER@$BACKUP_HOST" "$@"
}

# Newest dated snapshot dir (YYYY-MM-DD) under $BACKUP_REMOTE_BASE/$name.
#
# KNOWN, ACCEPTED RISK: a run that is killed mid-rsync (OOM kill / reboot /
# kill -9 — not a normal rsync failure, which backup.sh cleans up itself)
# can leave an EMPTY or PARTIAL dated dir behind. This function cannot tell
# it apart from a complete snapshot, so it may be returned as "newest" and
# picked by `restore.sh --from-backup` (same-day re-backups are also skipped
# by backup_snapshot_exists). We accept this: restores are rare, a restore
# from a partial day fails loudly/visibly (missing files, rsync of an empty
# dir) and is easily fixed by re-running with the previous day's DATE, and
# the NEXT backup run heals the chain (its snapshot is complete regardless of
# what its --link-dest pointed at). Do NOT "fix" this with completion
# markers unless that trade-off changes.
backup_newest_snapshot() {
  local name="$1"
  { backup_ssh "ls -1 '$BACKUP_REMOTE_BASE/$name' 2>/dev/null" 2>/dev/null \
      | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort | tail -1; } || true
}

backup_snapshot_exists() {
  local name="$1" date="$2"
  # Use `ls`, not `test -d`: Hetzner Storage Boxes give a restricted shell that
  # does not provide `test` (it would always fail, so the per-day "already
  # backed up" skip would never trigger). `ls` exits 2 for a missing dir.
  backup_ssh "ls '$BACKUP_REMOTE_BASE/$name/$date'" >/dev/null 2>&1
}

# Delete dated snapshot dirs older than $BACKUP_KEEP_DAYS (no-op if unset).
# With $BACKUP_KEEP_MONTHLY > 0, first-of-month dirs are always kept.
backup_prune_snapshots() {
  local name="$1"
  [ -n "$BACKUP_KEEP_DAYS" ] || return 0
  local base="$BACKUP_REMOTE_BASE/$name" cutoff d
  cutoff="$(date -d "$BACKUP_KEEP_DAYS days ago" +%Y-%m-%d 2>/dev/null || true)"
  [ -n "$cutoff" ] || return 0
  while IFS= read -r d; do
    case "$d" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) continue ;; esac
    [ "$d" \< "$cutoff" ] || continue
    if [ "${BACKUP_KEEP_MONTHLY:-0}" -gt 0 ] 2>/dev/null; then
      case "$d" in *-01) continue ;; esac
    fi
    echo "    prune: $name/$d"
    backup_ssh "rm -rf '$base/$d'"
  done <<< "$(backup_ssh "ls -1 '$base' 2>/dev/null" 2>/dev/null)"
}

# Databases to dump: all user schemas in the running MariaDB container.
db_list() {
  printf 'SHOW DATABASES;' | db_sql -N -B 2>/dev/null \
    | grep -vE '^(information_schema|performance_schema|mysql|sys)$' \
    | grep -v '^[[:space:]]*$' || true
}

# Legacy DB-dump retention: keep the last 4 weekly dumps plus the
# first-of-month (day 01-07) dumps for every database in $dir.
prune_db_dumps() {
  local dir="$1" db all keep
  [ -d "$dir" ] || return 0
  while IFS= read -r db; do
    [ -n "$db" ] || continue
    all="$(ls -1 "$dir/$db"-????-??-??.sql.gz 2>/dev/null | sort || true)"
    [ -n "$all" ] || continue
    keep="$( { printf '%s\n' "$all" | tail -n 4
              printf '%s\n' "$all" | grep -E "/$db-[0-9]{4}-[0-9]{2}-0[1-7]\.sql\.gz"
            } | sort -u || true )"
    comm -23 <(printf '%s\n' "$all") <(printf '%s\n' "$keep") | while IFS= read -r f; do
      [ -n "$f" ] || continue
      echo "    prune: ${f##*/}"
      rm -f "$f"
    done
  done < <(ls -1 "$dir"/*.sql.gz 2>/dev/null \
             | sed -E 's#^.*/##; s#-[0-9]{4}-[0-9]{2}-[0-9]{2}\.sql\.gz$##' | sort -u)
}
