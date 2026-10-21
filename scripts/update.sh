#!/usr/bin/env bash
# =============================================================================
# update.sh — refresh the stack (images + container OS packages) in place.
#
#   sudo bash scripts/update.sh
#
# Safe by design: it never re-provisions sites/DBs, so live data is untouched.
# Menu option 5 (install/setup.sh) and `bootstrap.sh --update` both call this.
#
# What it does:
#   1. refreshes the systemd units, so the supervisor knows how to recreate
#      containers (`--force-recreate`) and the weekly job has a long timeout;
#   2. pulls the upstream images (mariadb / valkey / open-webui / goatcounter /
#      syncthing / authelia / certbot) AND the base images used by the local
#      builds (ubuntu:24.04, node:22-slim) by their tags;
#   3. re-renders the configs from their .template files (a file update may
#      have changed them);
#   4. rebuilds the locally-built images (php / nginx / node / mailrelay) with
#      --no-cache. This is deliberate: `compose up --build` reuses the cached
#      `apt-get` layer, so container OS/PHP patch updates were silently
#      skipped. It also means trailing-edge packages (e.g. PHP 8.5.x) are
#      actually installed;
#   5. recreates the containers whose images changed. podman-compose compares
#      image *tags*, not image IDs, so `up -d` alone leaves old containers
#      running after a rebuild. The supervisor's ExecReload now passes
#      --force-recreate; a self-heal pass removes any container still on an
#      old image (and its dependents, e.g. nginx -> php-fpm) and reloads;
#   6. checks every expected container is running and logs the live PHP
#      version, then prunes the old layers.
#
# The recreate goes through `systemctl reload server-stack.service` (not a bare
# `compose up`) because this script also runs as a Type=oneshot timer job:
# systemd tears a oneshot's cgroup down on exit, which would kill the freshly
# created containers (notably nginx, taking the site offline). If the
# supervisor is not active (manual run on a legacy/non-systemd box) it falls
# back to a direct `compose up`.
#
# It deliberately does NOT run deploy.sh / provision-all.sh: those re-import
# sites + databases from the storage snapshots and would overwrite live data.
#
# Scheduled weekly by scripts/install-systemd.sh (server-update.timer).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo bash scripts/update.sh)."; exit 1; }

source scripts/lib-containers.sh

# Prefer `podman compose`, fall back to `podman-compose` (same as deploy.sh).
if podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
else
  COMPOSE=(podman-compose)
fi

LOG_DIR=/var/log/server-setup
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/update.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

log "=== update started ==="

# ---- 0. refresh the systemd units ------------------------------------------
# ExecReload must include --force-recreate, and server-update.service needs a
# timeout long enough for a no-cache rebuild. Re-running the installer is
# idempotent; a failure is logged and we carry on (the self-heal below still
# recovers stale containers).
if command -v systemctl >/dev/null 2>&1 && [ -x scripts/install-systemd.sh ]; then
  log "refreshing systemd units"
  bash scripts/install-systemd.sh >>"$LOG" 2>&1 \
    || log "  !! systemd unit refresh failed (continuing)"
fi
# Keep the SSH login banner in sync with the (possibly new) scripts. Cheap and
# idempotent; a failure is not worth aborting an update.
if [ -x scripts/install-login-help.sh ]; then
  bash scripts/install-login-help.sh >>"$LOG" 2>&1 \
    || log "  !! login banner refresh failed (continuing)"
fi

# ---- 1. upstream + base images (floating tags -> latest) ----
UPSTREAM=(
  docker.io/mariadb:11
  docker.io/valkey/valkey:8-alpine
  ghcr.io/open-webui/open-webui:main
  docker.io/arp242/goatcounter:2.7
  docker.io/syncthing/syncthing:2.1.6
  docker.io/authelia/authelia:4.39
  docker.io/certbot/certbot:latest
  # bases for the locally-built images
  docker.io/ubuntu:24.04
  docker.io/node:22-slim
)
for img in "${UPSTREAM[@]}"; do
  log "pulling $img"
  podman pull "$img" >>"$LOG" 2>&1 || log "  !! pull failed for $img (continuing)"
done

# ---- 2. re-render configs from the templates ----
# A file refresh may have changed nginx/fpm/my.cnf templates; render before
# rebuilding so nginx and FPM never disagree (e.g. about the socket path).
log "rendering configs"
bash scripts/render-config.sh >>"$LOG" 2>&1 \
  || log "  !! render-config.sh failed — check the templates and .env"

# ---- 3. rebuild local images without the layer cache ----
log "building local images (--no-cache: re-runs apt)"
if ! "${COMPOSE[@]}" build --no-cache >>"$LOG" 2>&1; then
  log "  !! build failed — see $LOG. Stack left as-is."
  log "=== update aborted ==="
  exit 1
fi

# ---- 4. recreate the stack through the supervisor ----
# ExecReload is `up -d --build --force-recreate`, so every container is
# recreated from the image it now points at. A restart is the fallback (down +
# up recreates from scratch and keeps the containers in the unit's cgroup).
log "recreating the stack"
if systemctl is-active --quiet server-stack.service 2>/dev/null; then
  systemctl reload server-stack.service >>"$LOG" 2>&1 \
    || { log "  !! reload failed — restarting the supervisor"; \
         systemctl restart server-stack.service >>"$LOG" 2>&1 \
           || log "  !! restart failed too — see $LOG"; }
else
  "${COMPOSE[@]}" up -d --force-recreate >>"$LOG" 2>&1 \
    || log "  !! compose up failed — see $LOG"
fi

# ---- 4b. self-heal: any container still running an old image? ----
# Covers an installed unit that predates the --force-recreate change (the
# refresh above normally fixes that) and providers that ignore it.
stale_images() {
  local c img cur new
  for c in "${ALL_CONTAINERS[@]}"; do
    podman container exists "$c" 2>/dev/null || continue
    img="$(podman inspect -f '{{.ImageName}}' "$c" 2>/dev/null || true)"
    cur="$(podman inspect -f '{{.Image}}' "$c" 2>/dev/null || true)"
    [ -n "$img" ] && [ "$img" != "<none>" ] || continue
    new="$(podman image inspect -f '{{.Id}}' "$img" 2>/dev/null || true)"
    [ -n "$new" ] || continue
    [ "$cur" = "$new" ] || printf '%s\n' "$c"
  done
  return 0
}

stale="$(stale_images)"
if [ -n "$stale" ]; then
  log "  containers on old images: $(printf '%s ' $stale)"
  for c in $stale; do
    podman container exists "$c" 2>/dev/null || continue
    # --depend also removes containers that require this one (nginx -> php-fpm).
    podman rm -f --depend "$c" >>"$LOG" 2>&1 || log "  !! could not remove $c"
  done
  if systemctl is-active --quiet server-stack.service 2>/dev/null; then
    systemctl reload server-stack.service >>"$LOG" 2>&1 \
      || systemctl restart server-stack.service >>"$LOG" 2>&1 \
      || log "  !! recovery reload failed"
  else
    "${COMPOSE[@]}" up -d >>"$LOG" 2>&1 || log "  !! recovery compose up failed"
  fi
fi

# ---- 5. health check: every expected container running? ----
down=()
for c in "${ALL_CONTAINERS[@]}"; do
  [ "$(podman inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] || down+=("$c")
done
if [ "${#down[@]}" -gt 0 ]; then
  log "  !! not running: ${down[*]} — recovering via the supervisor"
  if systemctl is-active --quiet server-stack.service 2>/dev/null; then
    systemctl reload server-stack.service >>"$LOG" 2>&1 || log "  !! recovery reload failed"
  else
    "${COMPOSE[@]}" up -d >>"$LOG" 2>&1 || log "  !! recovery compose up failed"
  fi
fi

# ---- 6. report + prune ----
if podman container exists php-fpm 2>/dev/null; then
  log "php-fpm reports: $(podman exec php-fpm php -r 'echo PHP_VERSION;' 2>/dev/null || echo unknown)"
fi
podman image prune -f >>"$LOG" 2>&1 || true

log "=== update finished ==="
