# Backup plan — new server → "pressabl-backups" (Hetzner Storage Box u676107)

Status: **implemented** (see §6). This document analyses the legacy backup system
in `temp-backup/`, describes what the new server needs, and documents the design
that `scripts/backup.sh` / `scripts/restore.sh` / `scripts/lib-backup.sh`
implement. Still-open decisions are noted with the default that was chosen.

## 1. Goal

Give the new containerised server (`~/server-setup`) an automated, off-site
backup system equivalent to the legacy production setup, writing to the
**"pressabl-backups"** Hetzner Storage Box **u676107** on port 23, so it can take
over from the old server.

**Method: keep the proven legacy approach** — direct `rsync` over SSH with
`--link-dest` hardlinked, dated snapshots, with a "date already exists" check so
each day is captured once. **Cadence: daily** (as the committed legacy script
actually does).

## 2. Storage-box topology

Three boxes are involved, and they have **distinct, non-overlapping roles**:

| Box | Role | Access |
|---|---|---|
| **u458814** | *primary* — holds `/home/gmail`, `/home/databases` | mounted read/write at `~/gmail`, `~/mariadbs` by `storage-mounts.sh` |
| **u513410** | *snapshot source* — holds `/home/pressabl/<date>` (the **old server's** backup chain) | **read-only** source for provisioning (`STORAGE_*`, `SNAPSHOT_ROOT=/home/pressabl`) |
| **u676107** | *pressabl-backups* — the new server's **backup target** | written by `scripts/backup.sh` (`BACKUP_*`) |

The key point: the new server **reads** site snapshots from **u513410** (the old
server's box) but **writes** its own backups to **u676107**. These are separate
boxes with separate config (`STORAGE_*` vs `BACKUP_*`) and must never be
confused — writing to u513410 would collide with the old server's chain, and
updating u458814/u513410 would break that old system.

`scripts/lib-backup.sh` therefore **does not fall back to `STORAGE_*`**: if
`BACKUP_HOST` is unset, `backup.sh` fails loudly rather than silently redirecting
backups to the old server's box.

No new key exchange is required beyond authorising the existing key on u676107,
which `scripts/storage-mounts.sh` now does (all three boxes).

## 3. Current state

### 3.1 Legacy system (`temp-backup/`)

Two generations plus helpers. The newer monolith `temp-backup/backup.sh` is the
real one; the split set under `temp-backup/backups/` is older.

**`temp-backup/backup.sh`** — run by cron on the old production box — does:

1. **Database dumps (weekly, `WEEKLY_BACKUP_DAY=1` = Monday).**
   `mysqldump -u … | gzip > /var/databases/<db>-<YYYY-MM-DD>.sql.gz` for every DB
   in `DB_NAMES`. Retention: **keep the last 4 weekly dumps plus the
   first-of-month dumps** (dates `01`–`07`); delete the rest.
2. **Getmail + config sync.**
   `getmail` delivers Gmail to `/var/gmail` (Maildir); `rsync` mirrors
   `/etc/nginx/` → `/var/www/backups/etc/nginx/` and `~/.getmail/` →
   `/var/www/backups/getmail/`.
3. **Hardlinked file snapshots (once per day).**
   `rsync` of `/var/www/` → `u513410:/home/pressabl/<YYYY-MM-DD>/` with:
   - `--link-dest=<previous dated dir>` (hardlinks unchanged files; only changed
     data costs space),
   - `--delete --size-only --no-p --no-g --no-o --omit-dir-times`,
   - `--exclude='.Trash*' --exclude='.cache' --exclude='lost+found' --exclude='*.log'`.
   - **Idempotent per day:** if `$REMOTE_BASE_PATH/<date>` already exists it exits
     (the "date-exists check"). So even under an hourly cron, the file sync ran
     only on the first invocation of each day.
   - Dedicated key `/home/ryan/.ssh/hetzner_backup`, `ssh -p 23`.

This is the method we keep. The `--link-dest` snapshots worked against u513410,
which confirms the Storage Box creates hardlinks via rsync.

**Older split set** (`temp-backup/backups/`):

- `backup-all.sh` → `backup-db.sh` (same DB dump + retention logic) then
  `backup-files.sh` (getmail; mirror `/etc/nginx` and `~/.getmail/` into
  `/var/www/backups`; then `rsync /var/www` → `u458814:/home/var/www` with
  `--ignore-existing`).
- `backup.conf` holds `DB_NAMES`, `WEEKLY_BACKUP_DAY`, `HETZNER_*`, `SSH_PORT`,
  `HETZNER_PATH`, `RSYNC_EXCLUDE`. Secrets live in the gitignored
  `backups/secrets.env`.

**Helpers:** `backup-zip.sh` (tar `/var/www` → `u458814:/home/backups/`),
`backup-temp.sh` (hardlinked snapshot of `Documents`/`Pictures`/`www` →
`u513410:/home/laptop/<date>/`), `backup-config.sh`, `connect-pressabl-hetzner.sh`,
`connect-secondary-hetzner.sh`.

### 3.2 What the new server already has

- `scripts/backup.sh` — the new producer (see §4.2).
- `scripts/restore.sh` — `--from-backup` plus the local-dump fallback.
- `server-backup.timer` — nightly 03:00, runs `scripts/backup.sh`
  (`scripts/install-systemd.sh`).
- `scripts/lib-db.sh` — `db_sql`, `db_provision`, `db_import`, `db_latest_dump`;
  DB work goes through `podman exec mariadb`.
- `scripts/lib-storage.sh` — `box_ssh`, `box_cat`, `newest_snapshot`,
  `snapshot_site_dirs` for the u513410 snapshot source.

### 3.3 Differences that matter for the redesign

- **Logs moved out of the web root** (`~/logs`, mounted at `/var/log/sites`), so
  the legacy `--exclude='*.log'` is no longer needed for site backups.
- **MariaDB runs in a container**, not on the host → dump via `podman exec`.
- **Site configs live in the repo** (`~/server-setup`, rendered into
  `nginx/nginx.conf`, `php/fpm-www.conf`, `maria/my.cnf`), not `/etc/nginx`.
- **Gmail is fetched on the new server** by `scripts/getmail.sh` (getmail6, daily
  timer) into `~/gmail` — added as a backup source (see D9).

## 4. Sources → destinations

Each local directory gets its **own hardlinked dated snapshot chain** on the
backup box u676107 (so it can be restored independently):

| Local (new server) | Remote base (**u676107**) | Snapshot |
|---|---|---|
| `~/www` (`resolve_www_root`) | `/home/www` | `/home/www/<YYYY-MM-DD>/` |
| `~/tools` (`resolve_tools_root`) | `/home/tools` | `/home/tools/<YYYY-MM-DD>/` |
| `~/mariadbs` (`DB_DUMP_DIR`) | `/home/mariadbs` | `/home/mariadbs/<YYYY-MM-DD>/` |
| `~/gmail` (getmail Maildir) | `/home/gmail` | `/home/gmail/<YYYY-MM-DD>/` |
| `~/server-setup` (the repo) | `/home/server-setup` | `/home/server-setup/<YYYY-MM-DD>/` |

`~/mariadbs` is a **new local directory** that holds the MySQL dumps (the backup
script writes them there before syncing). It is the mount point for
`u458814:/home/databases` (created by `storage-mounts.sh`); the old
`~/databases` name no longer exists.

These chains are written to u676107 and **never** to u513410 (the read-only
snapshot source), so they cannot collide with the old server's
`/home/pressabl/<date>` chain.

## 5. Design (daily `rsync --link-dest`)

### 5.1 Principles

1. **Direct `rsync` over SSH**, `--link-dest` hardlinked snapshots (as the legacy
   did successfully against u513410), one chain per source.
2. **Date-exists check per source** — skip a source if
   `/home/<name>/<YYYY-MM-DD>/` already exists (idempotent per day).
3. **Per-database gzipped dumps** into `~/mariadbs` (keeps `restore.sh` /
   `provision-site.sh` working).
4. **Reuse the existing key** `~/.ssh/id_ed25519` (authorised on u676107 by
   `storage-mounts.sh`).
5. **Systemd timer**, managed by `scripts/install-systemd.sh`, daily, with its
   own log at `/var/log/server-setup/backup.log`.
6. **Fail soft per item** (a failed DB dump doesn't abort the file snapshots).
7. **Locking** (`flock`) so runs can't overlap.
8. **Gate behind `BACKUP_ENABLED`** so the test box can't clobber the production
   chain during migration.
9. **Backup target is independent of the snapshot source** — `BACKUP_*` never
   falls back to `STORAGE_*`; a missing `BACKUP_HOST` is a hard error.

### 5.2 `scripts/backup.sh` (pseudo-flow)

```
source lib-containers.sh lib-paths.sh lib-storage.sh lib-db.sh lib-backup.sh
load .env
BACKUP_ENABLED — exit 0 with a notice if 0
DATE="$(date +%Y-%m-%d)"
SRC_WWW="$(resolve_www_root)"; SRC_TOOLS="$(resolve_tools_root)"
SRC_MARIADBS="$DB_DUMP_DIR"
SRC_GMAIL="${GMAIL_MAILDIR:-$(resolve_admin_home)/gmail}"
SRC_REPO="$(resolve_server_setup_root)"

flock -n /run/server-setup-backup.lock || { echo "already running"; exit 0; }

# 1. MySQL dumps -> ~/mariadbs (all databases, one gzipped file each)
mkdir -p "$SRC_MARIADBS"
for db in db_list:                       # see below
  podman exec mariadb mysqldump --single-transaction --quick "$db" \
    | gzip > "$SRC_MARIADBS/$db-$DATE.sql.gz"
prune old dumps (last 4 weekly + first-of-month, or per decision D3)

# 2. snapshot each source with a per-source date check + --link-dest
snapshot() {                             # local_dir  remote_name
  local src="$1" name="$2"
  local base="/home/$name" dest="$base/$DATE"
  ssh ... "test -d '$dest'" && { echo "$name: $DATE exists — skipped"; return; }
  prev = newest YYYY-MM-DD dir under $base on u676107
  ssh ... "mkdir -p '$dest'"
  rsync -az --delete --link-dest="$base/$prev" \
        --no-p --no-g --no-o --omit-dir-times \
        --exclude='.Trash*' --exclude='.cache' --exclude='lost+found' \
        -e "ssh -i $BACKUP_KEY -p $BACKUP_PORT" \
        "$src/" "$BACKUP_USER@$BACKUP_HOST:$dest/"
}

snapshot "$SRC_WWW"      www
snapshot "$SRC_TOOLS"    tools
snapshot "$SRC_MARIADBS" mariadbs
snapshot "$SRC_GMAIL"    gmail
snapshot "$SRC_REPO"     server-setup

# 3. log to /var/log/server-setup/backup.log
```

**DB list source:** derive from the site list used by provisioning
(`snapshot_site_dirs`, mapped to DB names `<domain>` with `.`/`-` → `_`) and/or
`SITE_DB_PASSWORD_*` keys in `.env`, falling back to `SHOW DATABASES` (excluding
`information_schema`, `performance_schema`, `mysql`, `sys`). "Dump all the MySQL
DBs" = one dump per database.

### 5.3 SQLite / in-place-modified files

**Do nothing (decision D8).** Hardlinked snapshots share inodes, so a file
modified in place changes in every snapshot that links to it. SQLite is rarely
used on this server, and where it is, changes are rare and the DBs are very
small — so this is accepted, exactly as the legacy system did it. No special
exclusion or separate copies.

### 5.4 Scheduling (`scripts/install-systemd.sh`)

`server-backup.timer` runs `scripts/backup.sh` daily (`*-*-* 03:00:00`,
`RandomizedDelaySec=15m`), `Type=oneshot`, with the `flock` guard. Everything
(packages, timer, script) is installed **by the repo scripts**, so future test
and production servers get it automatically on deploy — `host-setup.sh` for
packages and `install-systemd.sh` for the timer. No manual server-side steps,
and the old production server is never modified.

### 5.5 Restore (`scripts/restore.sh`)

```
sudo bash scripts/restore.sh --from-backup [DATE] [www|tools|mariadbs|server-setup|all]
  - pick DATE (default newest for the chosen source on the chosen box)
  - rsync $BASE/$DATE/ -> the matching local dir (then fix-perms.sh)
  - import DB dumps from /home/mariadbs/$DATE via lib-db.sh db_import
```

Keep the current local-`/var/databases` behaviour as the default/fallback.

### 5.6 Config variables (`.env` / `.env.example`)

```
# ---- Off-site backups (pressabl-backups / Hetzner u676107) ----
# NOTE: a different box from the STORAGE_* snapshot source (u513410).
BACKUP_ENABLED=1
BACKUP_USER=u676107
BACKUP_HOST=u676107.your-storagebox.de
BACKUP_PORT=23
#BACKUP_KEY=/home/ryan/.ssh/id_ed25519
BACKUP_REMOTE_BASE=/home          # chains at /home/www, /home/tools, ...
# Local DB dump dir (also the mariadbs backup source):
DB_DUMP_DIR=/home/ryan/mariadbs
# Server-setup repo root (defaults to this checkout):
#SERVER_SETUP_ROOT=/home/ryan/server-setup
BACKUP_WEEKLY_DAY=1
```

`BACKUP_HOST`/`BACKUP_USER` have **no fallback** to `STORAGE_*`; if unset,
`backup.sh` exits with a clear error.

### 5.7 Security

- Reuse `~/.ssh/id_ed25519`, authorised on u676107 by `storage-mounts.sh`
  (`install-ssh-key`, which appends and preserves existing keys). Never commit
  keys or `.env`.
- The `.env` in question is the repo's own **`~/server-setup/.env`** (gitignored).
  It holds server secrets: `MARIADB_ROOT_PASSWORD`, `GMAIL_APP_PASSWORD`,
  `SITE_DB_PASSWORD_*` and `OPENROUTER_API_KEY`. **Decision D2: it is included**
  — the Storage Box is private, and having `.env` in the backup means a full
  restore is possible without re-entering secrets. No exclude is applied to it.

### 5.8 Rollout / migration

1. Add scripts + config + timer with `BACKUP_ENABLED=0` on the test box.
2. Run `--dry-run`; do one real run and `stat` a file in two snapshots on
   u676107 to confirm hardlinks (link count > 1).
3. Enable on the box that should be the producer. **Never** run it from both old
   and new servers into the same chain.
4. Once verified, turn off the legacy cron on the old server.
5. Wire `scripts/restore.sh --from-backup` into the menu (`install/setup.sh`).

## 6. Decisions

- **D1 — layout.** Separate chains `/home/www`, `/home/tools`,
  `/home/mariadbs`, `/home/gmail`, `/home/server-setup` on **u676107**, each
  holding dated `<YYYY-MM-DD>/` snapshots. No collision with the legacy
  `/home/pressabl` chain on u513410.
- **D2 — `~/server-setup` contents.** **Resolved: include `.env`** (and its
  secrets) in the backup — the Storage Box is private and this enables a full
  restore without re-entering secrets. See §5.7.
- **D3 — DB cadence + retention.** Weekly dumps (Monday) with the legacy
  last-4-weekly + first-of-month retention.
- **D4 — snapshot retention.** Keep all dated snapshot chains forever (hardlinks
  are cheap in space); optional `BACKUP_KEEP_DAYS` / `BACKUP_KEEP_MONTHLY`
  pruning.
- **D5 — key.** Reuse `~/.ssh/id_ed25519`.
- **D6 — replace vs add.** Rewrite `scripts/backup.sh` / `scripts/restore.sh` and
  the `server-backup.timer` wiring.
- **D7 — coexistence.** `BACKUP_ENABLED=0` disables entirely on a box.
- **D8 — SQLite.** **Resolved: do nothing** (see §5.3).
- **D9 — getmail.** **Done** — `scripts/getmail.sh` (getmail6, daily
  `server-getmail.timer`) fetches Gmail into `~/gmail`; added as a backup source
  (→ `/home/gmail`).

## 7. Implementation checklist

- [x] `.env.example`: add the `BACKUP_*` block pointing at u676107 (independent
      of `STORAGE_*`); add `DB_DUMP_DIR=~/mariadbs`; retire `BACKUP_SSH`.
- [x] `scripts/lib-backup.sh` (new): resolve `BACKUP_*` (no `STORAGE_*`
      fallback), `db_list`, `backup_newest_snapshot`, `backup_prune_snapshots`,
      `prune_db_dumps`.
- [x] Rewrite `scripts/backup.sh` (`--dry-run`, `--db-only`, `--files-only`,
      `--force`; `flock`; per-source date check; `--link-dest`; fail-soft).
- [x] Extend `scripts/restore.sh` with `--from-backup`.
- [x] `scripts/install-systemd.sh`: `server-backup.timer` runs `scripts/backup.sh`
      daily — script logs to `/var/log/server-setup/backup.log`.
- [x] `scripts/storage-mounts.sh`: authorise the key on u676107 as well.
- [x] `README.md`: document the backup system and the three-box topology.
- [ ] Verify on a server: hardlink check on u676107, a real run, a test restore.
