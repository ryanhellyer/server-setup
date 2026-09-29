#!/usr/bin/env bash
# =============================================================================
# setup.sh — the ONE entry point for this repo. Everything admin runs from here.
#
# Single-line usage on a bare Ubuntu host (no docs, no keys, no git):
#
#   curl -fsSL https://raw.githubusercontent.com/ryanhellyer/server-setup/master/install/setup.sh \
#     -o /tmp/setup.sh && sudo bash /tmp/setup.sh
#
# Two modes, auto-detected:
#
#   * FRESH HOST (no repo installed — the curl|bash one-liner above):
#       1. Installs the host packages (podman, podman-compose, curl, openssl, nano...).
#       2. Downloads this whole repo as a tarball from GitHub (public repo — no
#          SSH keys needed) into the admin user's home (~/server-setup, e.g.
#          /home/ryan/server-setup) and writes a .tarball marker so deploy.sh can
#          refresh the files the same way later.
#       3. Creates an admin user 'ryan' — key-based, with passwordless
#          sudo (scripts/create-admin-user.sh). SERVER_SETUP_ADMIN_KEY supplies
#          the caller's key when run via bootstrap.sh.
#       4. Re-execs the installed copy, which presents the menu.
#
#   * INSTALLED SERVER (repo found in the parent of this script's dir, or in
#     ~/server-setup): Reinstalls — refreshes the repo files in place from
#     GitHub (tarball re-download, or git pull for git installs) — then
#     presents an interactive menu. The refresh is files-only and never
#     re-provisions sites/DBs (that's menu option 1). SETUP_NO_REFRESH=1 skips
#     it. Each menu option delegates to a script in scripts/ (sudo added only
#     where the target needs root).
#
# Menu options delegate to existing scripts, so the automation path is unchanged:
#   sudo bash scripts/deploy.sh        # full deploy (cron/automation friendly)
#   sudo bash scripts/new-site.sh ...  # add a site without the menu
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }

# Read from /dev/tty so prompts work even when piped in via curl | bash.
tty_read() { read -r "$1" < /dev/tty || true; }

# Admin user + install dir. The repo lives in the ADMIN USER'S HOME
# (~/server-setup, e.g. /home/ryan/server-setup) rather than /opt, so it sits on
# the persistent home partition (friendlier to atomic/immutable distros, where
# /opt is best left to the OS). Override with SERVER_SETUP_ADMIN_USER /
# SERVER_SETUP_DIR.
ADMIN_USER="${SERVER_SETUP_ADMIN_USER:-ryan}"
INSTALL_DIR="${SERVER_SETUP_DIR:-/home/$ADMIN_USER/server-setup}"

# ---- locate the repo: the parent of this script's dir, else the install dir ----
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
if [ ! -x "$REPO_DIR/scripts/deploy.sh" ] && [ -x "$INSTALL_DIR/scripts/deploy.sh" ]; then
  REPO_DIR="$INSTALL_DIR"
fi

# Download / refresh the repo files from GitHub (tarball — no git or keys
# needed). Used by the fresh install below AND when the installer is re-run on
# a server that already has the repo, so re-running it updates the scripts to
# the current master in place. Generated files and secrets (.env, rendered
# configs, certs) are gitignored, so an extract never touches them.
install_repo_files() { # "$1" = destination dir
  local dest="$1"
  local TARBALL_URL="${SERVER_SETUP_TARBALL:-https://github.com/ryanhellyer/server-setup/archive/refs/heads/master.tar.gz}"
  mkdir -p "$dest"
  # Resolve the live branch SHA first: SHA tarballs are immutable, so a
  # CDN-cached stale branch tarball is never used.
  local sha="" owner repo branch
  if [[ "$TARBALL_URL" =~ ^https://github.com/([^/]+)/([^/]+)/archive/refs/heads/([^/]+)\.tar\.gz$ ]]; then
    owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; branch="${BASH_REMATCH[3]}"
    sha="$(curl -fsSL "https://api.github.com/repos/$owner/$repo/commits/$branch" 2>/dev/null \
      | sed -n 's/.*"sha": "\([a-f0-9]\{40\}\)".*/\1/p' | head -1)"
    if [ -n "$sha" ]; then
      say "resolved $branch @ ${sha:0:7}"
      TARBALL_URL="https://github.com/$owner/$repo/archive/$sha.tar.gz"
    fi
  fi
  # Nothing to do if the files already match the live commit.
  if [ -n "$sha" ] && [ -f "$dest/.last-sha" ] && [ "$sha" = "$(cat "$dest/.last-sha")" ]; then
    say "already at ${sha:0:7} — no update needed"
    return 0
  fi
  # Fail explicitly (the caller may run this with errexit suppressed) so a bad
  # download never looks like a successful refresh.
  curl -fsSL "$TARBALL_URL" -o /tmp/server-setup.tar.gz || return 1
  tar -xzf /tmp/server-setup.tar.gz --strip-components=1 -C "$dest" || { rm -f /tmp/server-setup.tar.gz; return 1; }
  rm -f /tmp/server-setup.tar.gz
  # Remember how we were installed so deploy.sh can refresh the same way.
  # Store the refs/heads BRANCH URL (not the SHA-pinned URL we downloaded):
  # deploy.sh parses it to re-resolve the live SHA on every deploy. .last-sha
  # records what's actually applied so it can skip when nothing changed.
  printf '%s\n' "https://github.com/ryanhellyer/server-setup/archive/refs/heads/master.tar.gz" > "$dest/.tarball"
  chmod 600 "$dest/.tarball"
  [ -n "$sha" ] && printf '%s\n' "$sha" > "$dest/.last-sha"
  return 0
}

# =============================================================================
# FRESH HOST bootstrap
# =============================================================================
if [ ! -x "$REPO_DIR/scripts/deploy.sh" ]; then
  # ---- root ----
  if [ "$(id -u)" -ne 0 ]; then
    say "Not running as root — re-running with sudo."
    exec sudo bash "$0"
  fi

  echo
  echo "hellyer.kiwi server installer"
  echo "============================="
  echo

  # ---- host packages ----
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "This installer needs an Ubuntu/Debian host (apt-get). Aborting."
    echo "To install a REMOTE server from your laptop, run: ./bootstrap.sh --host <ip>"
    exit 1
  fi

  say "Installing fetch tools (curl, tar, ca-certificates ...)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y curl tar ca-certificates
  ok "Fetch tools installed."

  # ---- download the files (no git, no keys) ----
  REPO_DIR="$INSTALL_DIR"
  say "Downloading the server-setup files from GitHub"
  install_repo_files "$REPO_DIR"
  [ -f "$REPO_DIR/install/setup.sh" ] || { echo "Download failed — no install/setup.sh found in the tarball."; exit 1; }
  ok "Files installed at $REPO_DIR"

  # Transition guard: this is a tarball install — drop any stale .git left by an
  # earlier git-clone install so deploy.sh stays in tarball refresh mode.
  if [ -d "$REPO_DIR/.git" ]; then
    say "Removing stale .git from an earlier git-clone install (tarball mode now)."
    rm -rf "$REPO_DIR/.git"
  fi

  # ---- admin user (shared with bootstrap.sh) ----
  # SERVER_SETUP_ADMIN_KEY lets a remote caller (bootstrap.sh) supply the
  # caller's own key. Fallback: the maintainer's key, so a bare `curl | bash`
  # install still ends up with passwordless SSH. No password is set on the
  # account — access is key-only, with passwordless sudo. Always done (no
  # prompt): a fresh host must have the admin user + key.
  DEFAULT_ADMIN_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEheqtRv6dkhK3KNjuCwxfKDgvZAEzNcnBt7fL/XQWGX ryanhellyer@gmail.com'
  ADMIN_USER="$ADMIN_USER" \
    ADMIN_KEY="${SERVER_SETUP_ADMIN_KEY:-$DEFAULT_ADMIN_KEY}" \
    bash "$REPO_DIR/scripts/create-admin-user.sh"
  ok "Admin user '$ADMIN_USER' ready (key-based, passwordless sudo)."

  # The tarball was extracted as root BEFORE the admin user existed, and
  # `useradd -m` does not chown a home directory that already exists (it only
  # warns) — so make sure the admin user owns their home and the install dir.
  ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  ADMIN_GROUP="$(id -gn "$ADMIN_USER")"
  if [ -n "$ADMIN_HOME" ]; then
    if [ "$(dirname "$REPO_DIR")" = "$ADMIN_HOME" ]; then
      chown "$ADMIN_USER:$ADMIN_GROUP" "$ADMIN_HOME"
    fi
    chown -R "$ADMIN_USER:$ADMIN_GROUP" "$REPO_DIR"
  fi

  # ---- full host setup: packages + bind-mount dirs + swap ----
  # (delegates to host-setup.sh so the package list lives in ONE place; also
  # runs apt-get upgrade and creates a swapfile on small boxes.)
  say "Running scripts/host-setup.sh (host packages, dirs, swap)"
  bash "$REPO_DIR/scripts/host-setup.sh"
  ok "Host packages installed."

  # ---- remote storage access + mounts (asks for each box password once) ----
  # Always set up: authorises this server's key on both boxes and mounts the
  # primary box's gmail + databases shares under the admin user's home.
  bash "$REPO_DIR/scripts/storage-mounts.sh" \
    || say "Storage mounts not configured — re-run scripts/storage-mounts.sh later."

  # ---- first deploy (brings the stack up + imports every site/DB/Open WebUI) ----
  # Fully automatic: deploy.sh generates .env, starts the containers, and
  # provision-all.sh imports everything fresh from the newest snapshot.
  say "Running the first deploy (this may take a while)"
  bash "$REPO_DIR/scripts/deploy.sh" \
    || say "Deploy had failures — re-run it from the menu (option 1)."

  say "Re-running the installed copy to present the menu."
  cd "$REPO_DIR"
  exec bash "$REPO_DIR/install/setup.sh"
fi

# =============================================================================
# INSTALLED SERVER — interactive menu
# =============================================================================
cd "$REPO_DIR"

# ---- safety: setup.sh acts on the machine it RUNS on, never remotely ----
# The stack targets Ubuntu + systemd. If either is missing you're almost
# certainly on the wrong machine (e.g. a laptop), where a stray menu choice
# could install/modify local services. Point people at bootstrap.sh instead.
if [ "${SETUP_ALLOW_UNSUPPORTED:-0}" != "1" ]; then
  if ! command -v apt-get >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo
    echo "!! This host does not look like the target Ubuntu server (needs apt-get + systemd)."
    echo "!! setup.sh installs on THIS machine. To install a REMOTE server, run this"
    echo "!! from your laptop instead:"
    echo
    echo "!!     ./bootstrap.sh --host <server-ip>"
    echo
    echo "!! (If you really mean to run here, prefix with SETUP_ALLOW_UNSUPPORTED=1.)"
    exit 1
  fi
fi

# The menu is interactive — without a usable terminal, tell the caller to use
# the automation path instead of looping on failed reads. (Testing the node with
# `[ -e /dev/tty ]` is not enough: the node exists even with no controlling tty.)
if ! { : < /dev/tty; } 2>/dev/null; then
  echo "No terminal available (piped/automation). Run the scripts directly:"
  echo "  sudo bash scripts/deploy.sh"
  echo "  sudo bash scripts/new-site.sh <domain> <type>"
  echo "  sudo bash scripts/backup.sh   |   sudo bash scripts/restore.sh"
  echo "Other host tasks (TLS, systemd units, CLI tools, status, logs, storage"
  echo "mounts, SSH hardening): see the SSH login banner or README.md."
  exit 1
fi

# ---- reinstall: re-running the installer on a server that already has the
# repo updates the files in place (tarball re-download, or git pull for git
# installs). Files ONLY — it never re-provisions sites/DBs (that's menu option
# 1, which re-imports from the storage snapshots). Generated files and secrets
# (.env, rendered configs, certs) are gitignored, so they're untouched. Set
# SETUP_NO_REFRESH=1 to skip. The running copy keeps executing the old inode
# after an extract/pull, so the menu this run may predate the new files; that's
# cosmetic (each menu choice launches a fresh process that reads the new code).
if [ "${SETUP_NO_REFRESH:-0}" != "1" ]; then
  if git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
     && [ -n "$(git -C "$REPO_DIR" remote 2>/dev/null)" ]; then
    say "Existing install — updating files (git pull)"
    git -C "$REPO_DIR" pull --ff-only \
      || say "!! git pull failed (local edits?) — using the files already here"
  else
    say "Existing install — updating files from GitHub"
    install_repo_files "$REPO_DIR" \
      || say "!! file refresh failed — using the files already here"
  fi
  # A sudo/root refresh leaves root-owned files; keep them owned by the admin
  # user when the repo lives directly under their home.
  ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  if [ -n "$ADMIN_HOME" ] && [ "$(dirname "$REPO_DIR")" = "$ADMIN_HOME" ]; then
    chown -R "$ADMIN_USER:$(id -gn "$ADMIN_USER")" "$REPO_DIR" 2>/dev/null || true
  fi
fi

show_menu() {
  echo
  echo "server-setup — what would you like to do?"
  echo "------------------------------------------"
  echo " 1) Full install / deploy / update the stack"
  echo " 2) Add a new site"
  echo " 3) Back up"
  echo " 4) Restore from backup"
  echo " 0) Quit"
  echo
  echo "Other tasks now run as scripts — see the SSH login banner or README"
  echo "for the exact commands (TLS, systemd units, CLI tools, status, logs,"
  echo "storage mounts, SSH hardening)."
  echo
}

# Sub-menu: add a new site (prompt domain + type, then delegate).
add_site() {
  local domain type target
  echo
  echo "Site types: laravel | wordpress | static | static-spa | redirect | node"
  printf 'Domain: '; tty_read domain
  [ -n "$domain" ] || { echo "Domain required."; return 1; }
  printf 'Type:   '; tty_read type
  case "$type" in
    laravel|wordpress|static|static-spa|redirect|node) ;;
    *) echo "Unknown type: $type"; return 1 ;;
  esac
  if [ "$type" = "redirect" ]; then
    printf 'Target (e.g. https://example.com$request_uri): '; tty_read target
    [ -n "$target" ] || { echo "Target required for redirect."; return 1; }
    sudo bash scripts/new-site.sh "$domain" "$type" "$target"
  else
    sudo bash scripts/new-site.sh "$domain" "$type"
  fi
}

while true; do
  show_menu
  printf 'Choose: '
  tty_read choice
  # A failing delegated script (e.g. an aborted restore) must return to the
  # menu, not kill setup.sh — so drop errexit for the dispatch only.
  set +e
  case "$choice" in
    1) sudo bash scripts/deploy.sh ;;
    2) add_site ;;
    3) sudo bash scripts/backup.sh ;;
    4) sudo bash scripts/restore.sh ;;
    0|q|quit) echo "Bye."; exit 0 ;;
    *) echo "Invalid choice." ;;
  esac
  set -e
done