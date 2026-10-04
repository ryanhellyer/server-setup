#!/usr/bin/env bash
# =============================================================================
# container-watchdog.sh — restart stack containers that have hung or gone
# unhealthy.
#
#   sudo bash scripts/container-watchdog.sh [--dry-run]
#
# Why this exists: `restart: unless-stopped` only brings a container back when
# its main process EXITS. A container whose app hangs but keeps running (the
# process listens on its port yet never answers — as Open WebUI and MariaDB
# have both done on this box) stays up forever and is never recovered by
# compose. This watchdog is the thing that actually acts on a hang:
#
#   * containers with a HEALTHCHECK (compose.yaml) are checked via the
#     `.State.Health.Status` field — an `unhealthy` verdict triggers a restart;
#   * containers WITHOUT a healthcheck are pinged over the compose network from
#     the `node`/`curl`-capable container where one is available, falling back
#     to a TCP connect from the host for the rest.
#
# Restarts are done with `podman restart` (the container keeps its compose
# labels and restart policy). A container that ignores SIGTERM is escalated by
# the runtime itself; if the restart leaves conmon wedged we fall back to an
# explicit `podman start`. Runs every 2 minutes via server-watchdog.timer.
#
# Logs to /var/log/server-setup/watchdog.log.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo bash scripts/container-watchdog.sh)."; exit 1; }

source scripts/lib-containers.sh

LOG_DIR=/var/log/server-setup
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/watchdog.log"
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

# ---- health probes -----------------------------------------------------------
# Each entry is checked and, on failure, restarted. Containers with a compose
# healthcheck use that verdict directly; the rest use an explicit probe.
#
# probe results: 0 = healthy, non-zero = needs restart.
is_running() { # container
  [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

is_paused() { # container
  [ "$(podman inspect -f '{{.State.Paused}}' "$1" 2>/dev/null)" = "true" ]
}

health_status() { # container -> healthy|unhealthy|starting|<empty if none>
  podman inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null
}

# TCP connect test from the host to a published/loopback port.
tcp_ok() { # host port
  timeout 5 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

# HTTP test from INSIDE the compose network, using the php-fpm container which
# ships curl. $1=url.
http_ok_in_net() { # url
  podman exec "$CONTAINER_PHP_FPM" curl -fsS -o /dev/null --max-time 8 "$1" 2>/dev/null
}

restart_container() { # container reason
  local c="$1" reason="$2"
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY: would restart $c ($reason)"
    return 0
  fi
  log "RESTART $c ($reason)"
  # A paused container cannot be restarted/started until it is unpaused.
  if is_paused "$c"; then
    podman unpause "$c" >>"$LOG" 2>&1 || true
  fi
  # `podman restart` keeps labels/restart-policy. It can exit non-zero when a
  # hung process had to be SIGKILLed and conmon got wedged, so always verify
  # and fall back to an explicit start.
  podman restart -t 20 "$c" >>"$LOG" 2>&1 || true
  # Give it a moment to come up; a healthy restart can take a few seconds to
  # report Running=true, so poll before declaring failure.
  local i
  for i in 1 2 3 4 5; do
    is_running "$c" && return 0
    sleep 2
  done
  log "  $c not running after restart — forcing start"
  podman start "$c" >>"$LOG" 2>&1 || log "  !! podman start $c failed"
}

# ---- check every container ---------------------------------------------------
# Ordered so nginx (the front door) is handled last, after its upstreams.
for c in "${ALL_CONTAINERS[@]}"; do
  if ! is_running "$c"; then
    if is_paused "$c"; then
      # A paused container reports Running=false and can't be restarted until
      # unpaused. Treat it like a hang.
      restart_container "$c" "paused/hung"
    else
      # Exited/crashed: compose's restart policy should handle it, but if it is
      # sitting exited, bring it back.
      log "$c is not running — starting"
      [ "$DRY_RUN" = "1" ] || { podman start "$c" >>"$LOG" 2>&1 || log "  !! start $c failed"; }
    fi
    continue
  fi

  hs="$(health_status "$c")"
  if [ "$hs" = "unhealthy" ]; then
    restart_container "$c" "healthcheck unhealthy"
    continue
  fi
  if [ -n "$hs" ] && [ "$hs" != "healthy" ]; then
    # starting/other — leave it to settle.
    continue
  fi

  # No healthcheck: use a targeted probe per container.
  case "$c" in
    "$CONTAINER_OPENWEBUI")
      # Belt-and-braces even though it now has a healthcheck: verify the app
      # answers inside the network, not just that the port is bound.
      http_ok_in_net "http://open-webui:8080/health" \
        || restart_container "$c" "no HTTP answer on /health"
      ;;
    "$CONTAINER_MARIADB")
      # A hung mariadbd accepts TCP but answers no query; ping is cheap.
      podman exec "$CONTAINER_MARIADB" sh -c \
        'mariadb-admin ping -uroot -p"$MARIADB_ROOT_PASSWORD" --silent' >/dev/null 2>&1 \
        || restart_container "$c" "mariadb ping failed"
      ;;
    "$CONTAINER_VALKEY")
      podman exec "$CONTAINER_VALKEY" valkey-cli ping >/dev/null 2>&1 \
        || restart_container "$c" "valkey ping failed"
      ;;
    "$CONTAINER_GOATCOUNTER")
      http_ok_in_net "http://goatcounter:8080/" \
        || restart_container "$c" "no HTTP answer"
      ;;
    "$CONTAINER_AUTHELIA")
      http_ok_in_net "http://authelia:9091/api/health" \
        || restart_container "$c" "no HTTP answer on /api/health"
      ;;
    "$CONTAINER_NGINX")
      # nginx is the front door; verify it serves on loopback 443.
      tcp_ok 127.0.0.1 443 || restart_container "$c" "not listening on :443"
      ;;
    "$CONTAINER_NODE"|"$CONTAINER_PHP_FPM")
      # Long-lived app containers; a bound process is enough — php-fpm has no
      # HTTP endpoint of its own and node's app is per-site.
      ;;
  esac
done

exit 0
