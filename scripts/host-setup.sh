#!/usr/bin/env bash
# =============================================================================
# host-setup.sh — install the (small) host package set and create the
# bind-mount directories. Run once as root.
#
# Called by:
#   - install/setup.sh (fresh-host one-time setup)
#   - deploy.sh    (automatically, when podman/podman-compose are missing)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" -eq 0 ] || { echo "Run as root."; exit 1; }

[ -f .env ] && set -a && source .env && set +a
source scripts/lib-paths.sh
WWW_ROOT="$(resolve_www_root)"
LOG_ROOT="$(resolve_log_root)"

export DEBIAN_FRONTEND=noninteractive

echo "==> apt update + upgrade"
apt-get update
apt-get upgrade -y

echo "==> installing host packages"
apt-get install -y \
  podman \
  podman-compose \
  curl \
  tar \
  rsync \
  openssl \
  openssh-client \
  sshfs \
  ufw \
  fail2ban \
  logrotate \
  getmail6 \
  unattended-upgrades \
  nano

echo "==> capping journald size"
install -d -m 755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-server-setup.conf <<'EOF'
# Managed by server-setup (scripts/host-setup.sh).
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
systemctl restart systemd-journald 2>/dev/null || true

echo "==> fail2ban: sshd jail (systemd backend)"
cat > /etc/fail2ban/jail.local <<'EOF'
# Managed by server-setup (scripts/host-setup.sh).
[DEFAULT]
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban 2>/dev/null || true

# Reboot automatically only when an update requires it (kernel/libc/etc.), at
# 03:30; also clean up superseded kernels and auto-installed dependencies.
echo "==> unattended-upgrades: auto-reboot when required"
cat > /etc/apt/apt.conf.d/99-server-setup-autoreboot <<'EOF'
// Managed by server-setup (scripts/host-setup.sh).
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF

echo "==> creating bind-mount directories"
mkdir -p /var/databases /var/cache/nginx /var/log/nginx

# Site files live under the admin user's home (~/www), mounted at /var/www in
# the containers. Create it owned by ryan:www-data with the setgid bit.
WWW_GROUP="www-data"
getent group www-data >/dev/null 2>&1 || WWW_GROUP="root"
if id ryan >/dev/null 2>&1; then
  install -d -o ryan -g "$WWW_GROUP" -m 2775 "$WWW_ROOT"
else
  install -d -g "$WWW_GROUP" -m 2775 "$WWW_ROOT"
fi
echo "==> web root: $WWW_ROOT (owner ryan:$WWW_GROUP, setgid)"

# Per-site nginx logs live here (mounted at /var/log/sites), OUTSIDE the web
# roots so site backups/snapshots never include them. Owned like the web root.
if id ryan >/dev/null 2>&1; then
  install -d -o ryan -g "$WWW_GROUP" -m 2775 "$LOG_ROOT"
else
  install -d -g "$WWW_GROUP" -m 2775 "$LOG_ROOT"
fi
echo "==> log root: $LOG_ROOT (owner ryan:$WWW_GROUP, setgid)"

echo "==> adding admin user to www-data group (shared web-write model)"
if id ryan >/dev/null 2>&1; then
  usermod -aG www-data ryan
fi

# Small boxes: ensure swap so memory pressure doesn't OOM/thrash.
bash scripts/ensure-swap.sh

echo "==> installing Starship prompt (host shell)"
if ! command -v starship >/dev/null 2>&1; then
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin
fi

# Seed the config + init for future users, then apply to the existing
# interactive users (root + the admin user). Idempotent: the bashrc append
# is guarded so re-runs (deploy.sh calls host-setup.sh) don't duplicate it.
install -D -m 644 config/starship.toml /etc/skel/.config/starship.toml
grep -qs 'starship init bash' /etc/skel/.bashrc \
  || echo 'eval "$(starship init bash)"' >> /etc/skel/.bashrc

for user in root ryan; do
  home="$(getent passwd "$user" | cut -d: -f6)" || continue
  [ -d "$home" ] || continue
  install -D -o "$user" -g "$(id -gn "$user")" -m 644 \
    config/starship.toml "$home/.config/starship.toml"
  grep -qs 'starship init bash' "$home/.bashrc" \
    || echo 'eval "$(starship init bash)"' >> "$home/.bashrc"
done

# Group-write umask so files ryan creates in the web dirs stay editable by the
# www-data containers (matches the fpm `umask = 0002`).
if id ryan >/dev/null 2>&1; then
  home="$(getent passwd ryan | cut -d: -f6)" || true
  if [ -n "$home" ] && [ -d "$home" ]; then
    grep -qs '^umask 002' "$home/.bashrc" || echo 'umask 002' >> "$home/.bashrc"
  fi
fi

# ---- SSH key for the remote storage (site imports / backups) ----
# A single standard key (id_ed25519) is used for the storage mounts and the
# snapshot sync. Its public half must be authorised on the remote once; the
# storage-mounts step does that for you (it asks for the box password).
if id ryan >/dev/null 2>&1; then
  STORAGE_SSH_DIR="/home/ryan/.ssh"
  STORAGE_KEY_OWNER="ryan:ryan"
else
  STORAGE_SSH_DIR="/root/.ssh"
  STORAGE_KEY_OWNER="root:root"
fi
install -d -m 700 -o "$(echo "$STORAGE_KEY_OWNER" | cut -d: -f1)" -g "$(echo "$STORAGE_KEY_OWNER" | cut -d: -f2)" "$STORAGE_SSH_DIR"
if [ ! -f "$STORAGE_SSH_DIR/id_ed25519" ]; then
  echo "==> generating storage SSH key: $STORAGE_SSH_DIR/id_ed25519"
  ssh-keygen -q -t ed25519 -N "" -C "server-setup@$(hostname)" -f "$STORAGE_SSH_DIR/id_ed25519"
  chown "$STORAGE_KEY_OWNER" "$STORAGE_SSH_DIR/id_ed25519" "$STORAGE_SSH_DIR/id_ed25519.pub"
  chmod 600 "$STORAGE_SSH_DIR/id_ed25519"; chmod 644 "$STORAGE_SSH_DIR/id_ed25519.pub"
fi

echo "Host packages installed."