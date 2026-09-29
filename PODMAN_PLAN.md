# Podman Migration Plan — hellyer.kiwi server

> **Historical design doc.** The current source of truth is `README.md` and the
> scripts themselves. Some details below (ionos test site, `sync-site.sh`,
> Hetzner-specific names) have since changed.

**Goal:** Move ~15 sites (Laravel + WordPress + static + Node) from a bare-metal
Ubuntu server to a fully containerised stack running under Podman, so the box can
be rebuilt from scratch in minutes, not days. Nginx remains the only web server /
reverse proxy (no Varnish).

* * *

## 1. Target architecture

Single host running Podman. Everything else runs as containers.

```
Internet -> [Nginx proxy container :80/:443]   (Certbot TLS, brotli, gzip)
              |-> PHP-FPM container(s)        (Laravel + WordPress; one shared "app" image)
              |-> Node.js container(s)        (per Node site or a shared runner)
              |-> MariaDB container           (all DBs)
              `-> Valkey container           (sessions + WP object cache; drop-in Redis fork)
```

*   One **shared PHP-FPM container** (PHP **8.5**) is enough for all sites (same
    PHP version, same extensions). Per-site PHP is only needed if a site truly
    needs a different PHP version — add an extra app container then.

*   One **MariaDB** container hosts all site DBs. One **Valkey** container shared
    by WP + Laravel. Valkey is a drop-in, RESP-compatible fork of Redis, so the
    container also answers to the legacy `redis` network alias — existing
    WP/Laravel cache configs keep working without modification.

*   **Nginx** is its own container. The whole `/etc/nginx` layout is bind-mounted
    read-only from the repo's `nginx/` directory, so the repo is the single
    source of truth.

### Container OS image choice

*   Use **ubuntu:24.04** for PHP-FPM and Nginx (24.04 LTS is stable, and what the
    PHP packages target well). PHP **8.5** comes from **packages.sury.org** (the
    canonical source — the ondrej Launchpad PPA no longer carries 8.5 for noble).

*   Node image: official **node:22 (Debian)** slim — simplest and stable.

*   Host runs **Ubuntu 26.04**. The host only needs podman, git, sshfs etc —
    nothing that lags behind on 26.04 — and all app packages live inside the
    containers (which stay on 24.04, where PHP 8.5 etc. are best supported).
    The host shell gets the **Starship prompt** (`config/starship.toml`,
    seeded by `host-setup.sh`) so SSH sessions look consistent.

* * *

## 2. Repository layout (single git repo = instant rebuild)

```
server-setup/
|-- README.md                   # one-line install + day-to-day cheatsheet
|-- install/setup.sh            # THE entry point: fresh-host installer (curl | bash) + admin menu
|-- compose.yaml                 # root docker compose: full stack
|-- .env.example                 # secrets template (copy to .env, git-ignored)
|-- nginx/
|   |-- Containerfile            # ubuntu:24.04 + nginx + brotli modules
|   |-- nginx.conf               # main config (gzip, brotli, cache, maps, upstreams)
|   |-- conf.d/                  # the JOINED server blocks (few blocks, many domains)
|   |   |-- http-redirect.conf       # port 80: ACME challenge + 301 (all domains)
|   |   |-- php-site.conf            # ONE block: all Laravel/generic-PHP sites
|   |   |-- wordpress-multisite.conf # ONE block: pressabl multisite (~20 subdomains)
|   |   |-- static-site.conf         # ONE block: chocolate, julia, stuff, mum, dad
|   |   |-- static-spa.conf          # ONE block: comicjet, historic-wordpress
|   |   |-- node-proxy.conf          # chat.hellyer.kiwi (Node)
|   |   |-- secure-site.conf         # secure.hellyer.kiwi (auth + fallback)
|   |   |-- redirects.conf           # ONE block: all 301 redirects
|   |   `-- ionos-test.conf          # TEST-ONLY vhost (remove for production)
|   |-- snippets/                # SHARED building blocks (change once -> many)
|   |   |-- ssl-params.conf          # TLS protocols, ciphers, OCSP stapling
|   |   |-- security-headers.conf    # HSTS/CSP/X-Frame etc. header set
|   |   |-- static-assets.conf       # long-cache asset locations
|   |   |-- fastcgi-php.conf         # the PHP location shared by every PHP site
|   |   `-- wordpress-locations.conf # WP multisite locations
|   |-- sites/                   # per-site override notes + test site content
|   |   `-- ionos.hellyer.kiwi/      # PHP diagnostics page (test)
|   `-- _legacy/                 # old garbled configs, kept for reference only
|-- php/
|   |-- Containerfile            # ubuntu:24.04 + php8.5-fpm (sury.org) + extensions
|   |-- 10-opcache.ini
|   |-- 20-fpm-security.ini
|   `-- fpm-www.conf
|-- maria/
|   |-- init/example.sql         # DB + user grant template (idempotent)
|   `-- my.cnf
|-- valkey/
|   `-- valkey.conf              # maxmemory 64mb (test) / via VALKEY_MAXMEMORY
|-- node/
|   `-- Containerfile
|-- certbot/
|   |-- domains.txt              # one line per certificate: "<name> <domain>..."
|   |-- domains.test.txt         # test list: only ionos.hellyer.kiwi
|   `-- README.md
|-- scripts/
|   |-- host-setup.sh             # one-time host setup (packages + dirs + swap)
|   |-- deploy.sh                 # full deploy: .env + refresh + render + nginx -t + compose up
|   |-- new-site.sh               # scaffold a site into the joined blocks
|   |-- backup.sh                 # dump DBs + archive site dirs to Hetzner
|   |-- restore.sh                # restore DBs + the web root (~/www) from the latest backup
|   |-- certbot-issue.sh          # issue/renew certs (env-driven cert list)
|   |-- install-cli.sh            # symlink host CLI wrappers into ~/.local/bin
|   |-- install-login-help.sh     # /etc/update-motd.d banner listing the helpers
|   |-- install-systemd.sh        # systemd units so the stack starts at boot
|   |-- lib-containers.sh         # SINGLE source of truth: container names + CLI map
|   `-- test-site.sh              # scaffold the ionos.hellyer.kiwi test page
|-- bin/
|   |-- pod-exec                  # run php/composer/mariadb/ffmpeg/... in the right container
|   |-- pod-login                 # interactive shell in a container (default php-fpm)
|   |-- pod-logs                  # print/follow a container's logs
|   |-- pod-status                # stack state + health table
|   |-- pod-restart               # restart one container, or the whole stack
|   |-- sites                     # list sites under ~/www with type + DB
|   `-- cert-status               # TLS certificate domains + expiry
|-- .tarball                      # (generated by install/setup.sh) marks a tarball install so
|                                 #   scripts/deploy.sh refreshes the files the same way
`-- .env                          # passwords/secrets (git-ignored)
```

Everything needed to rebuild lives in this repo. A fresh host = the
`install/setup.sh` one-liner (which installs the host packages, downloads the files as
a tarball — public repo, **no git / no SSH keys** — then presents the menu, where
"Full install / deploy / update" runs `scripts/deploy.sh`).

* * *

## 3. Nginx: consolidation ("change one block -> changes many")

The old config had **~25 near-identical server blocks** (one per domain, each with
copied-and-pasted PHP/SSL/static locations — and several conflicting backup files).

The new layout collapses those into **8 server blocks for all ~45 domains**:

| Block | Domains served | What differs per domain |
|---|---|---|
| `http-redirect.conf` | every domain (port 80) | nothing (ACME + 301) |
| `php-site.conf` | gpx, ryan, kartastrophecup.de, spam-destroyer.com, german, cvs, ai, instantattend.com | root, log path (via maps) |
| `wordpress-multisite.conf` | de, undiecar, berlin-advice, book, external-posts, facebook, forum, ice, instagram, invoices, nb, offline-demo, slapshot, tweets, wordpress, dunedinicehockey, psychedelicsocietyberlin.org, carly, admin.ryan (+ undiecar.com) | nothing (shared pressabl root) |
| `static-site.conf` | chocolate, julia, stuff, mum, dad | root (map), dad's auth (map) |
| `static-spa.conf` | comicjet.com, historic-wordpress.hellyer.kiwi | root (map) |
| `node-proxy.conf` | chat.hellyer.kiwi | — |
| `secure-site.conf` | secure.hellyer.kiwi | too different to join |
| `redirects.conf` | events, spamannihilator, hellyer/geek/random, www variants | target (map) |

**How a single change propagates to every site:**

*   **PHP version/socket** → one `upstream php-fpm` in `nginx.conf`
    (`php8.5-fpm.sock`). Edit once, every vhost follows.
*   **TLS/ciphers/OCSP** → `snippets/ssl-params.conf`, included once at the
    `http` level.
*   **Security headers** → `snippets/security-headers.conf`.
*   **PHP handling** (split-path, params, SCRIPT_FILENAME) →
    `snippets/fastcgi-php.conf`, included by every PHP location.
*   **Cache control** → maps in `nginx.conf` (single `$no_cache_final` flag used
    by every PHP block) + one shared `fastcgi_cache_key`.
*   **Static asset caching** → `snippets/static-assets.conf`.

**Per-site differences within a joined block** are expressed as `map`s
(`$site_root`, `$site_access_log`, `$static_auth_realm`) and **host-scoped
locations** guarded by a flag map (see `$ryan_extra` in `php-site.conf`). This
keeps the "one file = the source of truth" property even for the few sites that
need their own quirks.

**PHP socket note:** all three old sockets (`php8.4-fpm.sock`,
`php8.4-fpm-admin.sock`, `php8.4-fpm-ryan.sock`) are now a single
`php8.5-fpm.sock` served by the shared FPM pool, matching the single shared
PHP container.

* * *

## 4. PHP-FPM container (the workhorse)

Containerfile (base **ubuntu:24.04**, PHP **8.5** from packages.sury.org —
the ondrej PPA no longer ships 8.5 for noble; `php8.5-xml` provides DOM and
opcache is built into the core `php8.5-common`):

```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
    && curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/php.gpg \
    && echo 'deb [signed-by=/usr/share/keyrings/php.gpg] https://packages.sury.org/php/ noble main' \
       > /etc/apt/sources.list.d/php.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      php8.5-fpm php8.5-cli php8.5-mysql php8.5-mbstring php8.5-zip php8.5-intl \
      php8.5-imagick php8.5-gd php8.5-curl php8.5-xml php8.5-redis php8.5-sqlite3 \
      ffmpeg imagemagick ghostscript poppler-utils zip unzip sqlite3 \
    && curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer \
    && curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp \
       && chmod +x /usr/local/bin/wp
```

*   OPcache enabled (128M, 10000 slots, JIT 1255/64M) via `10-opcache.ini`.
*   `cgi.fix_pathinfo = 0`, `expose_php = Off` via `20-fpm-security.ini`.
*   Site files mounted from the host's `~/www` (mounted at `/var/www` in the containers).
*   FPM listens on `/run/php/php8.5-fpm.sock`, shared with the Nginx container
    through the `php-socket` volume.

* * *

## 5. Nginx container (the only thing facing the internet)

*   Ubuntu 24.04 base with the distro nginx + `libnginx-mod-http-brotli-filter`
    / `-static` (brotli on; gzip fallback also enabled).
*   The repo's `nginx/` directory is mounted read-only at `/etc/nginx` — the
    repo **is** the config.
*   Port 80 is a single catch-all block: ACME webroot challenge + unconditional
    301 to https (see `conf.d/http-redirect.conf`).
*   TLS via Certbot-managed certs under `env/letsencrypt`, mounted read-only.

**Note:** Varnish is dropped entirely. The old Varnish/8081/CNAME juggling goes
away. Let's Encrypt uses `http01` webroot on port 80 before the redirect.

* * *

## 6. Stateful services

### MariaDB

*   One container on host volume `/var/lib/mysql`.
*   Init scripts (`maria/init/*.sql`) create each DB + least-privilege user.
*   Per-site credentials live in `.env`, generated by `new-site.sh`.

### Valkey

*   One container (`docker.io/valkey/valkey:8-alpine`), a drop-in
    RESP-compatible Redis fork. `maxmemory` defaults to **64 MB** on the test
    server (2 GB RAM); set `VALKEY_MAXMEMORY=1024mb` in `.env` on production
    (legacy `REDIS_MAXMEMORY` is honoured as a fallback). Policy is
    `maxmemory-policy allkeys-lru`.
*   Runs on the **internal** container network (sessions/cache only). Also
    reachable at the legacy `redis` alias so existing WP/Laravel cache configs
    need no changes.

### NodeJS

*   One `node:22-slim` container (or one per app if you need isolation).
*   Serves Node-based sites behind Nginx (`node-proxy.conf`).

* * *

## 7. Storage / the Hetzner sshfs mounts

Keep the same remote storage, but mount at the **host level** (not inside a
container), then bind-mount into the containers. SSHFS in a container is fragile
(FUSE + device access).

*   Host: `sshfs` mounts `/var/gmail`, `/var/yandex-disk`, `/var/databases`,
    `/var/sync` via `/etc/fstab` (same options: `x-systemd.automount`, `_netdev`,
    `reconnect`, fixed IdentityFile).
*   Compose bind-mounts these into the app containers where sites need them.
*   This preserves your backup/offload mounts unchanged.

* * *

## 8. Migration of the sites

1.  Copy site files to the host layout `~/www/<domain>` (rsync from the old
    box as you already do).
2.  Dump each MariaDB/WordPress DB, load it into the container.
3.  Run `scripts/new-site.sh <domain> <type>` for each site. It adds the domain
    to the right joined block's map + `server_name`, creates the web root + logs,
    generates the DB/user (for Laravel/WP), then `nginx -t` + reloads.
4.  `nginx -t`; reload the Nginx container; request the TLS cert via
    `scripts/certbot-issue.sh` (edit `certbot/domains.txt` first).

Most sites need **no per-site nginx changes at all** — the joined block already
handles their platform.

* * *

## 9. Rebuild procedure (the whole point)

### Production

**Emergency path (no docs needed)** — installs packages, downloads the repo as a
tarball (public repo — no SSH keys, no git) and deploys, all in one command:

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/install/setup.sh \
  -o /tmp/setup.sh && sudo bash /tmp/setup.sh
```

**Stepped path** (if you want to watch each stage):

```bash
sudo ./scripts/host-setup.sh           # one-time: packages + dirs + swap
mkdir -p ~/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz | \
  tar -xz --strip-components=1 -C ~/server-setup
cd ~/server-setup
cp .env.example .env                     # fill secrets, DEPLOY_ENV=production
# apply Hetzner sshfs mounts (fstab / automount)
sudo ./install/setup.sh                   # menu: pick "Full install / deploy / update"
sudo ./scripts/certbot-issue.sh          # request TLS for every domain
sudo ./scripts/restore.sh                # restore DBs + site files from the latest backup
```

`scripts/deploy.sh` also generates and enables a `container-<name>.service` for
every container, so the stack **starts automatically at boot** and is supervised
by systemd (nginx is ordered after php-fpm, since it uses the shared FPM
socket). Compose remains the source of truth for the container definitions.

The whole stack comes up from the repo in **under ~30 minutes once base images
are cached**.

### Test server (2 GB box)

Point DNS `ionos.hellyer.kiwi` → this box's IP **first** (the only manual
step), then everything is automatic:

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/install/setup.sh \
  -o /tmp/setup.sh && sudo bash /tmp/setup.sh
```

That one command installs packages, creates user `ryan`, downloads the files,
opens firewall ports 22/80/443, builds + starts the whole stack, installs
systemd units, and issues the real ionos cert (DNS-checked; if DNS isn't
propagated yet it says so and you just re-run `sudo ./install/setup.sh`). Then open
`https://ionos.hellyer.kiwi`.

Stepped equivalent:

```bash
sudo ./scripts/host-setup.sh
mkdir -p ~/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz | \
  tar -xz --strip-components=1 -C ~/server-setup
cd ~/server-setup
cp .env.example .env                     # keep DEPLOY_ENV=test
sudo ./install/setup.sh                   # menu: pick "Full install / deploy / update"
sudo ./scripts/test-site.sh              # scaffold the ionos.hellyer.kiwi test page
# point DNS ionos.hellyer.kiwi at this box, then open https://ionos.hellyer.kiwi
```

The repo lives at **`~/server-setup`** (e.g. `/home/ryan/server-setup`) — inside
the admin user's home, on the persistent home partition, so it survives an OS
reinstall and keeps the systemd units (`scripts/install-systemd.sh`) and CLI
wrappers (`bin/pod-exec`) resolving correctly across reboots and sessions.

In test mode the box is lightweight by design:

*   **Valkey** capped at **64 MB** (`VALKEY_MAXMEMORY` in `.env`).
*   **TLS** is only handled for **ionos.hellyer.kiwi**
    (`CERTBOT_DOMAINS_FILE=certbot/domains.test.txt`). `certbot-issue.sh`
    issues that one cert and symlinks it into the cert path every vhost
    references — other domains still resolve but show a cert warning (expected
    on a test box).
*   The **ionos.hellyer.kiwi** vhost (`nginx/conf.d/ionos-test.conf`, delete
    for production) serves a PHP diagnostics page that proves nginx -> php-fpm
    -> Valkey/MariaDB networking, PHP extensions, ffmpeg and OPcache all work.

* * *

## 10. Security hardening

Applied **in this repo** (ships with the config):

*   **TLS**: TLSv1.2 + TLSv1.3 only, ECDHE-only cipher suite, strong ECDH curves,
    OCSP stapling, session tickets off, `server_tokens off` (`snippets/ssl-params.conf`).
    Regenerate a 2048-bit dhparam if you ever enable DHE:
    `openssl dhparam -out /etc/nginx/dhparam.pem 2048`.
*   **Headers**: HSTS (63072000s, includeSubdomains, preload), `X-Frame-Options
    SAMEORIGIN`, `nosniff`, Referrer-Policy, Permissions-Policy, X-XSS-Protection
    (`snippets/security-headers.conf`).
*   **PHP**: `cgi.fix_pathinfo = 0`, `expose_php = Off`, `display_errors = Off`,
    plus nginx-side `try_files $uri =404` before FastCGI
    (`snippets/fastcgi-php.conf`, `php/20-fpm-security.ini`).
*   **Filesystem hygiene**: `.git` access routed away, direct `blogs.dir` blocked,
    PHP execution under `/images/` denied, no access logs for static assets.
*   **Least-privilege DB**: one DB + limited-grant user per site
    (`maria/init/example.sql`).
*   **Secrets**: passwords only in `.env` (git-ignored); `.env.example` is the
    only committed copy.

Applied **at deploy time** (documented here so you don't forget):

*   **Host firewall**: `sudo ufw allow 22,80,443/tcp && sudo ufw enable`.
*   **SSH**: disable password login + root login in `/etc/ssh/sshd_config`;
    use SSH keys only. Optionally fail2ban for the whole box.
*   **Unattended-upgrades** on the **host only** (`sudo apt install
    unattended-upgrades`) — containers stay frozen; you update them by rebuilding
    the repo.
*   **Swap** on low-RAM hosts: `fallocate -l 2G /swapfile` still recommended.
*   **MariaDB**: bind to the internal container network only (never publish port
    3306 to the host). Already the case in `compose.yaml`.
*   **Backups off-host**: `scripts/backup.sh` offloads nightly dumps + a site
    archive to the Hetzner storage box.
*   **TLS renewal**: auto-scheduled — `install-systemd.sh` installs the
    `certbot-renew.timer` (2×/day) on every deploy.
*   **Monitoring**: `podman ps` in a cron job, plus watch `/var/log/nginx/error.log`.

* * *

## 11. Automation (everything scriptable is scripted)

| Script | What it does |
|---|---|
| `install/setup.sh` | THE entry point. Fresh host (curl\|bash): installs packages, creates the admin user, downloads the repo as a tarball (public repo — no git/keys), authorises the storage key + mounts, runs the first deploy (which imports all sites/DBs/Open WebUI), then presents the menu (deploy / new site / backup / restore / certs / systemd / CLI tools / status / logs). |
| `scripts/host-setup.sh` | Installs the host package set + the Starship prompt (binary + `config/starship.toml` seeded to `/etc/skel` and the `ryan`/`root` users) + creates bind-mount dirs + ensures swap (called by install/setup.sh and auto by deploy.sh). |
| `scripts/deploy.sh` | Full deploy: auto-installs podman if missing, opens firewall ports 22/80/443, creates `.env` with generated secrets, refreshes files (git pull OR tarball re-download), renders nginx config, `nginx -t`, `compose up -d --build`, systemd units, and in test mode auto-issues the real cert. |
| `scripts/new-site.sh` | Adds a domain to the right joined block (map + `server_name`), creates web root/logs, generates DB + user + `.env` password (Laravel/WP), validates + reloads nginx. |
| `scripts/backup.sh` | Dumps all DBs, archives the web root (`~/www`), prunes 14 days, rsyncs to Hetzner. |
| `scripts/restore.sh` | Restores the latest DB dump + the web root archive from `/var/databases` (no-op if none exist yet). |
| `scripts/certbot-issue.sh` | Checks DNS is pointed at this host (clear error if not), then issues/renews certs from `CERTBOT_DOMAINS_FILE` (test = `domains.test.txt`) via the webroot challenge; links the cert into the path nginx serves. |
| `scripts/lib-storage.sh` / `lib-db.sh` / `lib-env.sh` | Shared helpers: generic storage config + snapshot discovery/rename, MariaDB provisioning (per-site users) and KEY=value edits. |
| `scripts/provision-site.sh` | Restores one site (files + DB) from the newest snapshot, always fresh; detects Laravel/Symfony/WordPress/SQLite; gives each DB its own user + password. |
| `scripts/migrate-sites.sh` | Runs provision-site across every site found in the newest snapshot. |
| `scripts/build-assets.sh` | Builds a site's front-end assets (`npm ci` + `npm run build`) inside the `node` container; only rebuilds a site when its Vite manifest/assets are missing or inconsistent (or with `--force`). Called by provision-site.sh. |
| `scripts/provision-all.sh` | `migrate-sites --all` + `provision-openwebui` — run by deploy.sh on every deploy. |
| `scripts/provision-openwebui.sh` | Restores the Open WebUI (chat.hellyer.kiwi) data and starts its container. |
| `scripts/storage-mounts.sh` | Authorises the storage key on all three boxes (primary, snapshot source, backup) + mounts `gmail`/`databases`. |
| `scripts/install-cli.sh` | Installs host-side CLI wrappers (see below). |
| `scripts/install-systemd.sh` | Generates + enables `container-*.service` units so the stack auto-starts at boot (called by deploy.sh). |

### Running CLI tools from the host

Nothing (php, composer, mariadb, ffmpeg, valkey-cli, node…) is installed on the
host — it all lives in the containers. To still type those commands on the host,
the repo ships a thin dispatcher (`bin/pod-exec`) that wraps `podman exec`:

`deploy.sh` runs `install-cli.sh` on every deploy, so the wrappers (and
`pod-login`) are already there. To (re)install them by hand:

```bash
./scripts/install-cli.sh                  # symlinks into the admin user's ~/.local/bin
                                          # + adds it to their ~/.bashrc PATH
```

Then, from the host (as root):

| Command | Runs inside | Notes |
|---|---|---|
| `php`, `composer` | php-fpm | as `www-data`; cwd mirrored when you're under `~/www` (mapped to `/var/www`) |
| `artisan <cmd>` | php-fpm | `php artisan …` in the current site dir |
| `wp <cmd>` | php-fpm | WP-CLI (now in the PHP image) |
| `ffmpeg`, `ffprobe` | php-fpm | |
| `convert`, `identify`, `compare`, `montage` | php-fpm | ImageMagick 6 CLI |
| `zip`, `unzip`, `sqlite3`, `gs`, `pdftoppm` | php-fpm | archive / SQLite / PDF tools |
| `php-reload` | php-fpm | graceful FPM pool reload (`php-fpm8.5 -t` then USR2 to master) |
| `mysql`, `mariadb` | mariadb | root creds pulled from `.env` automatically |
| `mysqldump`, `mariadb-dump` | mariadb | adds `--single-transaction` |
| `valkey-cli` | valkey | `redis-cli` works too (compat alias) |
| `node`, `npm`, `npx` | node | |
| `nginx -t`, `nginx -s reload`, `nginx-reload` | nginx | test config / graceful reload (no downtime) |
| `nginx-restart` | nginx | full container restart (`podman restart nginx`) — **drops connections** |
| `pod-exec <container> <cmd>` | any | escape hatch for arbitrary commands |
| `pod-login [container]` | any (default php-fpm) | interactive shell; mirrors cwd, runs under sudo, `-u user` to pick the login user |
| `pod-logs [container]` | any (default php-fpm) | print (`-n N`) or follow (`-f`) a container's logs |
| `pod-status` | — | fixed-order state/health table; exits non-zero if any container is down |
| `pod-restart <container>` / `--all [-y]` | any | restart a container or the whole stack |
| `sites` | host files | list sites under `~/www` with detected type + database |
| `cert-status` | host files | TLS certificate domains + expiry (offline, `openssl`) |

This list is also installed as an SSH login banner
(`/etc/update-motd.d/99-server-setup` via `scripts/install-login-help.sh`), so it
is shown by `pam_motd` on every interactive login.

Example session:

```bash
sudo -i
cd ~/www/some-site && composer install && artisan migrate
wp --path=/var/www/pressabl/public_html core version
mysqldump pressabl | gzip > /var/databases/pressabl.sql.gz
ffmpeg -i video.mov video.webm
valkey-cli ping
nginx -t && nginx-reload     # test + graceful reload after editing a server block
php-reload                   # reload FPM pool config after changing fpm-www.conf
convert input.png -resize 800x output.jpg
pdftoppm -png -r 150 doc.pdf page
```

* * *

## 12. Decisions

Confirmed — these are locked in and reflected throughout this plan:

*   **Host release: 26.04.** The host only runs podman/git/sshfs etc. — nothing
    that lags behind on 26.04; all app packages live in the 24.04-based
    containers.
*   **One shared PHP-FPM, all PHP 8.5.** A single `php8.5-fpm.sock` served by one
    FPM pool/container. A second PHP container is added only if a site ever
    truly needs a different version.
*   **Orchestration: `podman compose`.** `scripts/deploy.sh` prefers `podman
    compose` and falls back to `podman-compose` if it isn't available.
*   **Boot-start: systemd units.** `scripts/deploy.sh` generates + enables
    `container-*.service` units so the stack comes up automatically on reboot.

* * *

## 13. Sizing — test (2 GB / 1 core) vs production (16 GB / 8 cores)

Everything is driven from `.env`; the repo ships 2 GB-safe defaults. Set these
for production:

| Component | Test default (2 GB / 1 core) | Production (16 GB / 8 cores) |
|---|---|---|
| `FASTCGI_CACHE_SIZE` | `64m` | `500m` |
| `MARIADB_BUFFER_POOL` | `256m` | `8G` |
| `MARIADB_LOG_SIZE` | `64m` | `1G` |
| `PHP_FPM_MAX_CHILDREN` | `20` | `50` |
| `PHP_FPM_START_SERVERS` | `4` | `8` |
| `PHP_FPM_MIN_SPARE` | `4` | `8` |
| `PHP_FPM_MAX_SPARE` | `10` | `30` |
| `PHP_FPM_MEMORY_LIMIT` | `128M` | `256M` |
| `VALKEY_MAXMEMORY` | `64mb` | `1024mb` |
| `SWAP_SIZE` | `2G` (auto-created if none) | optional safety net; not required |

Notes:

*   **Rule of thumb:** MariaDB buffer pool ≈ 50–70% of RAM, but keep headroom
    for PHP-FPM (children × memory_limit) + Valkey + nginx + the OS. `8G` on a
    16 GB box leaves room for 50 PHP workers at 256M (~12.8 GB worst case, far
    less in practice).
*   **CPU:** nginx uses `worker_processes auto` (one per core), PHP-FPM
    `pm = dynamic` — on 8 cores, bump `PHP_FPM_START_SERVERS`/`MAX_SPARE` so
    spare workers cover bursts without spinning up.
*   **Host:** production should have real (not just swap) RAM for the DB; add a
    small swapfile as an OOM safety net only.
*   **PHP image note:** workers each hold up to `PHP_FPM_MEMORY_LIMIT`; if a
    site needs more, raise it and increase children accounting accordingly.

Apply on production by setting the values in `.env` (with
`DEPLOY_ENV=production` and `CERTBOT_DOMAINS_FILE=certbot/domains.txt`), then
`sudo bash scripts/deploy.sh` — `render-config.sh` regenerates `nginx.conf`,
`maria/my.cnf` and `php/fpm-www.conf` from them.