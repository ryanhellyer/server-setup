#!/usr/bin/env bash
# =============================================================================
# laravel-scheduler.sh — run `artisan schedule:run` for each Laravel site.
#
#   sudo bash scripts/laravel-scheduler.sh
#
# Laravel's scheduler must be ticked every minute from outside the app (via
# cron or a timer); the apps themselves have no background daemon. Each site is
# executed inside the php-fpm container as www-data, in the site's own
# directory, so it uses the container's PHP + the site's real DB/cache config.
#
# Sites come from .env (space-separated), defaulting to the sites that had a
# per-minute scheduler on the legacy server:
#   LARAVEL_SCHEDULER_SITES="spam-destroyer.com kartastrophecup.de"
# Set LARAVEL_SCHEDULER_SITES="" (empty) to disable the job entirely.
#
# Scheduled every minute by scripts/install-systemd.sh (server-scheduler.timer).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-storage.sh
WWW_ROOT="$(resolve_www_root)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }

# Default keeps the legacy behaviour (same two sites as the old crontab).
SITES="${LARAVEL_SCHEDULER_SITES-spam-destroyer.com kartastrophecup.de}"
[ -n "$SITES" ] || { say "LARAVEL_SCHEDULER_SITES is empty — scheduler disabled."; exit 0; }

LOG_DIR=/var/log/server-setup
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/scheduler.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true; }

# The stack must be up or every exec below fails; fail loudly into the log.
podman container exists "$CONTAINER_PHP_FPM" 2>/dev/null \
  || { warn "$CONTAINER_PHP_FPM container is not running — skipping."; log "php-fpm not running; skipped"; exit 0; }

FAILED=0
for site in $SITES; do
  # A site may be listed under its snapshot name but live in a renamed local
  # dir (SNAPSHOT_RENAMES, e.g. spam-destroyer.com=spam-destroyer.hellyer.kiwi).
  local_name="$(apply_rename "$site")"
  if [ -f "$WWW_ROOT/$local_name/artisan" ]; then
    dir="$local_name"
  elif [ -f "$WWW_ROOT/$site/artisan" ]; then
    dir="$site"
  else
    warn "$site: no artisan (not a Laravel app) — skipping."
    log "$site: no artisan — skipping"
    continue
  fi
  say "schedule:run -> $dir"
  if podman exec -u www-data -w "$CONTAINER_WWW/$dir" "$CONTAINER_PHP_FPM" \
       php artisan schedule:run >>"$LOG" 2>&1; then
    :
  else
    warn "$dir: artisan schedule:run exited non-zero (see $LOG)."
    log "$dir: artisan schedule:run FAILED"
    FAILED=1
  fi
done

[ "$FAILED" = 1 ] && exit 1
exit 0
