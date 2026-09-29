#!/usr/bin/env bash
# =============================================================================
# lib-paths.sh — resolve where the SITE FILES live on the host.
#
# Sites live under the admin user's home (default ~/www) instead of /var/www,
# so they sit on the persistent home partition and survive a move to an atomic
# / immutable distro (e.g. Fedora Silverblue) where /var is best left to the OS.
#
# The containers still see the same files at /var/www: compose.yaml mounts
#   ${WWW_ROOT:-/home/ryan/www}:/var/www
# so the nginx config (nginx/conf.d/*.conf) and the container images are
# UNCHANGED — they keep referring to /var/www. Only host-side scripts care
# about the real location.
#
#   source scripts/lib-paths.sh
#   WWW_ROOT="$(resolve_www_root)"     # call AFTER .env is loaded
#
# Override the location with WWW_ROOT in .env.
# =============================================================================

# Path as seen INSIDE the containers. Must match compose.yaml's mount target and
# the roots referenced by nginx/conf.d. Do not change without editing those.
CONTAINER_WWW="/var/www"
# Per-site nginx logs live OUTSIDE the web roots (so they are never part of a
# site backup or snapshot). compose.yaml mounts $LOG_ROOT here.
CONTAINER_LOG="/var/log/sites"

# Print the admin user (the account whose home holds the site files). Resolved
# from $SUDO_USER, then ryan, then the current user.
resolve_admin_user() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    printf '%s' "$SUDO_USER"; return 0
  fi
  if id ryan >/dev/null 2>&1; then printf '%s' "ryan"; return 0; fi
  id -un
}

# Print the admin user's home directory.
resolve_admin_home() {
  local home
  home="$(getent passwd "$(resolve_admin_user)" 2>/dev/null | cut -d: -f6)"
  [ -n "$home" ] || home="${HOME:-/root}"
  printf '%s' "$home"
}

# Print the host web root. Precedence: $WWW_ROOT (from .env) > the admin user's
# home (~/www).
resolve_www_root() {
  if [ -n "${WWW_ROOT:-}" ]; then printf '%s' "$WWW_ROOT"; return 0; fi
  printf '%s' "$(resolve_admin_home)/www"
}

# Print the host log root — per-site nginx logs, kept OUTSIDE the web roots so
# they are not swept into site backups/snapshots. Precedence: $LOG_ROOT (from
# .env) > the admin user's home (~/logs).
resolve_log_root() {
  if [ -n "${LOG_ROOT:-}" ]; then printf '%s' "$LOG_ROOT"; return 0; fi
  printf '%s' "$(resolve_admin_home)/logs"
}

# Print the host tools root — everything from the storage snapshot that is NOT a
# website (backup scripts, configs, cron, misc data). Precedence: $TOOLS_ROOT
# (from .env) > the admin user's home (~/tools).
resolve_tools_root() {
  if [ -n "${TOOLS_ROOT:-}" ]; then printf '%s' "$TOOLS_ROOT"; return 0; fi
  printf '%s' "$(resolve_admin_home)/tools"
}

# Print the local MySQL-dump root — the dumps the backup system writes and
# syncs. Precedence: $MARIADBS_ROOT (from .env) > the admin user's home
# (~/mariadbs). (DB_DUMP_DIR in lib-storage.sh defaults to this.)
resolve_mariadbs_root() {
  if [ -n "${MARIADBS_ROOT:-}" ]; then printf '%s' "$MARIADBS_ROOT"; return 0; fi
  printf '%s' "$(resolve_admin_home)/mariadbs"
}

# Map a container path (/var/www[/...] or /var/log/sites[/...]) to its host
# location ($WWW_ROOT[...] / $LOG_ROOT[...]). Other paths are returned unchanged.
www_host_path() {
  local p="$1"
  case "$p" in
    "$CONTAINER_WWW")   printf '%s' "${WWW_ROOT:-$(resolve_www_root)}" ;;
    "$CONTAINER_WWW"/*) printf '%s/%s' "${WWW_ROOT:-$(resolve_www_root)}" "${p#"$CONTAINER_WWW"/}" ;;
    "$CONTAINER_LOG")   printf '%s' "${LOG_ROOT:-$(resolve_log_root)}" ;;
    "$CONTAINER_LOG"/*) printf '%s/%s' "${LOG_ROOT:-$(resolve_log_root)}" "${p#"$CONTAINER_LOG"/}" ;;
    *)                  printf '%s' "$p" ;;
  esac
}
