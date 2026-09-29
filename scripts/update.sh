#!/usr/bin/env bash
# =============================================================================
# update.sh — refresh the stack (images + container OS packages) in place.
#
#   sudo bash scripts/update.sh
#
# What it does:
#   1. pulls the upstream images (mariadb / valkey / open-webui / certbot) by
#      their tags — a floating tag resolves to the newest image;
#   2. rebuilds the locally-built images (php / nginx / node) from their
#      Containerfiles. The build re-runs `apt-get update && install`, so the
#      Ubuntu 24.04 packages inside those images get their latest updates;
#   3. recreates any containers whose image changed;
#   4. prunes the old image layers.
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
  docker.io/certbot/certbot:latest
)
for img in "${UPSTREAM[@]}"; do
  log "pulling $img"
  podman pull "$img" >>"$LOG" 2>&1 || log "  !! pull failed for $img (continuing)"
done

# ---- 2 + 3. rebuild local images, recreate changed containers ----
log "rebuilding + recreating the stack"
"${COMPOSE[@]}" up -d --build >>"$LOG" 2>&1

# ---- 4. drop dangling layers left by the rebuild ----
podman image prune -f >>"$LOG" 2>&1 || true

log "=== update finished ==="
