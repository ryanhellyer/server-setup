#!/usr/bin/env bash
# =============================================================================
# lib-containers.sh — SINGLE source of truth for the stack's container names
# and the host-CLI command -> container map. SOURCE THIS FILE from other
# scripts; never execute it directly (it defines functions/vars only).
#
#   source scripts/lib-containers.sh
#
# Keep the names in sync with compose.yaml (the deployment source of truth —
# services: nginx / php (container_name: php-fpm) / node / mariadb / valkey).
# =============================================================================

# ---- canonical container names (must match compose.yaml) ----
CONTAINER_NGINX="nginx"
CONTAINER_PHP_FPM="php-fpm"
CONTAINER_MARIADB="mariadb"
CONTAINER_VALKEY="valkey"
CONTAINER_NODE="node"
CONTAINER_OPENWEBUI="open-webui"

# Ordered container inventory (nginx last: it depends on php-fpm/node/open-webui).
ALL_CONTAINERS=(
  "$CONTAINER_NGINX"
  "$CONTAINER_PHP_FPM"
  "$CONTAINER_MARIADB"
  "$CONTAINER_VALKEY"
  "$CONTAINER_NODE"
  "$CONTAINER_OPENWEBUI"
)

# ---- host-CLI command -> container (drives bin/pod-exec + install-cli.sh) ----
declare -A CLI_CONTAINER=(
  # php-fpm
  [php]=php-fpm [composer]=php-fpm [wp]=php-fpm [artisan]=php-fpm
  [ffmpeg]=php-fpm [ffprobe]=php-fpm [php-reload]=php-fpm
  [convert]=php-fpm [identify]=php-fpm [compare]=php-fpm [montage]=php-fpm
  [zip]=php-fpm [unzip]=php-fpm [sqlite3]=php-fpm [gs]=php-fpm [pdftoppm]=php-fpm
  # mariadb
  [mariadb]=mariadb [mysql]=mariadb [mysqldump]=mariadb [mariadb-dump]=mariadb
  # valkey (drop-in Redis replacement; `redis-cli` kept as a compat alias)
  [valkey-cli]=valkey
  [redis-cli]=valkey
  # node
  [node]=node [npm]=node [npx]=node
  # nginx
  [nginx]=nginx [nginx-test]=nginx [nginx-reload]=nginx [nginx-restart]=nginx
)