# Certbot

TLS is issued with Let's Encrypt using the **http01 webroot** challenge on port
80. The webroot is the host's `<WWW_ROOT>/acme` (default `~/www/acme`), mounted
into the containers at `/var/www/acme`; it is served by
`nginx/conf.d/http-redirect.conf` before the HTTPS redirect.

## Automation

```bash
sudo ./scripts/certbot-issue.sh        # issue/renew every cert in domains.txt
```

## How it works

- `domains.txt` lists certificates, one per line: `<cert-name> <domain>...`.
  A single line with all the domains = one combined cert (the `pressabl` cert
  here).
- The script runs the `certbot/certbot` image (or a local certbot if present)
  for each line, storing results under `env/letsencrypt/` (which compose mounts
  read-only into nginx as `/etc/letsencrypt`).
- All server blocks reference the same **`pressabl`** cert
  (`env/letsencrypt/live/pressabl`). `deploy.sh`/`gen-test-certs.sh` drop a
  self-signed placeholder there so nginx always starts; `certbot-issue.sh`
  removes any non-certbot placeholder first, then issues/renews the real cert.

## Manual (single domain)

```bash
sudo podman run --rm \
  -v "$PWD/env/letsencrypt:/etc/letsencrypt" \
  -v "$HOME/www/acme:/var/www/acme" \
  certbot/certbot certonly --webroot -w /var/www/acme \
  --email admin@hellyer.kiwi --agree-tos --no-eff-email \
  --cert-name example.hellyer.kiwi -d example.hellyer.kiwi
```

## Notes

- Keep the `acme-challenge` location in `http-redirect.conf` on port 80.
- Renewal is automatic: `scripts/install-systemd.sh` installs the
  `certbot-renew.timer` (runs `certbot-issue.sh` 2×/day) on every deploy —
  no cron needed. The script only renews certs with <30 days left, so it
  never hits Let's Encrypt rate limits.