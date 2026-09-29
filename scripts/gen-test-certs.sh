#!/usr/bin/env bash
# =============================================================================
# gen-test-certs.sh — TEST MODE ONLY: generate a temporary self-signed cert
# whose SAN list covers EVERY domain served by the nginx config, so each test
# vhost has a matching certificate (only the standard "self-signed / untrusted"
# browser warning, no name mismatch). Regenerated on every deploy; expires in
# 90 days. Production uses real certs via scripts/certbot-issue.sh instead.
#
#   sudo ./scripts/gen-test-certs.sh    (called by deploy.sh when DEPLOY_ENV=test)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-containers.sh

CERT_DIR="env/letsencrypt/live/pressabl"

# Never clobber a real (certbot-issued) cert. certbot-issued certs always ship
# chain.pem; the temporary self-signed cert does not (and certbot writes
# live/pressabl as a symlink to its archive/).
if [ -L "$CERT_DIR" ] || [ -f "$CERT_DIR/chain.pem" ]; then
  echo "Real (certbot) certificate already in place — skipping temporary self-signed cert."
  exit 0
fi

mkdir -p "$CERT_DIR"

# Collect every server_name from the joined vhost blocks.
DOMAINS="$(python3 - <<'PY'
import re, glob
domains = set()
for f in glob.glob('nginx/conf.d/*.conf'):
    txt = open(f).read()
    # Anchor to a line starting with server_name so words inside comments
    # ("add it to the server_name list ...") are never matched.
    for m in re.finditer(r'(?m)^[ \t]*server_name\s+(.*?);', txt, re.S):
        body = re.sub(r'#.*$', '', m.group(1), flags=re.M)
        for tok in body.split():
            tok = tok.strip()
            if tok and tok != '_' and '~' not in tok:
                domains.add(tok)
print('\n'.join(sorted(domains)))
PY
)"

[ -n "$DOMAINS" ] || { echo "No server_name domains found — aborting."; exit 1; }

FIRST="$(echo "$DOMAINS" | head -1)"
SANS="$(echo "$DOMAINS" | sed 's/^/DNS:/' | paste -sd, -)"

echo "==> Generating temporary self-signed cert for $(echo "$DOMAINS" | wc -l) domains (90 days)"
openssl req -x509 -nodes -newkey rsa:2048 -days 90 \
  -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
  -subj "/CN=$FIRST" \
  -addext "subjectAltName=$SANS"

chmod 600 "$CERT_DIR/privkey.pem"

podman exec "$CONTAINER_NGINX" nginx -s reload >/dev/null 2>&1 || true
echo "Temporary self-signed cert written to $CERT_DIR (SANs cover every test domain)."