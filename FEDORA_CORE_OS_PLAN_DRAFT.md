# Fedora CoreOS Port — Plan (DRAFT)

> **DRAFT — not implemented.** This is a design document for review. Nothing here
> is reflected in the scripts yet; the open questions in §11 need answers before
> work starts. The current source of truth remains `README.md` + the scripts.

**Goal:** make this stack installable and runnable on **Fedora CoreOS (FCOS)**,
without giving up the current Ubuntu path. The containerised stack is already
portable; the work is entirely in the **host-provisioning layer**, which today
assumes a mutable Debian/Ubuntu box.

The guiding idea: **keep the FCOS host pristine** (no `rpm-ostree` layering, no
reboot) and **delegate every non-default tool into a container** — the same trick
Bluefin OS uses. FCOS ships Podman, so a container with access to the host paths
can supply `rsync`, `python3`, `openssl`, `ssh`, etc. on demand.

* * *

## 1. Scope

**In scope**
- Run `install/setup.sh` → `deploy.sh` → `provision-all.sh` end-to-end on FCOS.
- A "tools" container that provides the host-side command set (like Bluefin's
  container with full home access).
- Boot-start via systemd (Quadlet on FCOS).
- Firewall, swap, admin-user, and storage-mount differences.

**Out of scope (for now)**
- Replacing Ubuntu support. Ubuntu stays the default; FCOS is an added target.
- Changing the application containers (`nginx`, `php`, `node`, `mariadb`,
  `valkey`, `open-webui`) or the site/DB provisioning logic — those are portable.
- Ignition/Butane as the *primary* provisioning path (see §11 Q5).

* * *

## 2. Why FCOS is different

| Area | Ubuntu assumption (today) | Fedora CoreOS reality |
|---|---|---|
| Packages | `apt-get install` (`host-setup.sh:20-36`) | immutable `/usr`; `rpm-ostree install` **+ reboot**, or run the tool in a container |
| SELinux | ignored | **enforcing** — bind mounts need `:Z`/`:z` or `label=disable` |
| Firewall | `ufw` (`deploy.sh:56-62`) | `firewalld` (enabled by default) |
| Swap | swapfile (`ensure-swap.sh`) | **swap unsupported** (zram only) |
| Compose | `podman-compose` | not installed; `podman compose` needs an external provider |
| systemd units | `podman generate systemd` (`install-systemd.sh:36-65`) | deprecated → **Quadlet** (`.container`) is the supported path |
| Base tools | python3/rsync/sshfs/nano present | **absent** (curl/tar/openssl/ssh/`useradd`/`visudo` present) |
| Bootstrap | password SSH as `root` | Ignition/Butane, user `core`, typically **key-only** |
| OS updates | `unattended-upgrades` | `zincati` (automatic, atomic) |
| Cron | cron | **no cron** — systemd timers (already used — good) |

* * *

## 3. Design principles

1. **Pristine host.** Only use what FCOS already has: `podman`, `systemd`,
   `firewalld`, coreutils, `openssl`, `ssh`, `useradd`/`usermod`, `visudo`.
   Everything else comes from a container. **No `rpm-ostree`, no reboot.**
2. **Explicit delegation for automation.** Scripts must *not* depend on a shell
   hook. `command_not_found_handle` only exists in shells that source it;
   systemd runs `bash scripts/deploy.sh` as a non-login, non-interactive shell,
   so the hook is undefined there. Scripts call the tools wrapper explicitly.
3. **Optional interactive sugar.** A `command_not_found_handle` pointing at the
   same tools container, for humans at a prompt only (§6.4).
4. **Paths are mounted, not translated, for scripts.** Mount host directories at
   **identical paths** inside the tools container (`/home/ryan/server-setup` →
   `/home/ryan/server-setup`, `/home/ryan` → `/home/ryan`). Then an absolute host path
   is valid unchanged, and the whole class of translation bugs disappears.
   A configurable translation map still exists so a Bluefin-style
   `$HOME → /workspace` layout can be supported for interactive use (§5.3).
5. **Keep Ubuntu working.** Add an OS abstraction (`lib-os.sh`) and branch; do
   not delete the apt path.

* * *

## 4. Target architecture

```
Fedora CoreOS host  (pristine: podman + systemd + firewalld only)
  |
  |-- /home/ryan/server-setup      repo (persists: on the home partition)
  |-- /home/ryan/www               web root (persists)
  |-- /var/lib/mysql               MariaDB data (persists)
  |
  |-- tools container (ephemeral, `podman run --rm`)
  |     mounts: repo, $HOME, /var/lib/mysql, snapshot source, SSH key
  |     provides: rsync, python3, openssh-client, openssl, tar, ...
  |
  `-- stack containers (via Quadlet or compose)
        nginx :80/:443  php-fpm  node  mariadb  valkey  open-webui
```

* * *

## 5. The tools container

### 5.1 Contents

New `tools/Containerfile` (small; Debian slim or Fedora minimal), or extend the
existing `php/Containerfile`. It must provide at least:

| Tool | Used by |
|---|---|
| `rsync` | `backup.sh:44`, `provision-site.sh:81`, `provision-openwebui.sh:74`, `deploy.sh:240`, `lib-storage.sh` |
| `python3` | `deploy.sh:72`, `lib-env.sh:15`, `provision-site.sh:101`, `new-site.sh:50`, `gen-test-certs.sh:28` |
| `openssh-client` | storage-box sync/mounts (`lib-storage.sh`, `storage-mounts.sh`) |
| `openssl` | cert bootstrap (`deploy.sh:182`, `new-site.sh:146`) — FCOS already has this |
| `tar`, `gzip` | file transport — FCOS already has these |
| `sshfs` | **only if** persistent mounts are kept (see §5.5) |

Recommendation: a **dedicated `tools` image** (Debian slim + `rsync`,
`openssh-client`, `python3-minimal`, `openssl`) rather than reusing the heavy PHP
image — it is small, fast to start, and decoupled from the PHP build.

### 5.2 Explicit wrapper

Extend `bin/pod-exec` with an ephemeral-run mode (it currently only `podman exec`s
into a *running* container):

```
# host-side, root
pod-run [--user UID:GID] [--mount SRC:DST[:opts]]... <tool> [args...]
```

- Runs `podman run --rm` from the tools image.
- Mounts the repo, `$HOME`, `/var/lib/mysql`, the snapshot source, and the
  storage SSH key read-only as needed.
- `--network host` for rsync-over-SSH to the storage boxes.
- Default mounts at **identical host paths** (§3.4).

Scripts then replace bare `rsync`/`python3`/`openssl` calls with `pod-run …`
**on FCOS only**, via `lib-os.sh`:

```sh
# lib-os.sh
if is_fcos; then
  rsync() { pod-run rsync "$@"; }
  # or: TOOL_RSYNC="pod-run rsync"
fi
```

### 5.3 Path handling

Two supported layouts:

- **Identity (default, for scripts):** mount host dirs at the same path.
  `~/www/x` is `~/www/x` in the container. No translation. Safest.
- **Bluefin-style (optional, interactive):** mount `$HOME` at a root such as
  `/workspace` and translate the prefix, mirroring the user's current setup:

  | Host | Container |
  |---|---|
  | `/home/ryan` | `/workspace` |

  A `to_container_path()` helper (akin to the existing `www_host_path()` in
  `lib-paths.sh`) does the rewrite. Only used when the layout is enabled.

### 5.4 Interactive hook (optional)

In `/etc/profile.d/zz-tools-container.sh` (and `~/.bashrc`):

```bash
command_not_found_handle() {
  pod-run -- "$@" 2>/dev/null || { printf 'not found: %s\n' "$1" >&2; return 127; }
}
```

Caveats to document in the script header: interactive only; slow (container per
miss); can mask typos; **never** relied on by automation.

### 5.5 sshfs — the one outlier

FUSE mounts live in the container's mount namespace, so a **host-visible** sshfs
from a container needs `--privileged` + mount propagation — fragile. Two options:

- **(a) Keep persistent mounts:** layer `fuse-sshfs` (one small reboot) and keep
  `/etc/fstab` automounts as today.
- **(b) On-demand (recommended):** drop the persistent `~/gmail` / `~/databases`
  mounts and fetch over SSH with `pod-run rsync` when needed (the snapshot sync
  already works this way). No host package, no reboot.

* * *

## 6. Component-by-component change list

| File | Change | Effort |
|---|---|---|
| `scripts/lib-os.sh` | **New.** `is_fcos()`/`is_debian()`, tool indirection (`pod-run` vs native), firewall + swap helpers | M |
| `scripts/host-setup.sh` | Replace `apt-get` block with OS branch; on FCOS: no packages, just dirs + Starship + key. Drop `ufw`/`unattended-upgrades`/`nano` | L |
| `scripts/deploy.sh` | OS guard accepts FCOS; `ufw` → `firewalld`; `python3`/`rsync`/`openssl` via `pod-run`; compose-provider selection; `podman run` mounts get `:Z` | L |
| `scripts/install-systemd.sh` | **Rewrite unit generation** to Quadlet on FCOS; keep `podman generate systemd` on Ubuntu; timers unchanged | L |
| `scripts/storage-mounts.sh` | `apt-get install sshfs` → OS branch (layer or skip); `/etc/fuse.conf` handling | M |
| `scripts/ensure-swap.sh` | Skip on FCOS (or emit zram-generator config); called from `deploy.sh:65` | S |
| `compose.yaml` | Add `:Z`/`:z` to bind mounts (or per-service `security_opt: [label=disable]`) | M |
| `scripts/certbot-issue.sh` | `:Z`/label on the `podman run` certbot fallback (`:44`) | S |
| `scripts/lib-env.sh`, `provision-site.sh`, `new-site.sh`, `gen-test-certs.sh` | Remove `python3` dependency (use `sed`/`awk`) **or** route via `pod-run` | M |
| `install/setup.sh` | Fresh-host FCOS path (no apt); bootstrap expectations; `SETUP_ALLOW_UNSUPPORTED` guard | M |
| `bootstrap.sh` | Support `--user core` + key-only (no password step) | M |
| `tools/Containerfile` + `bin/pod-run` | **New.** Tools image + ephemeral runner | M |
| `quadlet/*.container` | **New.** Generated/curated Quadlet units (FCOS boot-start) | L |
| `README.md`, `PODMAN_PLAN.md` | Document the FCOS path + prerequisites | S |

**Unchanged:** all application containers/Containerfiles, compose *service*
definitions (modulo labels), certbot (container fallback), snapshot/DB
provisioning (`lib-storage`, `lib-db`), storage-box key auth, systemd timers,
Starship/`/etc/skel`, `/etc/systemd/system`, `/opt`, `/home` persistence.

* * *

## 7. Phased implementation

- **Phase 0 — OS abstraction.** Add `lib-os.sh`; make `deploy.sh`/`setup.sh`
  guards recognise FCOS. No behaviour change on Ubuntu.
- **Phase 1 — Tools container.** Add `tools/Containerfile` + `bin/pod-run`;
  convert `rsync`/`python3`/`openssl` call sites to the indirection. Validate on
  Ubuntu (using native tools) and FCOS (using the container).
- **Phase 2 — Host services.** Firewalld, swap-skip/zram, SELinux labels on all
  bind mounts and ad-hoc `podman run`.
- **Phase 3 — Boot-start.** Quadlet units on FCOS; keep generated units on Ubuntu.
- **Phase 4 — Provisioning path.** `bootstrap.sh` `core`/key-only; fresh-host
  `setup.sh` on FCOS; storage mounts decision (§5.5).
- **Phase 5 — Docs + end-to-end test** on a throwaway FCOS VM.

* * *

## 8. Testing

- Provision a disposable FCOS VM (QEMU + `coreos-installer` or the FCOS
  `qemu`/`libvirt` image) with a Butane config that adds the SSH key + `ryan`.
- Run `bootstrap.sh --host <vm>` (or the fresh-host one-liner) and assert:
  stack up, `21/21` provisioned, per-DB users created, Open WebUI healthy, and
  `curl -sk -H 'Host: <domain>' https://127.0.0.1/` returns 200 for the smoke set
  (same checks used on the current server).
- Verify reboot: Quadlet units bring the stack back automatically.

* * *

## 9. Risks

| Risk | Mitigation |
|---|---|
| SELinux blocks bind mounts | `:Z` labels + `semanage fcontext` for host dirs; test early |
| Tools container UID mismatch (rootful root == host root) | run as `--user` matching `ryan`, or keep root + `fix-perms.sh` |
| Quadlet/Compose drift (two orchestration models) | generate Quadlet from a single source (`lib-containers.sh`) |
| sshfs awkward in a container | prefer on-demand rsync (§5.5b) |
| One-shot bootstrap breaks (FCOS key-only, no password) | Phase 4 rework; Butane fallback |
| `command_not_found_handle` masking script failures | automation uses explicit `pod-run` only |

* * *

## 10. Non-goals

- Supporting other immutable distros (Silverblue, openSUSE MicroOS) now.
- Rewriting the app containers or provisioning logic.
- Dropping Ubuntu.

* * *

## 11. Open questions

1. **Tool host:** dedicated small `tools` image, or reuse the existing PHP image?
2. **sshfs:** keep persistent `~/gmail`/`~/databases` mounts (layer `fuse-sshfs`,
   one reboot) or switch to on-demand `rsync` (no host package, no reboot)?
3. **Orchestration on FCOS:** Quadlet (drop Compose there) or keep Compose by
   layering `podman-compose`?
4. **`python3`:** replace with `sed`/`awk` (portable) or run it in the tools
   container?
5. **Provisioning:** keep the `curl | bash` `setup.sh` flow, or adopt
   Ignition/Butane for user + key + services?
6. **SELinux:** full `:Z` labelling (recommended) or `label=disable` (faster)?
