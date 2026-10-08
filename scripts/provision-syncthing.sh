#!/usr/bin/env bash
# =============================================================================
# provision-syncthing.sh — wire up and start the phone.hellyer.kiwi file sync.
#
#   sudo bash scripts/provision-syncthing.sh [--dry-run]
#
# What it sets up:
#   * ~/www/phone.hellyer.kiwi/.syncthing   — Syncthing config + index DB,
#     owned by the admin user (the PUID the container runs as).
#   * $PHONE_FILES_ROOT (default ~/phone-files) — the synced content; an sshfs
#     mount of u676107:/home/phone-files (scripts/storage-mounts.sh). It lives
#     outside ~/www and is mounted read-only into php-fpm at /var/phone-files.
#   * SYNCTHING_PUID / SYNCTHING_PGID in .env (from the admin user's ids).
#   * the `syncthing` container (compose.yaml), then waits for its health API.
#
# The folder itself is added ONCE through the GUI (the path is /var/sync/files);
# the GUI is published on 127.0.0.1:8384 only, so reach it via an SSH tunnel:
#
#   ssh -L 8384:127.0.0.1:8384 ryan@<host>   # then open http://127.0.0.1:8384
#
# Idempotent: re-running re-applies ownership and restarts the container.
# Options: --dry-run
# Config: PHONE_FILES_ROOT / SYNCTHING_PUID / SYNCTHING_PGID / PHONE_FILES_REMOTE in .env.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-env.sh

WWW_ROOT="$(resolve_www_root)"
ADMIN_USER="$(resolve_admin_user)"
ADMIN_UID="$(id -u "$ADMIN_USER")"
ADMIN_GID="$(id -g "$ADMIN_USER")"
PHONE_DIR="$WWW_ROOT/phone.hellyer.kiwi"
FILES_DIR="${PHONE_FILES_ROOT:-$(resolve_admin_home)/phone-files}"
CONFIG_DIR="$PHONE_DIR/.syncthing"
ENV_FILE="$PWD/.env"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
run() { if [ "$DRY" = 1 ]; then printf '    DRY: %s\n' "$*"; else "$@"; fi; }

[ -f "$ENV_FILE" ] || die ".env not found — run scripts/deploy.sh once to create it (or copy .env.example)."

# ---- 1. Syncthing uid/gid in .env (must own the sshfs mount) ----------------
if [ "$DRY" = 1 ]; then
  [ -n "$(get_env "$ENV_FILE" SYNCTHING_PUID 2>/dev/null || true)" ] \
    || warn "SYNCTHING_PUID would be set to $ADMIN_UID"
  [ -n "$(get_env "$ENV_FILE" SYNCTHING_PGID 2>/dev/null || true)" ] \
    || warn "SYNCTHING_PGID would be set to $ADMIN_GID"
else
  [ -n "$(get_env "$ENV_FILE" SYNCTHING_PUID 2>/dev/null || true)" ] \
    || { set_env "$ENV_FILE" SYNCTHING_PUID "$ADMIN_UID"; say "Set SYNCTHING_PUID=$ADMIN_UID in .env"; }
  [ -n "$(get_env "$ENV_FILE" SYNCTHING_PGID 2>/dev/null || true)" ] \
    || { set_env "$ENV_FILE" SYNCTHING_PGID "$ADMIN_GID"; say "Set SYNCTHING_PGID=$ADMIN_GID in .env"; }
  set -a; source "$ENV_FILE"; set +a
fi

# ---- 2. directories --------------------------------------------------------
say "Ensuring $CONFIG_DIR (owned $ADMIN_USER:$ADMIN_USER)"
run install -d -o "$ADMIN_USER" -g "$ADMIN_GID" -m 2775 "$CONFIG_DIR"
run install -d -o "$ADMIN_USER" -g www-data -m 2775 "$PHONE_DIR/public"
[ -e "$FILES_DIR" ] || run install -d -o "$ADMIN_USER" -g "$ADMIN_GID" -m 2775 "$FILES_DIR"

# ---- 3. the sshfs mount (best-effort; storage-mounts.sh owns the config) ----
if mountpoint -q "$FILES_DIR" 2>/dev/null; then
  ok "phone files mount is active: $FILES_DIR"
else
  if [ "$DRY" != 1 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl start "$(systemd-escape -p --suffix=automount "$FILES_DIR")" >/dev/null 2>&1 || true
    ls "$FILES_DIR" >/dev/null 2>&1 || true
  fi
  if mountpoint -q "$FILES_DIR" 2>/dev/null; then
    ok "phone files mount started: $FILES_DIR"
  else
    warn "phone files mount is NOT active — the sync will not work yet."
    warn "Set it up (asks for the u676107 password once), then re-run:"
    warn "    sudo bash scripts/storage-mounts.sh"
  fi
fi

# ---- 4. bring up the container --------------------------------------------
say "Bringing up the syncthing service"
if [ "$DRY" = 1 ]; then
  echo "    DRY: podman compose up -d syncthing"
else
  if podman compose version >/dev/null 2>&1; then podman compose up -d syncthing; else podman-compose up -d syncthing; fi
fi

# ---- 5. wait for the health API -------------------------------------------
if [ "$DRY" != 1 ]; then
  say "Waiting for Syncthing to become healthy"
  up=0
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:8384/rest/noauth/health" >/dev/null 2>&1; then
      ok "Syncthing is up"; up=1; break
    fi
    sleep 2
  done
  [ "$up" = 1 ] || warn "No health answer yet — check: podman logs --tail=40 $CONTAINER_SYNCTHING"
fi

# ---- 6. next steps ---------------------------------------------------------
# The image sets STHOMEDIR=/var/syncthing/config, so config.xml (with the
# device ID) lands in $CONFIG_DIR/config/ on the host.
DEVICE_ID="$(grep -oE '<device id="[A-Z0-9-]+"' "$CONFIG_DIR/config/config.xml" 2>/dev/null \
  | head -1 | grep -oE '[A-Z0-9]{7}-[A-Z0-9-]+' || true)"

echo
ok "Done: phone file sync (phone.hellyer.kiwi)"
echo
echo "Device ID: ${DEVICE_ID:-<open the GUI to see it>}"
echo
echo "Next steps:"
echo "  1. Reach the GUI (localhost only) over an SSH tunnel:"
echo "       ssh -L 8384:127.0.0.1:8384 ryan@<this-host>"
echo "     then open http://127.0.0.1:8384 in your browser."
echo "  2. Set a GUI username/password (Settings -> GUI) since the tunnel is the"
echo "     only protection on the GUI."
echo "  3. Add the phone as a device, and share a folder with this server using"
echo "     the folder path:  /var/sync/files"
echo "  4. The synced files land in $FILES_DIR on the host and are readable by"
echo "     the Laravel app at /var/phone-files inside the php-fpm container."
echo
echo "Point DNS for phone.hellyer.kiwi at this host, then issue TLS:"
echo "  sudo bash scripts/certbot-issue.sh   # (phone.hellyer.kiwi is in certbot/domains.txt)"
