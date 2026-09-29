#!/usr/bin/env bash
# =============================================================================
# install-login-help.sh — install an SSH login banner that shows the host
# helper commands plus a quick live status (backups, TLS, disk, sites) and a
# hint for rebuilding Vite front-end assets.
#
#   sudo bash scripts/install-login-help.sh
#   sudo bash scripts/install-login-help.sh --remove
#
# Writes /etc/update-motd.d/99-server-setup, which Ubuntu's pam_motd runs on
# every interactive login (SSH and console). It also disables the stock Ubuntu
# MOTD fragments (header, help text, landscape sysinfo, motd-news, updates …)
# so only this banner shows. Idempotent: re-running refreshes the text and
# re-disables the stock fragments (package updates can restore their exec bit).
# The banner is deliberately cheap (no network, no podman, no sudo prompts) so
# logins stay fast — it only reads local files and systemd state.
# =============================================================================
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"
MOTD_DIR="${MOTD_DIR:-/etc/update-motd.d}"
MOTD_FILE="${MOTD_FILE:-$MOTD_DIR/99-server-setup}"

# Stock Ubuntu fragments to suppress (only these; anything custom is left be).
STOCK_MOTD="00-header 10-help-text 50-landscape-sysinfo 50-motd-news 85-fwupd
  90-updates-available 91-contract-ua-esm-status 91-release-upgrade
  92-unattended-upgrades 95-hwe-eol 97-overlayroot 98-fsck-at-reboot
  98-reboot-required"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E "$SELF" "$@"
fi

# Suppress the stock fragments by clearing their exec bit (pam_motd only runs
# executable scripts). Symlinks are dereferenced by chmod; --remove restores it.
set_stock_motd() { # "$1" = enable|disable
  local mode="$1" name f
  for name in $STOCK_MOTD; do
    f="$MOTD_DIR/$name"
    [ -e "$f" ] || continue
    if [ "$mode" = "disable" ]; then chmod -x "$f" 2>/dev/null || true
    else                            chmod +x "$f" 2>/dev/null || true
    fi
  done
  # 50-motd-news also has a network-fetch toggle in /etc/default/motd-news.
  if [ -f /etc/default/motd-news ]; then
    local want=0; [ "$mode" = "enable" ] && want=1
    if grep -qs '^ENABLED=' /etc/default/motd-news; then
      sed -i "s/^ENABLED=.*/ENABLED=$want/" /etc/default/motd-news
    else
      printf 'ENABLED=%s\n' "$want" >> /etc/default/motd-news
    fi
  fi
}

if [ "${1:-}" = "--remove" ]; then
  rm -f "$MOTD_FILE"
  set_stock_motd enable
  echo "Removed login banner: $MOTD_FILE (stock Ubuntu MOTD re-enabled)"
  exit 0
fi

mkdir -p "$(dirname "$MOTD_FILE")"
set_stock_motd disable
cat > "$MOTD_FILE" <<'BANNER_SCRIPT'
#!/bin/sh
# server-setup — SSH login banner. Managed by scripts/install-login-help.sh.
# Remove with: sudo bash scripts/install-login-help.sh --remove
# Cheap on purpose: local files + systemd only (no network, no podman).

REPO_DIR="__REPO_DIR__"
ADMIN_HOME=$(dirname "$REPO_DIR")
WWW_DIR="$ADMIN_HOME/www"

cat <<'BANNER'

  Ryans server
  Pressabl 15
  ===========

  server-setup — host helper commands
  -----------------------------------
    pod-login [container]         shell inside a container (default: php-fpm)
    pod-logs  <container> [-f]    print / follow a container's logs
    pod-status                    stack state + health
    pod-restart <c> | --all       restart mariadb | php-fpm | nginx | all
    nginx-reload | php-reload     graceful reload (no dropped connections)
    sites                         list sites under ~/www (type + database)
    cert-status                   TLS certificate domains + expiry
    pod-exec <container> <cmd>    run one command in any container
    php composer wp artisan mariadb mysql node npm nginx ffmpeg ...  in-container tools

  Menu: sudo bash __REPO_DIR__/install/setup.sh
    Docs: __REPO_DIR__/README.md    Logs: pod-logs -f    Repo: __REPO_DIR__

BANNER

# --- adding a site (static text; the banner stays cheap) -------------------
printf '  Add a new site\n  --------------\n'
printf '    menu  : sudo bash %s/install/setup.sh   then choose 2\n' "$REPO_DIR"
printf '    or    : sudo bash %s/scripts/new-site.sh <domain> <type>\n' "$REPO_DIR"
printf '    types : laravel | wordpress | static | static-spa | redirect | node\n'
printf '            (redirect needs a target, e.g. https://dest.example$request_uri)\n'
printf '    then  : point DNS at this host, add the domain to\n'
printf '            %s/certbot/domains.txt, then run certbot-issue.sh\n' "$REPO_DIR"
printf '            (new-site.sh already reloads nginx for you)\n'

# --- other server tasks (static text; these left the setup menu) -----------
printf '\n  Other server tasks (run on the host)\n'
printf '  ------------------------------------\n'
printf '    renew TLS      : sudo bash %s/scripts/certbot-issue.sh\n' "$REPO_DIR"
printf '    systemd units  : sudo bash %s/scripts/install-systemd.sh\n' "$REPO_DIR"
printf '    host CLI tools : bash %s/scripts/install-cli.sh\n' "$REPO_DIR"
printf '    stack status   : pod-status          (raw: podman ps)\n'
printf '    container logs : pod-logs <container> [-f]   (default: php-fpm)\n'
printf '    storage boxes  : sudo bash %s/scripts/storage-mounts.sh\n' "$REPO_DIR"
printf '    harden SSH     : sudo bash %s/scripts/harden-sshd.sh [--revert]\n' "$REPO_DIR"

# --- front-end assets (static text; the banner stays cheap) ----------------
printf '\n  Broken CSS/JS after a restore? Rebuild a site'"'"'s Vite assets\n'
printf '  -------------------------------------------------------------\n'
printf '    one site  : sudo bash %s/scripts/build-assets.sh <site>\n' "$REPO_DIR"
printf '    all sites : sudo bash %s/scripts/build-assets.sh --all --force\n' "$REPO_DIR"
printf '    (npm/node run inside the node container; there is no host npm)\n'

# --- backups ---------------------------------------------------------------
# Read BACKUP_* / DB_DUMP_DIR from .env (never network). A missing value is
# reported rather than silently shown as "unset".
if [ -r "$REPO_DIR/.env" ]; then
  BU_ENABLED=$(sed -nE 's/^BACKUP_ENABLED=//p'   "$REPO_DIR/.env" | tail -1)
  BU_HOST=$(sed -nE 's/^BACKUP_HOST=//p'         "$REPO_DIR/.env" | tail -1)
  BU_BASE=$(sed -nE 's/^BACKUP_REMOTE_BASE=//p' "$REPO_DIR/.env" | tail -1)
  DUMP_DIR=$(sed -nE 's/^DB_DUMP_DIR=//p'        "$REPO_DIR/.env" | tail -1)
fi
DUMP_DIR=${DUMP_DIR:-$ADMIN_HOME/mariadbs}
BU_BASE=${BU_BASE:-/home}

bu_line="off"
[ "$BU_ENABLED" = "1" ] && bu_line="on"
[ -n "$BU_HOST" ] || bu_line="on (BACKUP_HOST NOT SET — will fail)"
latest_dump=""
if [ -d "$DUMP_DIR" ]; then
  latest_dump=$(ls -1 "$DUMP_DIR"/*.sql.gz 2>/dev/null | tail -1)
fi
next_run=$(systemctl list-timers server-backup.timer --no-pager 2>/dev/null | awk 'NR==2{print $1" "$2" "$3" "$4}')

printf '\n  Backups\n  -------\n'
printf '    enabled      : %s\n' "$bu_line"
[ -n "$BU_HOST" ] && printf '    target box   : %s:%s\n' "$BU_HOST" "$BU_BASE"
if [ -n "$latest_dump" ]; then
  printf '    latest db dump: %s\n' "$(basename "$latest_dump")"
else
  printf '    latest db dump: (none in %s)\n' "$DUMP_DIR"
fi
[ -n "$next_run" ] && printf '    next run     : %s\n' "$next_run"
printf '    run now      : sudo systemctl start server-backup.service\n'
printf '    dry run      : sudo bash %s/scripts/backup.sh --dry-run\n' "$REPO_DIR"
printf '    restore      : sudo bash %s/scripts/restore.sh --from-backup [DATE] [www|tools|mariadbs]\n' "$REPO_DIR"

# --- TLS certificates (local files only) -----------------------------------
CERT_LIVE="$REPO_DIR/env/letsencrypt/live"
if [ -d "$CERT_LIVE" ]; then
  printf '\n  TLS certificates\n  ----------------\n'
  printf '    %-14s %-12s %s\n' CERT EXPIRES DAYS
  for d in "$CERT_LIVE"/*/; do
    [ -f "$d/fullchain.pem" ] || continue
    end=$(openssl x509 -in "$d/fullchain.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
    [ -n "$end" ] || continue
    days=$(( ($(date -d "$end" +%s 2>/dev/null || echo 0) - $(date +%s)) / 86400 ))
    mark=""
    [ "$days" -lt 7 ] && mark="  <-- renew soon"
    printf '    %-14s %-12s %s%s\n' "$(basename "$d")" "$(date -d "$end" +%Y-%m-%d 2>/dev/null)" "$days" "$mark"
  done
fi

# --- disk + sites (cheap local stats) --------------------------------------
root_use=$(df -h / 2>/dev/null | awk 'NR==2{print $5" used, "$4" free ("$1" total)"}')
site_count=$(find "$WWW_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
printf '\n  Host\n  ----\n'
[ -n "$root_use" ] && printf '    disk (/)     : %s\n' "$root_use"
printf '    sites        : %s under %s\n' "$site_count" "$WWW_DIR"
printf '\n'
BANNER_SCRIPT
chmod 755 "$MOTD_FILE"

# Bake in the repo location (the banner runs as root at login, so $HOME is not
# the admin home). Paths with # or & are unlikely here but escape anyway.
_esc_repo=$(printf '%s' "$REPO_DIR" | sed 's/[#&]/\\&/g')
sed -i "s#__REPO_DIR__#$_esc_repo#g" "$MOTD_FILE"

echo "Installed login banner: $MOTD_FILE"
echo "It appears on the next interactive login (SSH or console)."
