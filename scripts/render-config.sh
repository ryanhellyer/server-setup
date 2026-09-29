#!/usr/bin/env bash
# =============================================================================
# render-config.sh — render configs from templates using .env values.
#
#   nginx/nginx.conf        FASTCGI_CACHE_SIZE            (test 64m / prod 500m)
#   nginx/snippets/security-headers.conf
#                           DEPLOY_ENV                    (HSTS: prod only)
#   maria/my.cnf            MARIADB_BUFFER_POOL, MARIADB_LOG_SIZE (test 256m / prod 1G)
#   php/fpm-www.conf        PHP_FPM_MAX_CHILDREN, START_SERVERS, MIN_SPARE,
#                           MAX_SPARE, MEMORY_LIMIT       (test 20 / prod 50)
#
# Called automatically by deploy.sh before nginx -t / compose up.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] && set -a && source .env && set +a

suffix_m() { # ensure a bare number becomes Nm
  case "$1" in *[kKmMgG]) echo "$1" ;; *) echo "${1}m" ;; esac
}

# ---- nginx.conf ----
CACHE="$(suffix_m "${FASTCGI_CACHE_SIZE:-64m}")"
sed "s/__FASTCGI_CACHE_SIZE__/$CACHE/g" nginx/nginx.conf.template > nginx/nginx.conf
echo "Rendered nginx/nginx.conf (fastcgi cache keys_zone: $CACHE)."

# ---- maria/my.cnf ----
BP="$(suffix_m "${MARIADB_BUFFER_POOL:-256m}")"
LG="$(suffix_m "${MARIADB_LOG_SIZE:-64m}")"
sed -e "s/__MARIADB_BUFFER_POOL__/$BP/" -e "s/__MARIADB_LOG_SIZE__/$LG/" \
    maria/my.cnf.template > maria/my.cnf
echo "Rendered maria/my.cnf (buffer pool: $BP, log: $LG)."

# ---- nginx/snippets/ssl-params.conf (resolver address) ----
# Podman/netavark DNS lives on the network gateway (10.89.0.1 for `web`). The
# old default (Docker's 127.0.0.11) does not exist under podman, and a resolver
# pointing at a dead address makes OCSP + any variable-based proxy_pass hang.
DNS="${NGINX_DNS:-10.89.0.1}"
sed "s/__NGINX_DNS__/$DNS/g" nginx/snippets/ssl-params.conf.template > nginx/snippets/ssl-params.conf
echo "Rendered nginx/snippets/ssl-params.conf (resolver: $DNS)."

# ---- nginx/snippets/security-headers.conf (HSTS: production only) ----
# In test mode the self-signed fallback certs are used, and a
# Strict-Transport-Security header (includeSubdomains) would make browsers
# hard-refuse them instead of letting you proceed. Production keeps full HSTS.
if [ "${DEPLOY_ENV:-test}" = "test" ]; then
  HSTS=""
else
  HSTS='add_header Strict-Transport-Security "max-age=63072000; includeSubdomains; preload" always;'
fi
awk -v hsts="$HSTS" '{ gsub(/__HSTS__/, hsts); print }' \
  nginx/snippets/security-headers.conf.template > nginx/snippets/security-headers.conf
echo "Rendered nginx/snippets/security-headers.conf (HSTS: $([ "${DEPLOY_ENV:-test}" = "test" ] && echo off || echo on))."

# ---- php/fpm-www.conf ----
CH="${PHP_FPM_MAX_CHILDREN:-20}"
ST="${PHP_FPM_START_SERVERS:-4}"
MI="${PHP_FPM_MIN_SPARE:-4}"
MA="${PHP_FPM_MAX_SPARE:-10}"
ML="${PHP_FPM_MEMORY_LIMIT:-128M}"
sed -e "s/__PHP_FPM_MAX_CHILDREN__/$CH/" \
    -e "s/__PHP_FPM_START_SERVERS__/$ST/" \
    -e "s/__PHP_FPM_MIN_SPARE__/$MI/" \
    -e "s/__PHP_FPM_MAX_SPARE__/$MA/" \
    -e "s/__PHP_FPM_MEMORY_LIMIT__/$ML/" \
    php/fpm-www.conf.template > php/fpm-www.conf
echo "Rendered php/fpm-www.conf (max_children: $CH, memory_limit: $ML)."