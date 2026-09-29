#!/usr/bin/env bash
# =============================================================================
# install-systemd.sh — make the compose-managed containers start at boot and be
# supervised by systemd. Run as root; deploy.sh calls it automatically.
#
# For each container it generates a `container-<name>.service` with
# `podman generate systemd` (start/stop the EXISTING container, so it stays
# compatible with compose, which remains the source of truth), enables it, and
# adds ordering so nginx starts after the FPM socket provider (php-fpm).
#
# It also installs systemd timers for the scheduled jobs: `server-backup.timer`
# (nightly 03:00), `certbot-renew.timer` (2x/day), `server-update.timer`
# (weekly), `server-logs.timer` (hourly, rotates the per-site nginx logs
# under $LOG_ROOT) and `server-getmail.timer` (daily Gmail fetch), so backups,
# TLS renewal, image/OS updates, log rotation and mail happen automatically.
#
# Re-run anytime (idempotent) — e.g. after `compose up` recreates a container.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-storage.sh
[ -f .env ] && set -a && source .env && set +a

command -v systemctl >/dev/null 2>&1 || { echo "systemd not present — skipping."; exit 0; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo ./scripts/install-systemd.sh)."; exit 1; }

# Containers compose creates (defined once in lib-containers.sh).
CONTAINERS=("${ALL_CONTAINERS[@]}")

SYSTEMD_DIR=/etc/systemd/system

# Ensure the stack is up so units can be generated from live containers.
if podman compose version >/dev/null 2>&1; then
  podman compose up -d
else
  podman-compose up -d
fi

for c in "${CONTAINERS[@]}"; do
  if ! podman container exists "$c" 2>/dev/null; then
    echo "  (container '$c' not running yet — skipping its unit; re-run after compose up)"
    continue
  fi
  echo "==> Generating systemd unit for $c"
  # Note: `--files` writes to the CURRENT directory, not to $SYSTEMD_DIR, so
  # the unit must be redirected explicitly or `systemctl enable` below fails.
  podman generate systemd --name "$c" > "$SYSTEMD_DIR/container-$c.service"
done

# nginx depends on the shared FPM socket: start it after php-fpm/node.
OVERRIDE="$SYSTEMD_DIR/container-$CONTAINER_NGINX.service.d/order.conf"
mkdir -p "$(dirname "$OVERRIDE")"
cat > "$OVERRIDE" <<EOF
[Unit]
After=container-$CONTAINER_PHP_FPM.service container-$CONTAINER_NODE.service container-$CONTAINER_OPENWEBUI.service
Wants=container-$CONTAINER_PHP_FPM.service container-$CONTAINER_NODE.service container-$CONTAINER_OPENWEBUI.service
EOF

# open-webui: cap CPU/memory and bound crash restarts, so a broken app (e.g. a
# corrupt SQLite DB) can't peg a core or restart forever. Its compose service
# deliberately has no podman restart policy, so systemd is the sole supervisor.
OPENWEBUI_OVERRIDE="$SYSTEMD_DIR/container-$CONTAINER_OPENWEBUI.service.d/limits.conf"
mkdir -p "$(dirname "$OPENWEBUI_OVERRIDE")"
cat > "$OPENWEBUI_OVERRIDE" <<EOF
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Restart=on-failure
CPUQuota=100%
MemoryMax=1536M
EOF

systemctl daemon-reload

for c in "${CONTAINERS[@]}"; do
  if ! podman container exists "$c" 2>/dev/null; then
    continue
  fi
  echo "==> Enabling container-$c.service"
  systemctl enable "container-$c.service" >/dev/null 2>&1
  systemctl start "container-$c.service" 2>/dev/null || true
done

# ---- per-site log rotation ----
# Per-site nginx logs live under $LOG_ROOT (~/logs), outside the web roots, so
# they are never part of a site backup/snapshot. Without rotation they grow
# unbounded (the old production box had multi-GB error.log files). This config
# lives OUTSIDE /etc/logrotate.d on purpose: it is driven by the hourly
# server-logs.timer below (with its own state file), so Ubuntu's daily
# logrotate job must not process it a second time.
LOG_ROOT="$(resolve_log_root)"
if ! command -v logrotate >/dev/null 2>&1; then
  echo "==> installing logrotate"
  DEBIAN_FRONTEND=noninteractive apt-get install -y logrotate >/dev/null 2>&1 || \
    echo "  (logrotate install failed — the server-logs timer will no-op)"
fi
cat > /etc/logrotate-server-setup.conf <<EOF
# Managed by server-setup (scripts/install-systemd.sh). Rotates the per-site
# nginx logs under \$LOG_ROOT. Driven hourly by server-logs.timer.
$LOG_ROOT/*/*.log {
    daily
    maxsize 50M
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0644
    sharedscripts
    postrotate
        podman exec $CONTAINER_NGINX nginx -s reopen 2>/dev/null || true
    endscript
}
EOF
echo "==> wrote /etc/logrotate-server-setup.conf (logs under $LOG_ROOT, 50M cap)"

# ---- scheduled jobs: nightly backup + TLS renewal (systemd timers) ----
# Installed automatically on every deploy so nothing depends on an admin
# remembering to cron them. Idempotent — unit files are overwritten and the
# timers re-enabled. `enable --now` on a .timer only arms the schedule
# (OnCalendar); it does NOT run the oneshot service immediately.
write_job() { # "$1" name, "$2" service desc, "$3" exec, "$4" timer desc, "$5" OnCalendar, "$6" delay
  local name="$1" sdesc="$2" exec="$3" tdesc="$4" cal="$5" delay="$6"
  cat > "$SYSTEMD_DIR/$name.service" <<EOF
[Unit]
Description=$sdesc
After=network-online.target

[Service]
Type=oneshot
ExecStart=$exec
EOF
  cat > "$SYSTEMD_DIR/$name.timer" <<EOF
[Unit]
Description=$tdesc

[Timer]
OnCalendar=$cal
RandomizedDelaySec=$delay

[Install]
WantedBy=timers.target
EOF
}

# Backup nightly at 03:00 (staggered up to 15 min).
write_job "server-backup" \
  "server-setup nightly backup" \
  "/bin/bash $PWD/scripts/backup.sh" \
  "run the server-setup nightly backup" \
  "*-*-* 03:00:00" "15m"

# TLS renewal twice a day (Let's Encrypt recommendation); certbot only renews
# when a cert has <30 days left, so this never hits rate limits.
write_job "certbot-renew" \
  "server-setup TLS certificate renewal" \
  "/bin/bash $PWD/scripts/certbot-issue.sh" \
  "run the server-setup TLS certificate renewal" \
  "*-*-* 00,12:00:00" "30m"

# Weekly image/OS refresh: pull upstream images + rebuild the local ones
# (which re-runs apt, updating the Ubuntu packages inside the containers) and
# recreate anything changed. Sunday 04:00, staggered up to 30 min. This does
# NOT run provisioning, so site data is untouched.
write_job "server-update" \
  "server-setup weekly image update" \
  "/bin/bash $PWD/scripts/update.sh" \
  "pull/build/recreate the stack weekly" \
  "Sun *-*-* 04:00:00" "30m"

# Hourly log-rotation check. The config is `daily` + `maxsize 50M`, so a normal
# day rotates once while a runaway log is cut as soon as it passes 50M (checked
# hourly). Uses its own state file (see the logrotate config above).
mkdir -p /var/lib/logrotate
LOGROTATE_BIN="$(command -v logrotate || echo /usr/sbin/logrotate)"
write_job "server-logs" \
  "server-setup per-site log rotation" \
  "$LOGROTATE_BIN --state /var/lib/logrotate/server-setup.status /etc/logrotate-server-setup.conf" \
  "rotate the server-setup per-site nginx logs" \
  "*-*-* *:00:00" "5m"

# Gmail fetch daily (getmail -> ~/gmail). Staggered up to 15 min.
write_job "server-getmail" \
  "server-setup Gmail fetch (getmail)" \
  "/bin/bash $PWD/scripts/getmail.sh" \
  "fetch Gmail into the Maildir daily" \
  "*-*-* 02:00:00" "15m"

# Laravel scheduler: tick every site's `artisan schedule:run` once a minute.
# No RandomizedDelaySec: the scheduler is minute-accurate by design (a delay
# would skip the current minute's tasks), and each run is short.
write_job "server-scheduler" \
  "server-setup Laravel scheduler tick" \
  "/bin/bash $PWD/scripts/laravel-scheduler.sh" \
  "run artisan schedule:run for each Laravel site" \
  "*-*-* *:*:00" "0"

# WordPress multisite catch-up cron: run all due WP-Cron events every 10 min
# (a full pass over ~26 sites can take longer than a minute, so a tighter
# interval would just run back-to-back).
write_job "server-wpcron" \
  "server-setup WordPress multisite cron" \
  "/bin/bash $PWD/scripts/wp-cron.sh" \
  "run due WP-Cron events across the multisite" \
  "*-*-* *:0/10:00" "0"

# ---- Laravel queue workers (supervised services) ----------------------------
# Each entry runs `artisan queue:work database` as a long-lived process. Unlike
# the timers above these are SERVERS, not oneshots: systemd restarts them if
# they die (Restart=always). Config (space-separated sites), defaulting to the
# one site the legacy server ran a worker for:
#   QUEUE_WORKER_SITES="kartastrophecup.de"
# A site listed under its snapshot name is resolved through SNAPSHOT_RENAMES
# (e.g. spam-destroyer.com -> spam-destroyer.hellyer.kiwi) to its local dir.
WWW_ROOT="$(resolve_www_root)"
QUEUE_SITES="${QUEUE_WORKER_SITES-kartastrophecup.de}"
for site in $QUEUE_SITES; do
  dir="$(apply_rename "$site")"
  [ -n "$dir" ] || dir="$site"
  unit="server-queue-worker-${dir//[^A-Za-z0-9]/-}.service"
  echo "==> Writing $unit (queue worker: $dir)"
  cat > "$SYSTEMD_DIR/$unit" <<EOF
[Unit]
Description=server-setup Laravel queue worker ($dir)
After=container-$CONTAINER_PHP_FPM.service container-$CONTAINER_MARIADB.service
Wants=container-$CONTAINER_PHP_FPM.service container-$CONTAINER_MARIADB.service

[Service]
Type=simple
ExecStart=/usr/bin/podman exec -u www-data -w $CONTAINER_WWW/$dir $CONTAINER_PHP_FPM php artisan queue:work database --sleep=3 --tries=3 --timeout=120
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
done

echo "==> Enabling scheduled jobs (nightly backup + TLS renewal + weekly update + hourly log rotation + daily getmail + minute scheduler/wpcron)"
systemctl daemon-reload
systemctl enable --now server-backup.timer certbot-renew.timer server-update.timer server-logs.timer server-getmail.timer server-scheduler.timer server-wpcron.timer
for site in $QUEUE_SITES; do
  dir="$(apply_rename "$site")"; [ -n "$dir" ] || dir="$site"
  unit="server-queue-worker-${dir//[^A-Za-z0-9]/-}.service"
  systemctl enable --now "$unit" >/dev/null 2>&1 || true
done

echo
echo "Systemd units installed and enabled. The stack will start at boot:"
echo "  systemctl list-units 'container-*.service'"
echo "Scheduled jobs (timers):"
echo "  systemctl list-timers 'server-backup.timer' 'certbot-renew.timer' 'server-update.timer' 'server-logs.timer' 'server-getmail.timer' 'server-scheduler.timer' 'server-wpcron.timer'"
[ -n "$QUEUE_SITES" ] && echo "Queue workers (services): systemctl list-units 'server-queue-worker-*.service'"
