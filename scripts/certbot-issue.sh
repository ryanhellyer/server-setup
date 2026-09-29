#!/usr/bin/env bash
# =============================================================================
# certbot-issue.sh — issue or renew certificates using the http01 webroot
# challenge (port 80). Which domains are issued is driven by .env:
#   CERTBOT_DOMAINS_FILE=...   default certbot/domains.txt
#                              (test: certbot/domains.test.txt)
#
# Usage:  sudo ./scripts/certbot-issue.sh [--force]
#   --force  force reissue even if a valid cert exists (rate-limit aware).
#
# All server blocks serve the same `pressabl` cert (live/pressabl). This
# script issues/renews it from certbot/domains.txt — one line per certificate
# ("<cert-name> <domains...>"), so a single line with all domains = one
# combined cert. deploy.sh/gen-test-certs.sh leave a self-signed placeholder
# there so nginx starts even before the first issuance.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-nginx.sh
[ -f .env ] && set -a && source .env && set +a
WWW_ROOT="$(resolve_www_root)"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

# The webroot exists at TWO paths: $WWW_ROOT/acme on the host, and
# /var/www/acme inside the containers (nginx serves it there; compose mounts
# the host dir onto it). certbot must be told the path it will actually see:
# the container path when run via podman, the host path when run natively.
WEBROOT_HOST="$WWW_ROOT/acme"
ACME_IN_CONTAINER="$CONTAINER_WWW/acme"
LETSENCRYPT_DIR="$PWD/env/letsencrypt"
DOMAINS_FILE="${CERTBOT_DOMAINS_FILE:-certbot/domains.txt}"
EMAIL="${CERTBOT_EMAIL:-admin@hellyer.kiwi}"

[ -f "$DOMAINS_FILE" ] || { echo "Missing $DOMAINS_FILE"; exit 1; }
mkdir -p "$WEBROOT_HOST/.well-known/acme-challenge" "$LETSENCRYPT_DIR"

if command -v certbot >/dev/null 2>&1; then
  CERTBOT=(certbot)
  CERTBOT_WEBROOT="$WEBROOT_HOST"
else
  CERTBOT=(podman run --rm -v "$LETSENCRYPT_DIR:/etc/letsencrypt" -v "$WEBROOT_HOST:$ACME_IN_CONTAINER" docker.io/certbot/certbot)
  CERTBOT_WEBROOT="$ACME_IN_CONTAINER"
fi

EXTRA=()
[ "$FORCE" = "1" ] && EXTRA=(--force-renewal)

# Issue each cert. certbot exits non-zero when nothing needed doing (e.g.
# "Certificate not yet due for renewal"), which must NOT abort the script —
# the nginx reload below has to run regardless. DNS is checked per cert: a
# cert whose domains don't resolve is skipped (clear message) so one pending
# domain doesn't block the others (e.g. one site still issues while a new
# test subdomain propagates). An IP mismatch is only a warning — certbot is the
# real judge, and its error (if any) is shown below.
PUBLIC_IP="$(curl -fsSL --max-time 10 https://ifconfig.me 2>/dev/null \
  || curl -fsSL --max-time 10 https://icanhazip.com 2>/dev/null || true)"

FAILED=0

issue_cert() {
  local line="$1" cert_name domains d ip unresolved
  cert_name="$(echo "$line" | awk '{print $1}')"
  domains="$(echo "$line" | cut -d' ' -f2-)"
  unresolved=0
  for d in $domains; do
    ip="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | head -1 || true)"
    if [ -z "$ip" ]; then
      echo "  !! $d does not resolve yet — skipping $cert_name (point DNS, then re-run)"
      unresolved=1
    elif [ -n "$PUBLIC_IP" ] && [ "$ip" != "$PUBLIC_IP" ]; then
      echo "  !! warning: $d resolves to $ip; this host reports public IP $PUBLIC_IP"
    fi
  done
  [ "$unresolved" = "1" ] && return 0

  # Clear a self-signed placeholder left by deploy.sh/gen-test-certs.sh: a real
  # certbot cert is a symlink to archive/ and ships chain.pem. If live/$name is
  # a plain dir without chain.pem it's our placeholder — remove it so certbot
  # (which writes live/<name> as its own symlink) starts clean.
  if [ -d "$LETSENCRYPT_DIR/live/$cert_name" ] && [ ! -L "$LETSENCRYPT_DIR/live/$cert_name" ] \
     && [ ! -f "$LETSENCRYPT_DIR/live/$cert_name/chain.pem" ]; then
    echo "  (removing self-signed placeholder at live/$cert_name)"
    rm -rf "$LETSENCRYPT_DIR/live/$cert_name"
  fi

  echo "==> Issuing/renewing $cert_name for: $domains"
  local args=()
  for d in $domains; do args+=(-d "$d"); done
  # --non-interactive: never prompt (e.g. "keep existing / renew & replace")
  # when a cert already exists, so the script is safe under cron/deploy.
  # `set +e` around the call so a failure doesn't abort before we report it.
  set +e
  "${CERTBOT[@]}" certonly --webroot -w "$CERTBOT_WEBROOT" \
      --cert-name "$cert_name" --expand --non-interactive "${EXTRA[@]}" \
      --email "$EMAIL" --agree-tos --no-eff-email "${args[@]}"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ ! -e "$LETSENCRYPT_DIR/live/$cert_name/fullchain.pem" ]; then
    echo "  !! certbot exited $rc and produced no certificate for $cert_name"
    FAILED=1
  elif [ "$rc" -ne 0 ]; then
    echo "  (certbot exited $rc for $cert_name but a certificate exists — continuing)"
  fi
}

while read -r line; do
  issue_cert "$line"
done < <(grep -v '^#' "$DOMAINS_FILE" | grep -v '^[[:space:]]*$')

# If issuance failed after the self-signed placeholder was removed, nginx would
# refuse to (re)start. Regenerate a placeholder so the stack stays bootable.
if [ ! -e "$LETSENCRYPT_DIR/live/pressabl/fullchain.pem" ]; then
  echo "!! No certificate at live/pressabl — regenerating a self-signed placeholder."
  bash "$PWD/scripts/gen-test-certs.sh" || true
  FAILED=1
fi

# A missing log dir (e.g. removed by provisioning's rsync --delete) makes
# nginx -t fail, which blocks the reload and leaves nginx serving the
# certificate it loaded at startup (the self-signed placeholder). Ensure the
# dirs exist, then only reload if the config is valid.
ensure_nginx_log_dirs

echo "==> Reloading nginx"
if ! reload_nginx; then
  echo "!! nginx could not be reloaded — the new certificate is NOT active."
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "!! One or more certificates could not be issued (see messages above)."
  exit 1
fi

echo "Certificates up to date."