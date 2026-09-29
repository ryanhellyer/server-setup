#!/usr/bin/env bash
# =============================================================================
# create-admin-user.sh — idempotently create the admin user, install a public
# key for it, and grant passwordless sudo.
#
#   sudo bash scripts/create-admin-user.sh
#
# Used by BOTH:
#   - bootstrap.sh  (piped over SSH onto a bare box, before the repo exists)
#   - install/setup.sh  (fresh-host path, after the repo is downloaded)
#
# Design: the box is intended to become key-only (see harden-sshd.sh), so the
# account gets NO password and sudo via a NOPASSWD sudoers drop-in. Safe to
# re-run.
#
# Config (env, all optional):
#   ADMIN_USER      default: ryan
#   ADMIN_SHELL     default: /bin/bash
#   ADMIN_KEY       inline public key, e.g. "ssh-ed25519 AAAA... me@host"
#   ADMIN_KEY_FILE  file containing the public key (used when ADMIN_KEY unset)
#   ADMIN_NOPASSWD  default: 1  (0 = remove the NOPASSWD drop-in)
#   ADMIN_GROUPS    extra groups to add (space separated; groups must exist)
#   ADMIN_SUDOERS_DIR  sudoers drop-in directory (default /etc/sudoers.d)
# =============================================================================
set -euo pipefail

SELF="$(readlink -f "$0")"
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$SELF" "$@"
fi

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }

ADMIN_USER="${ADMIN_USER:-ryan}"
ADMIN_SHELL="${ADMIN_SHELL:-/bin/bash}"
ADMIN_NOPASSWD="${ADMIN_NOPASSWD:-1}"
ADMIN_KEY="${ADMIN_KEY:-}"
ADMIN_KEY_FILE="${ADMIN_KEY_FILE:-}"
ADMIN_GROUPS="${ADMIN_GROUPS:-}"
SUDOERS_DIR="${ADMIN_SUDOERS_DIR:-/etc/sudoers.d}"

# ---- resolve the public key ----
if [ -z "$ADMIN_KEY" ] && [ -n "$ADMIN_KEY_FILE" ] && [ -f "$ADMIN_KEY_FILE" ]; then
  ADMIN_KEY="$(cat "$ADMIN_KEY_FILE")"
fi
ADMIN_KEY="${ADMIN_KEY%$'\n'}"

if [ -n "$ADMIN_KEY" ] && ! printf '%s' "$ADMIN_KEY" | grep -qE '^(ssh-|ecdsa-|sk-)'; then
  warn "ADMIN_KEY does not look like an OpenSSH public key — ignoring it."
  ADMIN_KEY=""
fi

# ---- create the user (idempotent) ----
if id "$ADMIN_USER" >/dev/null 2>&1; then
  ok "User '$ADMIN_USER' already exists."
else
  say "Creating user '$ADMIN_USER' (shell $ADMIN_SHELL, no password)."
  useradd -m -s "$ADMIN_SHELL" "$ADMIN_USER"
fi

ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
[ -n "$ADMIN_HOME" ] || { warn "Could not resolve a home directory for '$ADMIN_USER'."; exit 1; }

# ---- sudo ----
if getent group sudo >/dev/null 2>&1; then
  usermod -aG sudo "$ADMIN_USER"
elif getent group wheel >/dev/null 2>&1; then
  usermod -aG wheel "$ADMIN_USER"
else
  warn "No 'sudo' or 'wheel' group found — '$ADMIN_USER' will not have sudo."
fi
ok "User '$ADMIN_USER' is in the sudo group."

# ---- extra groups (only if they exist) ----
for grp in $ADMIN_GROUPS; do
  if getent group "$grp" >/dev/null 2>&1; then
    usermod -aG "$grp" "$ADMIN_USER"
  else
    warn "Group '$grp' does not exist — skipped."
  fi
done

# ---- authorized_keys (append-only, never overwrites other keys) ----
SSH_DIR="$ADMIN_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
install -d -m 700 -o "$ADMIN_USER" -g "$(id -gn "$ADMIN_USER")" "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "$ADMIN_USER":"$(id -gn "$ADMIN_USER")" "$AUTH_KEYS"

if [ -n "$ADMIN_KEY" ]; then
  if grep -qF "$ADMIN_KEY" "$AUTH_KEYS"; then
    ok "Public key already authorized for '$ADMIN_USER'."
  else
    printf '%s\n' "$ADMIN_KEY" >> "$AUTH_KEYS"
    ok "Public key authorized for '$ADMIN_USER'."
  fi
elif [ -s "$AUTH_KEYS" ]; then
  ok "'$ADMIN_USER' already has authorized_keys — leaving them as-is."
else
  warn "No ADMIN_KEY given and '$ADMIN_USER' has no keys — only password auth."
  warn "Install a key before disabling password authentication (harden-sshd.sh)."
fi

# ---- passwordless sudo (sudoers drop-in) ----
SUDOERS="$SUDOERS_DIR/90-server-setup-$ADMIN_USER"
if [ "$ADMIN_NOPASSWD" = "1" ]; then
  rm -f "$SUDOERS"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" > "$SUDOERS"
  chmod 0440 "$SUDOERS"
  if command -v visudo >/dev/null 2>&1; then
    visudo -cf "$SUDOERS" >/dev/null || { warn "Invalid sudoers entry — removing it."; rm -f "$SUDOERS"; exit 1; }
  fi
  ok "Passwordless sudo enabled for '$ADMIN_USER' ($SUDOERS)."
else
  rm -f "$SUDOERS"
  ok "Passwordless sudo NOT enabled for '$ADMIN_USER'."
fi

echo
echo "Admin user '$ADMIN_USER' ready (home $ADMIN_HOME, key-based, sudo)."
