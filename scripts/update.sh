#!/usr/bin/env bash
# =============================================================================
# update.sh — refresh the stack (images + container OS packages) in place.
#
#   sudo bash scripts/update.sh
#
# What it does:
#   1. pulls the upstream images (mariadb / valkey / open-webui / goatcounter /
#      authelia / certbot) by their tags — a floating tag resolves to the
#      newest image;
#   2. rebuilds the locally-built images (php / nginx / node) from their
#      Containerfiles. The build re-runs `apt-get update && install`, so the
#      Ubuntu 24.04 packages inside those images get their latest updates;
#   3. recreates any containers whose image changed;
#   4. prunes the old image layers.
#
# The recreate is done by reloading `server-stack.service` (whose persistent
# cgroup supervises the stack), NOT by running `compose up` here: this script
# runs as a Type=oneshot timer job, and systemd tears a oneshot's cgroup down
# on exit — which would kill the freshly (re)created containers (notably nginx,
# taking the whole site offline). If the supervisor isn't active (manual run on
# a non-systemd/legacy box) it falls back to a direct `compose up`.
#
# It deliberately does NOT run deploy.sh / provision-all.sh: those re-import
# sites + databases from the storage snapshots and would overwrite live data.
#
# Scheduled weekly by scripts/install-systemd.sh (server-update.timer).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo bash scripts/update.sh)."; exit 1; }

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

# ---- 1. upstream images (floating tags -> latest) ----
UPSTREAM=(
  docker.io/mariadb:11
  docker.io/valkey/valkey:8-alpine
  ghcr.io/open-webui/open-webui:main
  docker.io/arp242/goatcounter:2.7
  docker.io/authelia/authelia:4.39
  docker.io/certbot/certbot:latest
)
for img in "${UPSTREAM[@]}"; do
  log "pulling $img"
  podman pull "$img" >>"$LOG" 2>&1 || log "  !! pull failed for $img (continuing)"
done

# ---- 2 + 3. rebuild local images, recreate changed containers ----
# Do it via the supervisor so the container conmons land in server-stack's
# persistent cgroup rather than this transient oneshot job's (see header).
log "rebuilding + recreating the stack"
if systemctl is-active --quiet server-stack.service 2>/dev/null; then
  systemctl reload server-stack.service >>"$LOG" 2>&1 \
    || { log "  !! reload failed — falling back to direct compose"; "${COMPOSE[@]}" up -d --build >>"$LOG" 2>&1; }
else
  "${COMPOSE[@]}" up -d --build >>"$LOG" 2>&1
fi

# ---- 3b. health check: every expected container running? ----
# Belt-and-braces: if anything came up stopped (e.g. the supervisor wasn't
# active and the direct fallback raced), recover through the supervisor so the
# container doesn't get killed when this job's cgroup is torn down.
source scripts/lib-containers.sh
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

# ---- 4. drop dangling layers left by the rebuild ----
podman image prune -f >>"$LOG" 2>&1 || true

log "=== update finished ==="
