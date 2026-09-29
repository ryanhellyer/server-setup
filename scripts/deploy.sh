#!/usr/bin/env bash
# =============================================================================
# deploy.sh — bring the whole stack up / update it in one command.
#
# The day-to-day entry point is ./install/setup.sh (interactive menu); this script is
# the automation-friendly path it delegates to, and it can be run directly:
#   sudo bash scripts/deploy.sh
#
# It does, in order:
#   1. Ensures the host has podman/podman-compose/git/etc. (installs them
#      automatically if they're missing — see scripts/host-setup.sh).
#   2. Creates .env from .env.example if missing, then opens it in nano for
#      you to fill in the secrets (save & exit to continue).
#   3. git pull (or re-download the files for a tarball install).
#   4. Renders nginx.conf from the template (.env-driven values).
#   5. Bootstraps a self-signed cert so nginx boots before certbot runs.
#   6. Creates log dirs the config references.
#   7. TEST MODE ONLY (DEPLOY_ENV=test): seeds placeholder sites and generates
#      a temporary self-signed cert covering every domain — skipped entirely
#      in production, so nothing needs removing for prod.
#   8. Builds the nginx image and runs nginx -t against the repo config.
#   9. podman compose up -d --build.
#   10. Installs systemd units so the stack starts at boot.
#
# After first deploy: sudo ./install/setup.sh (or scripts/certbot-issue.sh
# directly), then point DNS at this host.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-paths.sh
source scripts/lib-containers.sh
source scripts/lib-nginx.sh

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo bash scripts/deploy.sh)."; exit 1; }

# Safety: deploy.sh installs on the machine it RUNS on, never remotely. If this
# isn't an Ubuntu + systemd host you're likely on the wrong machine (e.g. a
# laptop). install/setup.sh does the same check before its menu.
if [ "${SETUP_ALLOW_UNSUPPORTED:-0}" != "1" ]; then
  if ! command -v apt-get >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo "!! This host does not look like the target Ubuntu server (needs apt-get + systemd)."
    echo "!! To install a REMOTE server from your laptop, run: ./bootstrap.sh --host <ip>"
    echo "!! (Override with SETUP_ALLOW_UNSUPPORTED=1 if you really mean to run here.)"
    exit 1
  fi
fi

# ---- 1. host packages (podman etc.) ----
if ! command -v podman >/dev/null 2>&1 || ! command -v podman-compose >/dev/null 2>&1 \
   || ! command -v curl >/dev/null 2>&1 || ! command -v tar >/dev/null 2>&1; then
  echo "==> podman/podman-compose/curl/tar not all present — installing host packages first"
  bash scripts/host-setup.sh
else
  mkdir -p /var/databases /var/cache/nginx /var/log/nginx
fi

# Allow every podman network subnet through ufw (input + routed). ufw's default
# "deny (routed)" blocks container->container DNS AND container egress during
# image builds (the default `podman` bridge) — without this, a fresh
# `podman build` can't resolve apt mirrors and fails. Subnets are discovered
# from podman, so it works whatever was assigned. Called before the build
# (covers the default `podman` net) and again after `compose up` (covers the
# project networks, which don't exist yet at build time).
ufw_allow_podman_networks() {
  command -v ufw >/dev/null 2>&1 || return 0
  command -v podman >/dev/null 2>&1 || return 0
  local net sub
  for net in $(podman network ls --format '{{.Name}}' 2>/dev/null); do
    for sub in $(podman network inspect "$net" --format '{{range .Subnets}}{{.Subnet}} {{end}}' 2>/dev/null); do
      [ -n "$sub" ] || continue
      ufw allow from "$sub"       >/dev/null 2>&1 || true
      ufw route allow from "$sub" >/dev/null 2>&1 || true
    done
  done
}

# ---- 1b. firewall: always allow the ports the site + certbot need ----
# Harmless if ufw isn't enabled; rules stay dormant until it is.
if command -v ufw >/dev/null 2>&1; then
  ufw allow 22/tcp   >/dev/null 2>&1 || true
  ufw allow 80/tcp   >/dev/null 2>&1 || true
  ufw allow 443/tcp  >/dev/null 2>&1 || true
  # Published container ports are DNAT'd, so inbound web traffic traverses
  # ufw's FORWARD chain. Without these, the default "deny (routed)" policy
  # silently drops everything to nginx: the box answers on 22 but 80/443 look
  # closed from the internet.
  ufw route allow proto tcp from any to any port 80  >/dev/null 2>&1 || true
  ufw route allow proto tcp from any to any port 443 >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  # Let the podman bridge through so image builds (podman build) can reach the
  # network — must be before step 8's build.
  ufw_allow_podman_networks
  echo "==> firewall enabled (22, 80, 443/tcp + routed web ports + podman nets)"
fi

# ---- 1c. swap: avoid OOM / thrash on small boxes ----
"$PWD/scripts/ensure-swap.sh"

# ---- 2. .env (create with generated secrets; no editor) ----
if [ ! -f .env ]; then
  cp .env.example .env
  # Generate a strong MariaDB root password (don't leave the placeholder).
  dbpass="$(openssl rand -hex 24)"
  python3 - .env "$dbpass" <<'PY'
import sys
path, val = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
for i, ln in enumerate(lines):
    if ln.startswith("MARIADB_ROOT_PASSWORD="):
        lines[i] = f"MARIADB_ROOT_PASSWORD={val}"
open(path, "w").write("\n".join(lines) + "\n")
PY
  chmod 600 .env
  echo "==> Created .env from .env.example (generated MARIADB_ROOT_PASSWORD)"
fi
# shellcheck disable=SC1091
set -a && . ./.env && set +a
DEPLOY_ENV="${DEPLOY_ENV:-test}"
echo "==> Deployment mode: $DEPLOY_ENV"

# Site files live under the admin user's home (~/www) on the host, mounted into
# the containers at /var/www (see scripts/lib-paths.sh + compose.yaml).
WWW_ROOT="$(resolve_www_root)"
mkdir -p "$WWW_ROOT"
export WWW_ROOT   # so `podman compose` mounts the same path
echo "==> Web root (host): $WWW_ROOT  (containers see it as $CONTAINER_WWW)"

# Per-site nginx logs live outside the web roots (~/logs), mounted at
# /var/log/sites, so site backups/snapshots never include them.
LOG_ROOT="$(resolve_log_root)"
mkdir -p "$LOG_ROOT"
export LOG_ROOT   # so `podman compose` mounts the same path
echo "==> Log root (host): $LOG_ROOT  (containers see it as $CONTAINER_LOG)"

# ---- 3. refresh files ----
# Tarball install (.tarball marker) -> re-download. Git clone -> git pull.
# Plain copied checkout -> deploy as-is.
echo "==> refresh files (tarball re-download, or git pull for git installs)"
if [ -f .tarball ]; then
  TARBALL_URL="$(cat .tarball)"
  LAST_SHA="$(cat .last-sha 2>/dev/null || true)"
  echo "  (tarball install — checking for updates)"

  # Resolve the live branch SHA first: SHA tarballs are immutable, so a
  # CDN-cached stale branch tarball is never used. If it matches what's
  # already applied, skip the download.
  owner=""; repo=""; branch=""
  if [[ "$TARBALL_URL" =~ ^https://github.com/([^/]+)/([^/]+)/archive/refs/heads/([^/]+)\.tar\.gz$ ]]; then
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; branch="${BASH_REMATCH[3]}"
  elif [[ "$TARBALL_URL" =~ ^https://github.com/([^/]+)/([^/]+)/archive/ ]]; then
    # Old installs wrote the resolved SHA URL to .tarball (see install/setup.sh), which
    # the refs/heads regex can't parse — so every deploy re-downloaded the same
    # pinned SHA forever. Self-heal: ask the API for the repo's default branch
    # and rewrite .tarball to the branch form.
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"
    branch="$(curl -fsSL "https://api.github.com/repos/$owner/$repo" 2>/dev/null \
      | sed -n 's/.*"default_branch": *"\([^"]*\)".*/\1/p' | head -1)"
    if [ -n "$branch" ]; then
      echo "  (repaired stale SHA-pinned .tarball -> refs/heads/$branch)"
      printf '%s\n' "https://github.com/$owner/$repo/archive/refs/heads/$branch.tar.gz" > .tarball
      TARBALL_URL="https://github.com/$owner/$repo/archive/refs/heads/$branch.tar.gz"
    else
      echo "  !! can't resolve the default branch for $owner/$repo — keeping .tarball as-is"
    fi
  fi

  if [ -n "$branch" ]; then
    sha="$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$branch" 2>/dev/null \
      | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1)"
    if [ -n "$sha" ]; then
      if [ "$sha" = "$LAST_SHA" ]; then
        echo "  (already at ${sha:0:7} — no update needed)"
        skip_refresh=1
      else
        echo "  (resolved $branch @ ${sha:0:7})"
        TARBALL_URL="https://github.com/$owner/$repo/archive/$sha.tar.gz"
      fi
    fi
  fi
  if [ "${skip_refresh:-0}" != "1" ]; then
    curl -fsSL "$TARBALL_URL" -o /tmp/server-setup.tar.gz
    tar -xzf /tmp/server-setup.tar.gz --strip-components=1 -C "$PWD"
    rm -f /tmp/server-setup.tar.gz
    [ -n "${sha:-}" ] && printf '%s\n' "$sha" > .last-sha
    REFRESHED=1
  fi
elif git rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ -n "$(git remote 2>/dev/null)" ]; then
  git pull --ff-only
  REFRESHED=1
else
  echo "  (local checkout — deploying what's here)"
fi

# The repo lives in the admin user's home (~/server-setup). A refresh extracts
# as root, which would leave root-owned files in their home — keep it owned by
# the admin user. (Only when the repo is directly under that home.)
_admin_user="$(resolve_admin_user)"
_admin_home="$(resolve_admin_home)"
if [ -n "$_admin_home" ] && [ "$(dirname "$PWD")" = "$_admin_home" ]; then
  chown -R "$_admin_user:$(id -gn "$_admin_user")" "$PWD" 2>/dev/null || true
fi

# The running copy of deploy.sh is one version behind what we just extracted.
# Re-exec the freshly-downloaded deploy.sh so the LATEST logic runs this
# invocation (DEPLOY_REEXEC guards against a loop; the .last-sha match makes
# the refresh a no-op on the re-run).
if [ "${REFRESHED:-0}" = "1" ] && [ "${DEPLOY_REEXEC:-0}" != "1" ]; then
  echo "==> files updated — re-running with the latest deploy.sh"
  exec env DEPLOY_REEXEC=1 bash "$PWD/scripts/deploy.sh"
fi

# Prefer `podman compose`, fall back to `podman-compose`.
if podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
else
  COMPOSE=(podman-compose)
fi

# ---- 4. render nginx.conf from the template (.env-driven values) ----
"$PWD/scripts/render-config.sh"

# ---- 5. bootstrap TLS cert (nginx -t needs ssl files to exist) ----
# Written to live/pressabl — every server block references this one path. In
# test mode gen-test-certs.sh regenerates it as a multi-SAN self-signed cert;
# certbot-issue.sh replaces it with the real cert.
CERT_DIR="env/letsencrypt/live/pressabl"
if [ ! -f "$CERT_DIR/fullchain.pem" ]; then
  echo "==> no TLS cert yet — generating bootstrap self-signed cert"
  mkdir -p "$CERT_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=pressabl"
fi

# ---- 6. create log dirs referenced by the nginx config ----
# nginx -t fails if a static access_log/error_log path's parent dir is missing,
# so create every log directory the config references (works on a fresh box
# before the sites have been migrated in). Re-run after provisioning too, since
# rsync --delete can remove a site's logs/ dir (see lib-nginx.sh).
echo "==> creating log directories referenced by the nginx config"
ensure_nginx_log_dirs

# ---- 7. TEST MODE: temporary certs ----
# Nothing here runs in production — set DEPLOY_ENV=production in .env and
# this step is skipped automatically (no manual code removal needed).
if [ "$DEPLOY_ENV" = "test" ]; then
  # Temporary self-signed cert whose SANs cover every vhost domain, so each
  # test site has a matching certificate. certbot replaces this in production.
  "$PWD/scripts/gen-test-certs.sh"
fi

# ---- 8. build + test nginx config ----
echo "==> build nginx image (used for config validation)"
IMAGE_ID="$(podman build -q ./nginx)"

echo "==> nginx -t against the repo config"
# --add-host: the config references upstreams by container name (open-webui),
# which resolve on the compose network but not in this throwaway container.
podman run --rm \
  --add-host open-webui:127.0.0.1 \
  -v "$PWD/nginx:/etc/nginx:ro" \
  -v "$PWD/env/letsencrypt:/etc/letsencrypt:ro" \
  -v "$WWW_ROOT:/var/www" \
  -v "$LOG_ROOT:/var/log/sites" \
  "$IMAGE_ID" nginx -t

# ---- 9. compose up ----
echo "==> bring the stack up (build + start)"
"${COMPOSE[@]}" up -d --build

# ---- 9a. let the podman networks through ufw (after compose up) ----
# ufw's default-deny blocks netavark DNS (container->container name resolution)
# and container->published-port traffic, which makes WordPress/Laravel hang on
# "Error establishing a database connection" / resolution timeouts. The compose
# networks only exist after `compose up`, so re-run the allow-list now (step 1b
# covered the default `podman` bridge used by the build).
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw_allow_podman_networks
  echo "==> ufw: allowed the podman network subnets (input + routed)"
fi

# ---- 9b. web-dir ownership + permissions (ryan:www-data, setgid) ----
# Idempotent; also catches a server that predates this step.
echo "==> apply web-dir permissions (ryan:www-data)"
"$PWD/scripts/fix-perms.sh" "$WWW_ROOT"

# ---- 9c. import every site + database + Open WebUI from the newest snapshot ----
# Always fresh: files are rsynced with --delete, databases are dropped and
# re-imported, each with its own user (named after the DB). A hard failure must
# NOT abort the deploy — print and keep going, like the certbot step below.
"$PWD/scripts/provision-all.sh" \
  || echo "==> (provisioning had failures — see above; re-run: sudo bash scripts/provision-all.sh)"

# Provisioning rsyncs with --delete and can remove a site's logs/ dir, which
# would make nginx -t fail and block the post-certbot reload (leaving the
# self-signed placeholder in place). Recreate every referenced log dir.
ensure_nginx_log_dirs

# ---- 9c-ii. clear PHP OPcache so provisioning's config rewrites take effect ----
# Provisioning rewrites wp-config.php / .env after FPM has started. They'd be
# picked up within revalidate_freq (10s) anyway, but reload now so the new DB
# credentials are live immediately (and so a config with
# validate_timestamps=0 still works). SIGUSR2 clears OPcache gracefully.
if podman container exists "$CONTAINER_PHP_FPM" 2>/dev/null; then
  echo "==> reloading php-fpm (clear OPcache after provisioning)"
  podman exec "$CONTAINER_PHP_FPM" sh -c 'php-fpm8.5 -t && kill -USR2 1' \
    || echo "  (reload failed — run: sudo podman restart php-fpm)"
fi

# ---- 9d. host CLI wrappers for the admin user ----
# php/composer/mariadb/... + pod-login (interactive shell) into ~/.local/bin.
# Idempotent; catches servers installed before this step existed.
echo "==> install host CLI wrappers (php, composer, pod-login, ...)"
"$PWD/scripts/install-cli.sh"

# ---- 9e. SSH login banner listing the host helper commands ----
echo "==> install SSH login banner (helper commands + backup/TLS/disk status)"
"$PWD/scripts/install-login-help.sh"

# ---- 10. systemd units ----
echo "==> install systemd units so the stack starts at boot"
"$PWD/scripts/install-systemd.sh"

# ---- 11. TEST MODE: issue the real TLS cert automatically ----
# Test mode configures a real Let's Encrypt cert for the domains in
# CERTBOT_DOMAINS_FILE. Requires DNS pointed at this host — certbot-issue.sh
# checks that first and tells you what to do if it isn't. The stack is up
# either way.
if [ "$DEPLOY_ENV" = "test" ]; then
  echo "==> issuing the real TLS cert (test mode)"
  if "$PWD/scripts/certbot-issue.sh"; then
    echo "==> real TLS cert issued for the test domain"
  else
    echo "==> (cert not issued — see the message above; point DNS, then re-run: sudo ./install/setup.sh)"
  fi
fi

echo
echo "Deploy complete."
echo "Next: sudo ./install/setup.sh   (menu) — or directly:"
echo "      sudo bash scripts/provision-all.sh  (re-import sites + DBs + Open WebUI)"
echo "      sudo bash scripts/certbot-issue.sh  (renew TLS certificates)"