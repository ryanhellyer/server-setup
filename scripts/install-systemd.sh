#!/usr/bin/env bash
# =============================================================================
# install-systemd.sh — make the compose-managed containers start at boot and be
# supervised by systemd. Run as root; deploy.sh calls it automatically.
#
# Supervision is a single `server-stack.service` that wraps
# `podman compose up -d` / `down` for the whole stack, so compose stays the
# source of truth and the containers' own `restart:` policies handle crashes.
# The unit stays active after `up` (RemainAfterExit=yes) and exposes an
# `ExecReload` that runs `up -d --build`; anything that recreates containers
# (scripts/update.sh) must go through `systemctl reload server-stack.service`
# so the conmon processes live in this persistent cgroup and not in the
# transient cgroup of the calling timer job (which systemd kills on exit).
# Older installs generated one `container-<name>.service` per container with the
# deprecated `podman generate systemd`. Those units were Type=forking and pinned
# each container's ID in PIDFile=, so they broke every time compose recreated a
# container (new ID) — systemd would then kill and restart it every ~90s. This
# script now removes any such units it finds.
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
STACK_UNIT="server-stack.service"

# Resolve the compose command once. `podman compose` delegates to the external
# provider (podman-compose); fall back to the standalone binary if needed.
if podman compose version >/dev/null 2>&1; then
  COMPOSE=(/usr/bin/podman compose)
else
  COMPOSE=("$(command -v podman-compose)")
fi
COMPOSE_FILE="$PWD/compose.yaml"

# ---- remove the obsolete per-container units ---------------------------------
# Older installs generated container-<name>.service with
# `podman generate systemd --name`. Those units are Type=forking and pin the
# container's ID in PIDFile=, so they start killing the container at the 90s
# start timeout as soon as compose recreates it under a new ID. Delete them (and
# any .d/ overrides) so only the single stack unit below supervises the stack.
for c in "${CONTAINERS[@]}"; do
  old="container-$c.service"
  if [ -e "$SYSTEMD_DIR/$old" ] || [ -d "$SYSTEMD_DIR/$old.d" ]; then
    echo "==> Removing obsolete $old"
    systemctl disable --now "$old" >/dev/null 2>&1 || true
    rm -f "$SYSTEMD_DIR/$old"
    rm -rf "$SYSTEMD_DIR/$old.d"
  fi
done
# Drop a leftover all-in-one unit from the pre-per-container setup, if present.
old="podman-compose@server-setup.service"
if [ -e "$SYSTEMD_DIR/$old" ]; then
  echo "==> Removing obsolete $old"
  systemctl disable --now "$old" >/dev/null 2>&1 || true
  rm -f "$SYSTEMD_DIR/$old"
fi

# ---- single stack supervisor unit --------------------------------------------
# `up -d` at boot, `down` on stop. The containers' own `restart:` policies keep
# the individual services alive, so systemd only has to bring the stack up once.
# compose honours depends_on, so no per-container ordering is needed.
echo "==> Writing $STACK_UNIT"
cat > "$SYSTEMD_DIR/$STACK_UNIT" <<EOF
[Unit]
Description=server-setup container stack (podman compose)
Documentation=man:podman-compose(1)
Wants=network-online.target
After=network-online.target
RequiresMountsFor=/run/containers/storage

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$PWD
ExecStart=${COMPOSE[*]} -f $COMPOSE_FILE up -d
ExecReload=${COMPOSE[*]} -f $COMPOSE_FILE up -d --build
ExecStop=${COMPOSE[*]} -f $COMPOSE_FILE down
TimeoutStartSec=600
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
for c in "${CONTAINERS[@]}"; do
  systemctl reset-failed "container-$c.service" >/dev/null 2>&1 || true
done
systemctl reset-failed "$STACK_UNIT" >/dev/null 2>&1 || true

echo "==> Enabling $STACK_UNIT"
systemctl enable --now "$STACK_UNIT"

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
    # The per-site log dirs under $LOG_ROOT are group-writable (the containers
    # write there), which logrotate refuses to touch unless told which user to
    # rotate as. Root can rotate them regardless of the directory mode.
    su root root
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
#
# NOTE: these jobs are Type=oneshot with RemainAfterExit=no, so systemd tears
# the service's cgroup down as soon as ExecStart exits. Never use a job as the
# parent of a long-lived process (e.g. `podman compose up`, which leaves conmon
# running) — it would be signalled/killed on exit. Recreate the stack through
# server-stack.service (`systemctl reload server-stack.service`) instead.
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
After=$STACK_UNIT
Wants=$STACK_UNIT

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
echo "  systemctl status $STACK_UNIT"
echo "Scheduled jobs (timers):"
echo "  systemctl list-timers 'server-backup.timer' 'certbot-renew.timer' 'server-update.timer' 'server-logs.timer' 'server-getmail.timer' 'server-scheduler.timer' 'server-wpcron.timer'"
[ -n "$QUEUE_SITES" ] && echo "Queue workers (services): systemctl list-units 'server-queue-worker-*.service'"
