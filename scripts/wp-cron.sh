#!/usr/bin/env bash
# =============================================================================
# wp-cron.sh — run due WP-Cron events across the Pressabl WordPress multisite.
#
#   sudo bash scripts/wp-cron.sh
#
# WordPress's own wp-cron.php only fires on page loads, which is unreliable for
# low-traffic sites and misses events entirely when a site is idle. This is the
# catch-up runner: it lists every site in the multisite and runs all events that
# are due now (`wp cron event run --due-now`), like the legacy server's
# /var/www/wp-cron.sh did.
#
# Runs inside the php-fpm container as www-data so it uses the container's PHP
# and the site's real DB/cache config.
#
# Config (from .env):
#   WP_CRON_PATH   path to the multisite web root, as seen INSIDE the container
#                  (default: /var/www/pressabl/public_html)
#
# Scheduled every 10 minutes by scripts/install-systemd.sh (server-wpcron.timer).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }

WP_PATH="${WP_CRON_PATH:-$CONTAINER_WWW/pressabl/public_html}"
WWW_ROOT="$(resolve_www_root)"

LOG_DIR=/var/log/server-setup
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/wpcron.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

podman container exists "$CONTAINER_PHP_FPM" 2>/dev/null \
  || { warn "$CONTAINER_PHP_FPM container is not running — skipping."; log "php-fpm not running; skipped"; exit 0; }

# Translate the container path back to the host to verify it exists.
HOST_PATH="$(www_host_path "$WP_PATH")"
if [ ! -d "$HOST_PATH" ]; then
  warn "WordPress path not found: $HOST_PATH — skipping."
  log "path not found: $HOST_PATH; skipped"
  exit 0
fi

say "Listing sites in $WP_PATH"
# WP-CLI and WP core emit a lot of harmless noise under PHP 8.5 (missing
# HTTP_HOST warnings when run outside a request, and deprecation notices from
# WP-CLI's bundled libs / WP core). It cannot be silenced via php.ini flags
# because WP-CLI resets them, so filter it out of the log. Real problems are
# still detected from the command's EXIT STATUS (see below).
NOISE='Undefined array key "HTTP_HOST"|Using null as an array offset is deprecated'
SITES="$(podman exec -u www-data -w "$WP_PATH" "$CONTAINER_PHP_FPM" \
  wp site list --fields=url --format=csv --path="$WP_PATH" 2>&1 \
  | grep -vE "$NOISE" | tail -n +2 || true)"

if [ -z "$SITES" ]; then
  warn "No sites listed — see $LOG."
  log "no sites listed"
  exit 1
fi

FAILED=0
COUNT=0
while IFS= read -r url; do
  case "$url" in
    http*) ;;
    *) continue ;;
  esac
  COUNT=$((COUNT + 1))
  # Only run events that are due now. WP-CLI rejects "--all --due-now" together
  # on newer versions, so pass --due-now alone (it still covers every hook).
  # Filter the harmless noise from what reaches the log, but judge success by
  # the command's own exit status. `set -e`/pipefail would abort on a failing
  # pipeline, so capture the status explicitly with `|| rc=$?` (PIPESTATUS[0]
  # is the podman/wp exit code, not grep's).
  rc=0
  podman exec -u www-data -w "$WP_PATH" "$CONTAINER_PHP_FPM" \
    wp cron event run --due-now --url="$url" --path="$WP_PATH" 2>&1 \
    | grep -vE "$NOISE" >>"$LOG" || rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    :
  else
    warn "cron events failed for $url (see $LOG)."
    log "cron events FAILED for $url (exit $rc)"
    FAILED=1
  fi
done <<< "$SITES"

say "Ran due events for $COUNT site(s)."
[ "$FAILED" = 1 ] && exit 1
exit 0
