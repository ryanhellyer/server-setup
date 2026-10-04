#!/usr/bin/env bash
# =============================================================================
# lib-nginx.sh — shared helpers for keeping nginx reloadable.
#
# nginx refuses to (re)load when a static access_log/error_log path's parent
# directory is missing. On a fresh server the log dirs are created by deploy.sh,
# but a later step (provisioning rsync --delete) can remove a site's logs/ dir.
# After that every `nginx -s reload` fails and the master keeps serving whatever
# certificate it loaded at startup — e.g. the self-signed placeholder — even
# though certbot has since issued a real one. So: always ensure the log dirs
# exist immediately before a reload, and never reload without a config test.
#
#   source scripts/lib-nginx.sh
#   ensure_nginx_log_dirs      # create every access_log/error_log dir on the host
#   reload_nginx               # nginx -t, then reload; non-zero if config invalid
#
# Requires scripts/lib-paths.sh (for www_host_path) and
# scripts/lib-containers.sh (for CONTAINER_NGINX) to be sourced first.
# =============================================================================

# Create the host-side parent directory of every access_log/error_log path the
# nginx config references. Paths are container paths (/var/www/... and
# /var/log/sites/...) mapped back to their host location via www_host_path.
# Matches any absolute *.log path (not just access_log/error_log directives),
# because per-site paths can also come from a `map` (e.g. php-site.conf's
# $site_access_log), and those are opened at request time — a missing dir means
# the log write silently fails.
#
# The dirs MUST be group-writable by www-data (owner root, group www-data, mode
# 2775): the nginx worker runs as www-data and CREATES the per-site *.log files
# itself. A plain `mkdir -p` yields root-owned 2755, which the worker cannot
# write to — nginx then fails to open $site_access_log on every request and
# answers 500 for the whole vhost (this happened to three sites on the live
# box). So apply the shared-hosting mode here too, including to dirs that
# already exist, so a deploy self-heals a bad mode.
ensure_nginx_log_dirs() {
  local dirs d host
  dirs="$( { grep -rhvE '^[[:space:]]*#' nginx/nginx.conf nginx/conf.d nginx/snippets 2>/dev/null; } \
    | grep -oE '/[A-Za-z0-9._/-]+\.log' \
    | xargs -r -n1 dirname | sort -u || true )"

  while IFS= read -r d; do
    [ -n "$d" ] || continue
    host="$(www_host_path "$d")"
    mkdir -p "$host"
    chown root:www-data "$host" 2>/dev/null || true
    chmod 2775 "$host" 2>/dev/null || true
  done <<< "$dirs"
}

# Validate the config inside the nginx container, then reload. Returns non-zero
# (with a clear message) when the config is invalid, so callers can surface the
# problem instead of silently continuing to serve a stale certificate.
reload_nginx() {
  if ! podman exec "$CONTAINER_NGINX" nginx -t; then
    echo "!! nginx configuration test failed — not reloading."
    return 1
  fi
  podman exec "$CONTAINER_NGINX" nginx -s reload
}
