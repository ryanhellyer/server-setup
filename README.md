# server-setup

## TODO

~/gmail should update
Backup MariaDBs - not sure if this is working on live site yet or not

----

The containerised web stack for **hellyer.kiwi** (Nginx + PHP 8.5 + MariaDB +
Valkey + Node), deployed with Podman. Everything needed to rebuild the server
lives in this repo.

## Install on a fresh Ubuntu server — one line

```bash
curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/install/setup.sh \
  -o /tmp/setup.sh && sudo bash /tmp/setup.sh
```

That one command is fully hands-off after the two prompt types below:

1. **Installs the host tools** (podman, podman-compose, curl, openssl, nano...) plus the
   **Starship prompt** (config in `config/starship.toml`).
2. **Creates an admin user `ryan`** with your SSH key and passwordless `sudo`
   (key-only; `scripts/create-admin-user.sh`).
3. **Downloads the repo as a tarball** from GitHub (public — no git/keys needed).
4. **Opens the firewall ports** 22/80/443.
5. **Generates a standard storage key** (`~/.ssh/id_ed25519`) and authorises it on
   all three storage boxes (primary, snapshot source and the off-site backup
   box), then mounts `gmail`/`databases` under `ryan`'s home.
6. **Deploys automatically** — creates `.env` with a generated MariaDB root
   password (no editor), builds the images, brings up the whole stack, installs
   systemd units + the nightly-backup/TLS-renewal timers, then **imports every
   site (files + databases, each with its own DB user) and the Open WebUI data**
   from the newest storage snapshot. Anything in the snapshot that is *not* a
   site (backup scripts, configs, cron, old copies, misc data) is copied to
   **`~/tools`**.
7. **Issues real TLS** for the domains in `CERTBOT_DOMAINS_FILE` (test mode: the
   test domain(s)); this needs DNS pointed at the host first.

The only manual bits: **point DNS** at this host, and type each **storage box
password once** when asked (to authorise the key).

> **Where does each script run?** `install/setup.sh` (and `deploy.sh`) install on the
> machine they are **executed on** — they do not touch anything remote. Run
> `install/setup.sh` **on the server**. To install a *remote* server from your laptop,
> use `bootstrap.sh` below. (Both refuse to run on a host without `apt-get` +
> `systemd`, so a stray `install/setup.sh` on your laptop won't install anything.)

## Install / manage a remote server from your laptop

`bootstrap.sh` provisions and drives a server over SSH from your own machine.
Hetzner ships boxes with password auth, so the first contact uses the password
**once**; the script then installs your public key, creates the admin user, and
disables password auth. Running it again on the same host **updates the
server's copy of the repo** (it always runs the current `install/setup.sh` from
GitHub; see step 4). `--host` is the only required flag.

```bash
./bootstrap.sh --host 203.0.113.10        # install (new box) or update, then the menu
./bootstrap.sh --host box.example.com --no-harden
```

What it does, in order:

1. Installs your key for the login user (default `root`) — one password prompt.
2. Creates `ryan` with the same key and `NOPASSWD` sudo
   (`scripts/create-admin-user.sh`).
3. Hardens sshd — `PasswordAuthentication no`, `PermitRootLogin
   prohibit-password` (`scripts/harden-sshd.sh`). It refuses to run unless a key
   is already installed for `root` or `ryan`, so it can't lock you out.
4. Runs the **current** `install/setup.sh` from GitHub (not the server's local
   copy). On a new box that bootstraps; if the repo is already in the admin
   user's home (`~/server-setup`) it **reinstalls** — refreshes the files in
   place (tarball re-download, or `git pull` for git installs) — then opens the
   on-server menu. The refresh is **files-only**; it never re-provisions
   sites/DBs (that's menu option 1).

Flags: `--user`, `--admin-user`, `--port`, `--identity`, `--no-harden`.
`--install` is accepted for compatibility (install-or-update is now always what
runs). The password is entered by `ssh` and never stored.

> Changed your mind? `sudo bash scripts/harden-sshd.sh --revert` restores
> password authentication.

## Everything else: `sudo ./install/setup.sh`

`install/setup.sh` is the one script to remember. **Re-running it on a server
that already has the repo reinstalls the files** — it refreshes them in place
from GitHub (tarball re-download, or `git pull` for git installs), then shows an
interactive menu that delegates to the scripts in `scripts/`. The refresh is
files-only, so generated files/secrets (`.env`, rendered configs, certs) are
safe; it does **not** re-provision sites/DBs. `SETUP_NO_REFRESH=1` skips it. The
menu:

- **1)** full deploy / update the stack
- **2)** add a new site
- **3)** back up
- **4)** restore from backup

Everything else is a direct script call (the SSH login banner lists them too);
see the **Day-to-day** table below for the exact commands — TLS
(`scripts/certbot-issue.sh`), systemd units (`scripts/install-systemd.sh`), host
CLI tools (`scripts/install-cli.sh`), stack status (`pod-status`), logs
(`pod-logs`), storage boxes (`scripts/storage-mounts.sh`) and SSH hardening
(`scripts/harden-sshd.sh`).

## Manual path

```bash
sudo ./scripts/host-setup.sh          # one-time host setup (packages + dirs + swap)
mkdir -p ~/server-setup
curl -fsSL https://github.com/ryanhellyer/server-setup2/archive/refs/heads/master.tar.gz | \
  tar -xz --strip-components=1 -C ~/server-setup
cd ~/server-setup
cp .env.example .env      # scripts/deploy.sh does this (with generated secrets) automatically
sudo ./install/setup.sh                 # menu: pick "Full install / deploy / update"
```

> **Config templates:** `nginx/nginx.conf`, `php/fpm-www.conf` and `maria/my.cnf`
> are generated from their `.template` files by `scripts/render-config.sh` on
> every deploy (values from `.env`). They're not committed — edit the `.template`
> files instead. A fresh `podman compose up` without a prior deploy won't find
> them, so always go through `scripts/deploy.sh` first.

## Day-to-day

| Thing | Command |
|---|---|
| Menu: deploy, add a site, backup, restore | `sudo ./install/setup.sh` |
| Deploy / update the stack (no menu) | `sudo bash scripts/deploy.sh` (refreshes files from the tarball, keeps `.env`) |
| Refresh images + container OS packages (no data changes) | `sudo bash scripts/update.sh` (weekly `server-update.timer`) |
| Add a site (no menu) | `sudo bash scripts/new-site.sh <domain> <type>` |
| Back up (off-site snapshots + DB dumps) | `sudo bash scripts/backup.sh` |
| Restore from off-site backup | `sudo bash scripts/restore.sh --from-backup [DATE] [www\|tools\|mariadbs\|gmail\|server-setup\|all]` |
| Issue/renew TLS | `sudo bash scripts/certbot-issue.sh` |
| Fix web-dir ownership + permissions (ryan:www-data, setgid) | `sudo bash scripts/fix-perms.sh` (re-run after `restore.sh`) |
| Import every site + DB + Open WebUI (always fresh) | `sudo bash scripts/provision-all.sh` (auto-run by `deploy.sh`) |
| Restore one site fully (files + DB) | `sudo bash scripts/provision-site.sh <snapshot-dir> [--to <dir>]` |
| Restore every site found in the snapshot | `sudo bash scripts/migrate-sites.sh [--dry-run]` |
| Build a site's front-end assets (Vite) in the `node` container | `sudo bash scripts/build-assets.sh <site> [--force]` (auto-run by `provision-site.sh`) |
| Copy the snapshot's non-site files (backup scripts, configs, cron) into `~/tools` | `sudo bash scripts/provision-extras.sh [--force]` |
| Connect the storage boxes + mount `gmail`, `mariadbs` | `sudo bash scripts/storage-mounts.sh` |
| Create/refresh the admin user (`ryan`) with a key + passwordless sudo | `sudo bash scripts/create-admin-user.sh` |
| Harden SSH (keys only) / revert | `sudo bash scripts/harden-sshd.sh [--revert]` |
| Provision a remote server, or update its files + open its menu over SSH | `./bootstrap.sh --host <ip>` |
| Run CLI tools on the host (php, composer, mariadb, ffmpeg...) | `bash scripts/install-cli.sh` |
| Open a terminal in a container (defaults to the PHP box) | `pod-login [container]` |
| Install / remove the SSH login helper banner | `sudo bash scripts/install-login-help.sh [--remove]` |
| Re-apply host packages / Starship / swap / firewall / fail2ban / journald cap | `sudo bash scripts/host-setup.sh` |
| See the full architecture & rebuild plan | [`PODMAN_PLAN.md`](PODMAN_PLAN.md) |

### Host helper commands

`scripts/install-cli.sh` (run by `deploy.sh`) drops wrappers into
the admin user's `~/.local/bin` — the php/composer/mariadb/... commands above,
which self-sudo (type them without `sudo`; they proxy into the containers) —
plus these container helpers:

| Command | What it does |
|---|---|
| `pod-login [container]` | interactive shell (default `php-fpm`); mirrors cwd, auto-sudo, `-u user` |
| `pod-logs [container] [-f] [-n N]` | print / follow a container's logs (default `php-fpm`) |
| `pod-status` | fixed-order stack state + health table; exits non-zero if degraded |
| `pod-restart <container>` / `--all [-y]` | restart one container or the whole stack |
| `sites` | list the sites under `~/www` with their type and database |
| `cert-status` | TLS certificate domains + expiry (offline, via `openssl`) |

```bash
pod-login                 # root shell in php-fpm (the main PHP box)
pod-login mariadb         # root shell in the database container
pod-login -u www-data php-fpm   # as www-data, so files stay owned correctly
pod-login --list          # show the running stack containers
pod-logs nginx -f         # follow the web-server logs
pod-restart --all         # restart the whole stack
```

`pod-login` mirrors your current directory into the container when you are under
the web root (`~/www` -> `/var/www`) and runs under `sudo` automatically; it
defaults to `php-fpm` because that is where the PHP tooling (and the site files)
live.

**The same list is shown every time you log in over SSH**, along with a live
status block (backups, TLS expiry, disk, site count). `deploy.sh` installs
`/etc/update-motd.d/99-server-setup`, which Ubuntu's `pam_motd` prints on
interactive logins, and **disables the stock Ubuntu MOTD fragments** (header,
help text, landscape sysinfo, motd-news, updates-available, …) so only this
banner shows. Re-install or remove it with:

```bash
sudo bash scripts/install-login-help.sh            # (re)install the banner
sudo bash scripts/install-login-help.sh --remove   # remove it + restore Ubuntu's
```

### Automatic updates

* **Host OS:** `unattended-upgrades` installs all Ubuntu 26.04 updates daily
  (including security/ESM). If an update needs a reboot, the box reboots itself
  at **03:30** (`/etc/apt/apt.conf.d/99-server-setup-autoreboot`), and superseded
  kernels + auto-installed dependencies are cleaned up.
* **Containers:** nothing updates the images by itself — `compose up` reuses the
  local image. `server-update.timer` runs `scripts/update.sh` weekly (Sun 04:00,
  up to 30 min staggered) to pull the upstream images
  (`mariadb`/`valkey`/`open-webui`/`certbot`) and rebuild `php`/`nginx`/`node`,
  which re-runs `apt` so the Ubuntu packages *inside* the images are updated.
  It does **not** re-provision sites, so site data is untouched. Logs:
  `/var/log/server-setup/update.log`.

### Firewall (ufw) and the containers

`deploy.sh` enables ufw and sets up two things, both required because the
containers sit behind podman's NAT:

1. **Routed web ports** — `ufw route allow ... port 80/443`. Published container
   ports are DNAT'd, so inbound traffic crosses ufw's FORWARD chain; without
   this the default `deny (routed)` drops it and the box looks closed on 80/443
   (even though it answers on 22).
2. **The podman subnets** (input + routed), discovered via
   `podman network inspect`. Without this, ufw blocks the netavark DNS, so
   containers can't resolve `mariadb`/`valkey`/`open-webui` and the sites hang
   (WordPress: "Error establishing a database connection"; Laravel:
   name-resolution timeouts).

### Open WebUI resilience

`chat.hellyer.kiwi` keeps its SQLite DB on the shared volume. The container has
**no podman restart policy** — systemd supervises it with a bounded restart
(`StartLimitBurst=5`) and `CPUQuota=100%` / `MemoryMax=1536M`
(`scripts/install-systemd.sh`), so a crash-looping app can't peg a core or spin
forever. `scripts/provision-openwebui.sh` runs `PRAGMA integrity_check` on the
restored `webui.db` and moves a corrupt one aside (Open WebUI then rebuilds a
fresh DB) instead of looping.

## Where the site files live

Site files live in the **admin user's home** — `~/www` (e.g. `/home/ryan/www`),
not `/var/www` — so they sit on the home partition and survive a move to an
atomic/immutable distro such as Fedora Silverblue. Override in `.env` with
`WWW_ROOT`.

The containers still see the same files at **`/var/www`**: `compose.yaml` mounts
`${WWW_ROOT:-/home/ryan/www}:/var/www`, so the nginx config
(`nginx/conf.d/*.conf`) and the container images are unchanged. Host-side
scripts translate between the two via `scripts/lib-paths.sh`.

> **Upgrading a box that still has content in `/var/www`?** Move it once:
> `sudo install -d -o ryan -g www-data -m 2775 /home/ryan/www && sudo rsync -a /var/www/ /home/ryan/www/`,
> then `sudo bash scripts/deploy.sh` (or re-run `scripts/provision-all.sh`).

`~/www` uses a shared-hosting permission model so files stay editable both by
`ryan` (SSH) and by the containers (`www-data` — same uid/gid 33 on host and
images):

* owner `ryan`, group `www-data`; dirs `2775` (setgid), files `664`.
* `ryan` is added to the `www-data` group and gets `umask 002` in `.bashrc`
  (`scripts/host-setup.sh`).
* PHP-FPM creates files with `umask = 0002` (`php/fpm-www.conf`).
* `sudo bash scripts/fix-perms.sh` re-applies ownership/modes (idempotent, run
  automatically by `deploy.sh` and `new-site.sh`; re-run after `restore.sh`).

> **Editing PHP on the host:** changes appear within ~10 seconds — OPcache
> revalidates file timestamps every 10s (`opcache.revalidate_freq = 10` in
> `php/10-opcache.ini`). To apply one immediately, `php-reload` (graceful) or
> `sudo podman restart php-fpm`; `deploy.sh` reloads FPM automatically after
> provisioning. (A stale `wp-config.php` otherwise shows up as WordPress's
> "Error establishing a database connection" even when the DB is fine.)

## Logs

Per-site nginx logs live in the **admin user's home** — `~/logs/<site>/`
(`access.log`, `error.log`) — **outside** the web roots, so a site backup or
snapshot never includes them. Override in `.env` with `LOG_ROOT`.

The containers see them at **`/var/log/sites`** (`compose.yaml` mounts
`${LOG_ROOT:-/home/ryan/logs}:/var/log/sites`); the per-site nginx configs
(`nginx/conf.d/wordpress-multisite.conf`, `secure-site.conf`, `php-site.conf`)
point their logs there. Shared/global nginx logs stay under `/var/log/nginx`.

`server-logs.timer` runs `logrotate` **hourly** against
`/etc/logrotate-server-setup.conf`: `daily` + `maxsize 50M` + `rotate 14` +
`compress`, so a normal day rotates once while a runaway log is cut as soon as
it passes 50M. Rotation recreates the file and signals nginx to reopen it
(`podman exec nginx nginx -s reopen`).

> Application-level logs (e.g. Laravel's `storage/logs/`) are **not** managed
> here — only the nginx per-site logs.

## Gmail (getmail)

`scripts/getmail.sh` fetches mail from Gmail over IMAP (SSL) into a Maildir at
`~/gmail` using **getmail6**, and runs daily via `server-getmail.timer`:

```bash
sudo bash scripts/getmail.sh                 # write config + fetch
sudo bash scripts/getmail.sh --config-only   # just (re)write the getmailrc
```

Config lives in `.env` (`GMAIL_USER`, `GMAIL_APP_PASSWORD` — a Google **app
password**, `GMAIL_MAILDIR`, optional `GMAIL_MAILBOXES`). The `getmailrc` is
written to the admin user's `~/.getmail/getmailrc` (mode 600) and the fetch runs
as that user, so delivered files are owned correctly. `~/gmail` is normally the
sshfs mount of the storage box's `/home/gmail` share (`scripts/storage-mounts.sh`);
a plain local dir works too.

> Migrating from an old server? Copy its `~/.getmail/oldmail-*` state files
> across first, otherwise getmail re-downloads everything into the Maildir, and
> make sure only one server runs getmail at a time.

## Remote storage (snapshots, DB dumps)

Snapshots of the old `/var/www`, the weekly DB dumps and the Open WebUI data
live on remote storage (a Hetzner Storage Box by default), described by generic
`STORAGE_*` vars in `.env`:

* `STORAGE_USER` / `STORAGE_HOST` / `STORAGE_PORT` — the box.
* `STORAGE_KEY` — the SSH key (`~/.ssh/id_ed25519`, generated by
  `host-setup.sh`; authorised on the box by `storage-mounts.sh`).
* `SNAPSHOT_ROOT` — dated snapshot dirs (e.g. `/home/pressabl/2026-09-20`); the
  newest is used automatically. Pin `SNAPSHOT_DIR` to force a date.
* `SNAPSHOT_RENAMES` — map a snapshot dir to a different local dir, e.g.
  `spam-destroyer.com=spam-destroyer.hellyer.kiwi`.
* `DB_DUMP_DIR` — where the `<db>-<date>.sql.gz` dumps are (the `~/mariadbs`
  mount).

### Non-site files: `~/tools`

Sites land in `~/www`. Everything else in the newest snapshot — `backup.sh` and
friends, `sites.conf`, `nginx.conf`, `crontab.txt`, `configs/`, `acme/`, old
site copies (`*OLD*`, `*BACKUP*`, `*.bak-*`) and misc data dirs — is copied into
**`~/tools`** by `scripts/provision-extras.sh`, which `provision-all.sh` runs on
every deploy. The copied set is the exact complement of the site list (both come
from `lib-storage.sh:snapshot_site_dirs()`), so sites are never duplicated.

The copy runs **once per snapshot**: a hidden `~/tools/.snapshot` marker records
which snapshot was copied, so trimming `~/tools` by hand survives later deploys.
`--force` re-copies, `EXTRAS_EXCLUDE="name1 name2"` skips entries, and
`PROVISION_EXTRAS=0` disables the step. Files keep their permissions (so the
backup scripts stay executable); there is no `--delete`, so it never removes
anything locally.

**One-time key authorisation:** `storage-mounts.sh` installs the key on all
three boxes (asking for each box's password once) with Hetzner's `install-ssh-key`,
which appends and never replaces existing keys.

## Migrating all sites (files + databases)

`scripts/provision-site.sh` restores **one** site from the newest snapshot,
deriving everything from the site's own files (no manifest). It is **always
fresh**: files are rsynced with `--delete`, and the database is dropped,
recreated and re-imported.

1. syncs `<snapshot>/<dir>/` into `~/www/<local-dir>` (`SNAPSHOT_RENAMES`
   applies, so `spam-destroyer.com` lands in `spam-destroyer.hellyer.kiwi`);
2. detects the database from the app — Laravel `.env` (`DB_*`), **Symfony
   `.env` (`DATABASE_URL`; sqlite → skipped)**, WordPress `wp-config.php`, or
   sqlite (file only);
3. creates the DB + its **own user (named after the DB)** with a fresh random
   password and a least-privilege grant, then imports the newest
   `<db>-*.sql.gz` (DEFINER clauses are stripped so the old shared user isn't
   needed);
4. points the app at the containers (`DB_HOST=mariadb`, `REDIS_HOST=valkey`,
   `REDIS_URL=redis://valkey:6379`, `REDIS_PASSWORD=`), clears caches, fixes
   permissions, reloads nginx;
5. builds front-end assets when a site's Vite output is broken (see below).

```bash
sudo bash scripts/provision-site.sh cvs.hellyer.kiwi
sudo bash scripts/provision-site.sh spam-destroyer.com --to spam-destroyer.hellyer.kiwi
sudo bash scripts/provision-site.sh gpx.hellyer.kiwi --files-only   # SQLite app
```

### Front-end assets (Vite)

A site snapshot can contain a `public/build/manifest.json` and a `public/build/assets/`
directory from **different** Vite builds (e.g. captured mid-deploy). After a
restore the manifest points at CSS/JS files that no longer exist, so the site
serves 404s and renders unstyled. `scripts/build-assets.sh` runs `npm ci` +
`npm run build` **inside the `node` container** (which shares `~/www` at
`/var/www`) to regenerate a consistent build.

`provision-site.sh` calls it automatically for any site that ships a
`package.json` — but only when the output is actually missing/inconsistent, so
healthy sites are skipped. Force a rebuild, or build a whole snapshot:

```bash
sudo bash scripts/build-assets.sh instantattend.com           # only if broken
sudo bash scripts/build-assets.sh instantattend.com --force   # rebuild anyway
sudo bash scripts/build-assets.sh --all --force               # every Vite site
```

> There is no `npm` on the host (by design). The `npm`/`node`/`npx` wrappers from
> `scripts/install-cli.sh` proxy into the `node` container, e.g.
> `cd ~/www/instantattend.com && npm run build`.


`scripts/migrate-sites.sh` runs it across every site found in the newest
snapshot (dirs with `public/`, `public_html/`, `.env` or `wp-config.php`), and
`scripts/provision-all.sh` additionally imports the Open WebUI data — this is
what `deploy.sh` runs on **every** deploy:

```bash
sudo bash scripts/migrate-sites.sh --dry-run        # show what it would do
sudo bash scripts/provision-all.sh                  # everything, for real
```

Flags: `--files-only`, `--db-only`, `--dry-run`.

> **Every deploy is destructive to server-side data** (files, DBs and Open WebUI
> are replaced from the newest snapshot) — this box is a mirror of the backups.

> Only the databases listed in the old `backup.conf` have dumps
> (`pressabl`, `secure`, `events`, `cvs_hellyer_kiwi`, `spamannihilator`,
> `kartastrophecup`). Other apps use SQLite, or are created empty and migrated.

## Open WebUI (`chat.hellyer.kiwi`)

`chat.hellyer.kiwi` is served by **Open WebUI** — its own container, not a PHP
site. It's part of `compose.yaml` (service `open-webui`, data at
`~/www/chat.hellyer.kiwi:/app/backend/data`), and nginx proxies to it over the
`web` network (`nginx/conf.d/node-proxy.conf` → upstream `open-webui:8080`,
with WebSocket + long-timeout settings). The vhost is behind **Authelia**
(see below).

Restore/refresh its data from the storage box (newest dated snapshot):

```bash
sudo bash scripts/provision-openwebui.sh
sudo bash scripts/provision-openwebui.sh --drop-vector-db   # force ChromaDB rebuild
sudo bash scripts/provision-openwebui.sh --dry-run
```

It rsyncs `webui.db` + `uploads/` (skipping the transient `webui.db-wal`/`-shm`,
`cache/`, and the old `install.sh`/tooling), reads `OPENROUTER_API_KEY` from the
snapshot's `install.sh` into `.env` (never printed/committed), brings up the
`open-webui` service, waits for `/api/version`, and reloads nginx.

Notes: `vector_db/` is kept by default because the container path
(`/app/backend/data`) is stable; use `--drop-vector-db` if RAG/embeddings
misbehave. The container is localhost-published on `127.0.0.1:3000` for health
checks/debugging; nginx reaches it by name on the compose network.

## Authelia (forward-auth / SSO)

**Authelia** gates access to protected vhosts: `chat.hellyer.kiwi`,
`storage.hellyer.kiwi`, `invoices.hellyer.kiwi`, `admin.ryan.hellyer.kiwi`,
`health.hellyer.kiwi`, `secure.hellyer.kiwi` and `dad.hellyer.kiwi`. On
`secure`/`dad` it replaces the old HTTP basic auth. The gate is reusable for
future sites/pages.

* Container: `compose.yaml` service `authelia`, config in `authelia/`, data
  (SQLite DB + user database + notifier) at `~/www/auth.hellyer.kiwi:/data` so
  the nightly `~/www` snapshot backs it up. Sessions live in the existing
  `valkey` container. **This is a data dir, not a site root** — the portal is a
  proxy vhost (`proxy_pass` to the container), so nginx has no `root` for it
  and no other per-domain files appear under `~/www/auth.hellyer.kiwi`.
* Portal: `auth.hellyer.kiwi` (`nginx/conf.d/auth-site.conf`), on the shared
  `pressabl` TLS cert.
* nginx asks Authelia per-request via `auth_request`
  (`nginx/snippets/authelia-authz-location.conf` + `authelia-authrequest.conf`);
  unauthenticated visitors get a 302 to the portal.
* Secrets (`AUTHELIA_SESSION_SECRET`, `AUTHELIA_STORAGE_ENCRYPTION_KEY`,
  `AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET`) are generated into
  `.env` by `deploy.sh` on first run.

### Standalone setup (no full deploy)

`deploy.sh` is destructive (it re-imports every site + DB from the snapshot), so
you do **not** need it just to add Authelia. On a box that already has the stack
and `.env`:

```bash
# 1. add to .env: AUTHELIA_ADMIN_USER / _EMAIL / _PASSWORD
#    (the three AUTHELIA_* secrets must also be present — see .env.example)
# 2. create the data dir + user database and start the container:
sudo bash scripts/provision-authelia.sh
# 3. bring up / restart nginx so it picks up auth-site.conf + the snippets:
sudo podman compose up -d nginx      # or: podman compose up -d --build
# 4. portal TLS + DNS: point auth.hellyer.kiwi at this host, then
sudo bash scripts/certbot-issue.sh
```

`provision-authelia.sh` creates `~/www/auth.hellyer.kiwi` itself (it does not
depend on `deploy.sh`). Re-running it is safe: it re-hashes the password and
restarts the container.

Create the first user (hashes `AUTHELIA_ADMIN_PASSWORD` from `.env`):

```bash
# set AUTHELIA_ADMIN_USER / _EMAIL / _PASSWORD in .env, then:
sudo bash scripts/provision-authelia.sh
sudo podman logs authelia            # if it does not come up
```

To protect another vhost, add the two snippet includes to its server block (or
just its `location` for a single page) and add the host to
`access_control.rules` in `authelia/configuration.yml`, then restart authelia.

### Portal theming

The login portal is branded to match `https://ryan.hellyer.kiwi`:

* **Logo + favicon** — `authelia/assets/logo.png` and `authelia/assets/favicon.ico`.
  Authelia 4.39 reads these via `server.asset_path: '/config/assets'` (the
  `./authelia` dir is mounted at `/config`). These are the **only** image
  overrides Authelia supports; there is no custom-CSS hook.
* **Custom CSS** — because there is no CSS hook, `auth-site.conf` injects
  `<link rel="stylesheet" href="/themes/rh-theme.css">` into the portal HTML
  with `sub_filter`, and serves `/themes/` from
  `~/www/auth.hellyer.kiwi/themes/` (same-origin, so Authelia's default CSP
  already permits it; no CSP weakening). The stylesheet is
  `authelia/assets/theme.css` and targets MUI's stable `.Mui*` classes and
  palette custom properties. Font is self-hosted at
  `authelia/assets/fonts/outfit.woff2`.
* `provision-authelia.sh` copies `theme.css` + `fonts/` into
  `~/www/auth.hellyer.kiwi/themes/` on every run (owner `ryan:www-data`, dirs
  2775, files 664). Re-run it after editing the theme, then reload nginx:

  ```bash
  sudo bash scripts/provision-authelia.sh
  sudo podman exec nginx nginx -t && sudo podman exec nginx nginx -s reload
  ```

  A browser hard-refresh may be needed to pick up the new `theme.css`.

## TLS certificates

* Every server block serves the same **`pressabl`** certificate
  (`env/letsencrypt/live/pressabl`). Before a real one is issued,
  `gen-test-certs.sh` (test mode) or the deploy.sh bootstrap creates a
  self-signed placeholder there — covering every configured domain in test
  mode — so nginx always starts and every site still gets a (bypassable)
  certificate.
* The real cert is issued by `scripts/certbot-issue.sh`, driven by
  `certbot/domains.txt` — one line = one certificate, `pressabl <all domains>`.
  Test mode uses `certbot/domains.test.txt` (`pressabl
  spam-destroyer.hellyer.kiwi`). Every listed domain must have DNS pointed at
  this host before it can be issued.
* **HSTS is sent in production only.** In test mode `render-config.sh` drops
  the `Strict-Transport-Security` header, so browsers still let you proceed
  past the self-signed fallback certs (HSTS errors are non-bypassable).

## Scheduled jobs (automatic)

No cron is needed — `scripts/deploy.sh` installs systemd timers on every
install/deploy:

| Job | Schedule | Runs |
|---|---|---|
| Nightly backup | daily 03:00 | `scripts/backup.sh` |
| TLS renewal | 2×/day (renews only when <30 days left) | `scripts/certbot-issue.sh` |
| Weekly image update | Sun 04:00 | `scripts/update.sh` |
| Log rotation | hourly (caps per-site logs at 50M) | `logrotate /etc/logrotate-server-setup.conf` |
| Gmail fetch | daily 02:00 | `scripts/getmail.sh` |
| Laravel scheduler | every minute | `scripts/laravel-scheduler.sh` (`LARAVEL_SCHEDULER_SITES`) |
| WordPress cron | every 10 minutes | `scripts/wp-cron.sh` (`WP_CRON_PATH`) |

There is also one **service** (not a timer): a supervised Laravel queue worker per
site in `QUEUE_WORKER_SITES`, written as `server-queue-worker-<site>.service`
(`php artisan queue:work database`, `Restart=always`).

Check them with `systemctl list-timers 'server-backup.timer' 'certbot-renew.timer' 'server-update.timer' 'server-logs.timer' 'server-getmail.timer' 'server-scheduler.timer' 'server-wpcron.timer'` and `systemctl list-units 'server-queue-worker-*.service'`.

> **Off-site backups.** `scripts/backup.sh` writes dated, hardlinked
> `rsync --link-dest` snapshots to the "pressabl-backups" Storage Box (u676107):
> one chain per source under `$BACKUP_REMOTE_BASE/` — `www`, `tools`, `mariadbs`
> (the MySQL dumps), `gmail` and `server-setup`. It also dumps every MariaDB
> database (one gzipped file per DB) into `~/mariadbs` first. A source is
> skipped if that day's snapshot already exists. Restore with
> `scripts/restore.sh --from-backup [DATE] [source…]`.
>
> This is a **different box from the snapshot source**: the new server reads
> site snapshots from `u513410` (`STORAGE_*`, the old server's box, read-only)
> but writes its own backups to `u676107` (`BACKUP_*`). The two are deliberately
> independent — `BACKUP_HOST` never falls back to `STORAGE_HOST`.
>
> Controls in `.env`: `BACKUP_ENABLED`, `BACKUP_USER/HOST/PORT/KEY`,
> `BACKUP_REMOTE_BASE`, `BACKUP_WEEKLY_DAY`, and optional `BACKUP_KEEP_DAYS` /
> `BACKUP_KEEP_MONTHLY` pruning. See [`BACKUP_PLAN.md`](BACKUP_PLAN.md) and
> [`temp-backup/`](temp-backup/) (the legacy system it's modelled on).
