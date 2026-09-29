#!/usr/bin/env bash
# =============================================================================
# lib-db.sh — MariaDB helpers (source, don't run).
#
#   source scripts/lib-db.sh
#
# Requires $CONTAINER_MARIADB (from lib-containers.sh) and, in the environment,
# $MARIADB_ROOT_PASSWORD (from .env). Every site gets its OWN user (named after
# its database) with a unique password and a least-privilege grant.
#
#   db_running                 is the mariadb container up?
#   db_sql [flags]             run mariadb (SQL on stdin)
#   db_has_tables DB           number of tables in DB (0 if absent)
#   db_provision DB USER PASS  create DB + user + least-privilege grant
#   db_import DB DUMP          drop/recreate DB and import DUMP (strips DEFINERs)
# =============================================================================

db_running() {
  local _ s
  for _ in 1 2 3 4 5; do
    s="$(podman inspect -f '{{.State.Running}}' "$CONTAINER_MARIADB" 2>/dev/null || true)"
    [ "$s" = "true" ] && return 0
    sleep 0.5
  done
  return 1
}

db_sql() { # extra mariadb flags; SQL on stdin
  podman exec -i "$CONTAINER_MARIADB" sh -c "exec mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" $*"
}

db_has_tables() { # DB
  local n
  n="$(printf "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='%s';" "$1" | db_sql -N -B 2>/dev/null || true)"
  printf '%s' "${n:-0}"
}

db_provision() { # DB USER PASS
  local db="$1" user="$2" pass="$3"
  case "$db"   in *[!A-Za-z0-9_]*) echo "Unsafe DB name: $db"   >&2; return 1 ;; esac
  case "$user" in *[!A-Za-z0-9_]*) echo "Unsafe DB user: $user" >&2; return 1 ;; esac
  local p="${pass//\'/\'\'}"
  {
    printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "$db"
    printf "CREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s';\n" "$user" "$p"
    printf "ALTER USER '%s'@'%%' IDENTIFIED BY '%s';\n" "$user" "$p"
    printf "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, INDEX, DROP, REFERENCES ON \`%s\`.* TO '%s'@'%%';\n" "$db" "$user"
    printf 'FLUSH PRIVILEGES;\n'
  } | db_sql
}

db_import() { # DB DUMP  (fresh: drop + recreate + import)
  local db="$1" dump="$2"
  case "$db" in *[!A-Za-z0-9_]*) echo "Unsafe DB name: $db" >&2; return 1 ;; esac
  printf 'DROP DATABASE IF EXISTS `%s`; CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' \
    "$db" "$db" | db_sql
  # Strip DEFINER=`user`@`host` so views/triggers don't depend on the old user.
  zcat "$dump" \
    | sed -E 's/DEFINER=`[^`]*`@`[^`]*`//g; s/DEFINER="[^"]*"@`[^`]*`//g' \
    | podman exec -i "$CONTAINER_MARIADB" sh -c "exec mariadb -uroot -p\"\$MARIADB_ROOT_PASSWORD\" '$db'"
}

# Newest DB dump for a database in $DB_DUMP_DIR (or empty).
db_latest_dump() { # DB
  ls -1 "$DB_DUMP_DIR/$1"-*.sql.gz 2>/dev/null | sort | tail -1
}
