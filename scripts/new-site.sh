#!/usr/bin/env bash
# =============================================================================
# new-site.sh — scaffold a brand-new site from the consolidated nginx setup.
#
#   sudo ./scripts/new-site.sh <domain> <type> [target]
#
#   type:
#     laravel    -> joined php-site.conf block (root /var/www/<domain>/public)
#     wordpress  -> WordPress Multisite block (pressabl root, DB + user created)
#     static     -> joined static-site.conf block (autoindex, /public)
#     static-spa -> joined static-spa.conf block (/public_html, index.html app)
#     redirect   -> joined redirects.conf block (needs target, e.g.
#                   https://destination.example$request_uri)
#     node       -> node-proxy.conf block (chat-style Node app)
#     node-auth  -> node-proxy.conf block, protected by Authelia forward-auth
#                   (like chat.hellyer.kiwi; remember to add the host to the
#                   access_control rule in authelia/configuration.yml)
#     static-auth-> NEW standalone block (conf.d/<domain>.conf) protected by
#                   Authelia (like storage.hellyer.kiwi). Used because
#                   auth_request is not variable-driven, so a protected host
#                   cannot join a shared server block with unprotected ones.
#     php-auth   -> NEW standalone php-site-style block protected by Authelia
#                   (like health.hellyer.kiwi).
#
# What it does:
#   1. Adds the domain to the right map + server_name list in conf.d/ (or writes
#      a whole new conf.d/<domain>.conf for the *-auth types).
#   2. Creates the web root + log dirs under the host web root (~/www).
#   3. For laravel/wordpress: creates the DB + least-privilege user
#      (user = DB name) and stores the password in .env.
#   4. Runs nginx -t and reloads nginx.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-db.sh
WWW_ROOT="$(resolve_www_root)"
LOG_ROOT="$(resolve_log_root)"

usage() {
  echo "Usage: $0 <domain> <type> [target]"
  echo "  type: laravel | wordpress | static | static-spa | redirect | node | node-auth | static-auth | php-auth"
  echo "  target: required for redirect, e.g. 'https://example.com\$request_uri'"
  echo "  *-auth types create a NEW standalone conf.d/<domain>.conf protected by"
  echo "  Authelia; also add the host to access_control in authelia/configuration.yml."
  exit 1
}

[ $# -lt 2 ] && usage
DOMAIN="$1"
TYPE="$2"
TARGET="${3:-}"

case "$DOMAIN" in
  *[!a-zA-Z0-9.-]*|'') echo "Invalid domain: $DOMAIN"; exit 1 ;;
esac

echo "==> Adding $DOMAIN ($TYPE)"

# ---- 1. Edit the nginx config (backup first, then insert) ----
NGINX_DIR="nginx" DOMAIN="$DOMAIN" TYPE="$TYPE" TARGET="$TARGET" python3 - <<'PY'
import os, re, sys

nginx_dir = os.environ["NGINX_DIR"]
domain    = os.environ["DOMAIN"]
stype     = os.environ["TYPE"]
target    = os.environ.get("TARGET", "")

# type -> (file, map name or None, root or None, server_name marker, needs target)
PLAN = {
  "laravel":   ("conf.d/php-site.conf",          "site_root",        "/var/www/%s/public" % domain,       "php-site domains",      False),
  "wordpress": ("conf.d/wordpress-multisite.conf", None,             None,                                 "wordpress domains",     False),
  "static":    ("conf.d/static-site.conf",       "static_root",      "/var/www/%s/public" % domain,       "static-site domains",   False),
  "static-spa":("conf.d/static-spa.conf",        "spa_root",         "/var/www/%s/public_html" % domain,  "static-spa domains",    False),
  "redirect":  ("conf.d/redirects.conf",         "redirect_target",  None,                                 "redirect domains",      True),
  "node":      ("conf.d/node-proxy.conf",        None,               None,                                 "node-proxy domains",    False),
  "node-auth": ("conf.d/node-proxy.conf",        None,               None,                                 "node-proxy domains",    False),
  # Standalone Authelia-protected blocks: no shared file/map/marker — a new
  # conf.d/<domain>.conf is generated instead. Mode is signalled by map_name=None
  # plus the special marker strings below.
  "static-auth": ("conf.d/%s.conf" % domain,     None,               "/var/www/%s/public" % domain,       "@standalone-static",    False),
  "php-auth":    ("conf.d/%s.conf" % domain,     None,               "/var/www/%s/public" % domain,       "@standalone-php",       False),
}
if stype not in PLAN:
    sys.exit("Unknown type: %s" % stype)

path, map_name, root, marker, needs_target = PLAN[stype]
if needs_target and not target:
    sys.exit("redirect type requires a target argument")

STANDALONE = marker in ("@standalone-static", "@standalone-php")

if STANDALONE:
    # Generate a whole new server block, protected by Authelia. Mirrors the
    # health-site.conf (php) / storage-site.conf (static) shapes.
    titles = {
      "@standalone-static": ("static file site", "public", "autoindex on;",
                             'try_files $uri $uri/ =404;', 'index index.html index.php;'),
      "@standalone-php":    ("PHP site", "public", "",
                             'try_files $uri $uri/ /index.php?$args;', 'index index.php index.html;'),
    }
    desc, _, autoindex, root_try, index_line = titles[marker]
    php_extra = ""
    if marker == "@standalone-php":
        php_extra = """
	location ~ ^/files/ {
		try_files $uri $uri/ @files_fallback;
	}
	location @files_fallback {
		rewrite ^ /index.php last;
	}

	location ~* ^/images/.*\\.php$ { return 403; }

	include /etc/nginx/snippets/static-assets.conf;

	location ~ \\.php$ {
		include /etc/nginx/snippets/fastcgi-php.conf;
		fastcgi_pass php-fpm;

		fastcgi_cache_bypass $no_cache_final;
		fastcgi_no_cache     $no_cache_final;
		fastcgi_cache PRESSABL;
		fastcgi_cache_valid 200 1m;
		fastcgi_cache_use_stale error timeout invalid_header http_500;
	}
"""
    else:
        php_extra = """
	include /etc/nginx/snippets/static-assets.conf;
"""
    block = """# =============================================================================
# {domain} — {desc} behind Authelia (generated by scripts/new-site.sh).
#
# Standalone block because auth_request is not variable-driven: a protected
# host cannot share a server block with unprotected ones. Remember to add
# '{domain}' to access_control in authelia/configuration.yml.
# =============================================================================

server {{
	listen 443 ssl http2;
	listen [::]:443 ssl http2;

	server_name {domain};

	ssl_certificate /etc/letsencrypt/live/pressabl/fullchain.pem;
	ssl_certificate_key /etc/letsencrypt/live/pressabl/privkey.pem;

	root {root};
	{index_line}
	{autoindex}

	access_log /var/log/sites/{domain}/access.log;
	error_log /var/log/sites/{domain}/error.log;

	include /etc/nginx/snippets/security-headers.conf;
	error_page 404 /404.jpg;

	# Authelia forward-auth gate (whole vhost).
	include /etc/nginx/snippets/authelia-authz-location.conf;
	include /etc/nginx/snippets/authelia-authrequest.conf;

	location / {{
		{root_try}
	}}
{php_extra}}}
""".format(domain=domain, desc=desc, root=root, index_line=index_line,
           autoindex=autoindex, root_try=root_try, php_extra=php_extra)
    filepath = os.path.join(nginx_dir, path)
    if os.path.exists(filepath):
        sys.exit("Refusing to overwrite existing %s" % filepath)
    with open(filepath, "w") as fh:
        fh.write(block)
    print("  -> wrote %s" % filepath)
    sys.exit(0)

filepath = os.path.join(nginx_dir, path)
with open(filepath) as fh:
    text = fh.read()

def insert_into_map(text, map_name, entry):
    """Insert `entry` inside the named $http_host map (after hostnames; or before })."""
    lines = text.split("\n")
    out = []
    inside = False
    inserted = False
    for ln in lines:
        if not inside and re.search(r"map \$http_host \$%s \{" % re.escape(map_name), ln):
            inside = True
            out.append(ln)
            continue
        if inside and not inserted:
            if re.match(r"\s*hostnames;\s*$", ln):
                out.append(ln)
                out.append(entry)
                inserted = True
                continue
            if ln.rstrip() == "}":
                out.append(entry)
                out.append(ln)
                inserted = True
                inside = False
                continue
        if inside and ln.rstrip() == "}":
            inside = False
        out.append(ln)
    if not inserted:
        raise RuntimeError("map %s not found or not editable" % map_name)
    return "\n".join(out)

def insert_into_server_name(text, marker, domain):
    lines = text.split("\n")
    for i, ln in enumerate(lines):
        if marker in ln:
            lines.insert(i, "\t\t%s" % domain)
            break
    else:
        raise RuntimeError("server_name marker not found: %s" % marker)
    return "\n".join(lines)

if map_name:
    entry = "\t%s      %s;" % (domain, root or target)
    text = insert_into_map(text, map_name, entry)
text = insert_into_server_name(text, marker, domain)

with open(filepath, "w") as fh:
    fh.write(text)
print("  -> edited %s" % filepath)
PY

# ---- 2. Create web root + logs (host paths; config uses /var/www + /var/log/sites) ----
case "$TYPE" in
  laravel|static|php-auth)  ROOT="$WWW_ROOT/$DOMAIN/public" ;;
  static-spa)               ROOT="$WWW_ROOT/$DOMAIN/public_html" ;;
  static-auth)              ROOT="$WWW_ROOT/$DOMAIN/public" ;;
  *)                        ROOT="" ;;
esac
if [ -n "$ROOT" ]; then
  mkdir -p "$ROOT"
  # Log dir must be group-writable by www-data (the nginx worker creates the
  # per-site *.log files); plain mkdir gives root-owned 2755 and nginx 500s.
  install -d -g www-data -m 2775 "$LOG_ROOT/$DOMAIN"
  echo "  -> created $ROOT and $LOG_ROOT/$DOMAIN"
  "$PWD/scripts/fix-perms.sh" "$WWW_ROOT/$DOMAIN"
fi

# ---- 3. Database for laravel / wordpress ----
if [ "$TYPE" = "laravel" ] || [ "$TYPE" = "wordpress" ]; then
  # Never create .env from .env.example here: deploy.sh only generates the
  # strong MARIADB_ROOT_PASSWORD when .env does NOT exist yet, so a placeholder
  # copy would silently leave the database on the example password.
  if [ ! -f .env ]; then
    echo "  !! .env not found — run scripts/deploy.sh first (it creates .env"
    echo "  !! with a generated MARIADB_ROOT_PASSWORD); then re-run new-site.sh."
    exit 1
  fi
  DB_NAME="$(printf '%s' "$DOMAIN" | tr '.-' '__')"
  DB_USER="$DB_NAME"
  DB_PASS="$(openssl rand -hex 16)"
  DB_KEY="SITE_DB_PASSWORD_$(echo "$DOMAIN" | tr '[:lower:].-' '[:upper:]___')"
  grep -q "^$DB_KEY=" .env || printf '%s=%s\n' "$DB_KEY" "$DB_PASS" >> .env
  if db_running; then
    db_provision "$DB_NAME" "$DB_USER" "$DB_PASS"
    echo "  -> created database '$DB_NAME' + user '$DB_USER' (password saved in .env as $DB_KEY)"
  else
    echo "  !! mariadb not running — database not created; re-run after the stack is up."
  fi
fi

# ---- 4. Validate + reload ----
if command -v nginx >/dev/null 2>&1; then
  nginx -t
  nginx -s reload
elif podman ps --format '{{.Names}}' | grep -q "^$CONTAINER_NGINX$"; then
  podman exec "$CONTAINER_NGINX" nginx -t
  podman exec "$CONTAINER_NGINX" nginx -s reload
else
  echo "  !! nginx not running here — run nginx -t and reload on the server."
fi

echo
echo "Site added: $DOMAIN ($TYPE)"
case "$TYPE" in
  node-auth|static-auth|php-auth)
    echo "Protected by Authelia — next steps:"
    echo "  - add '$DOMAIN' to the access_control rule in authelia/configuration.yml"
    echo "    and restart: sudo podman restart authelia"
    if [ "$TYPE" = "node-auth" ]; then
      echo "  - migrate the data dir / upstream (see nginx/conf.d/node-proxy.conf +"
      echo "    scripts/provision-openwebui.sh as the template)"
    fi
    ;;
  *)
    echo "Next steps:"
    ;;
esac
echo "  - sudo ./scripts/certbot-issue.sh   (add the domain to certbot/domains.txt if new)"
echo "  - point DNS at this host, then reload nginx."