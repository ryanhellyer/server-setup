#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — provision and manage a remote Ubuntu server over SSH.
#
# Run this from your laptop (not on the server). It:
#   1. Connects once with the server password (the way Hetzner ships a box).
#   2. Installs your SSH public key for the login user (root by default).
#   3. Creates the admin user (default 'ryan') with your key + passwordless sudo.
#   4. Hardens sshd — disables password auth (root left reachable by key only).
#   5. Runs the CURRENT installer from GitHub: bootstraps a new box, or — if
#      the repo is already in the admin user's home (~/server-setup) — refreshes
#      the files in place and opens the on-server menu for full remote control.
#      So a plain run is also the "update an installed server" command.
#
#   ./bootstrap.sh --host 203.0.113.10
#   ./bootstrap.sh --host box.example.com --user root --admin-user ryan
#   ./bootstrap.sh --host box.example.com --no-harden   # skip sshd hardening
#
# The password is entered by ssh itself, once, and is never stored.
#
# Options:
#   --host HOST        server to connect to (prompted if omitted)
#   --port PORT        SSH port (default 22)
#   --user USER        login user for provisioning (default root)
#   --admin-user NAME  admin user to create (default ryan)
#   --identity FILE    private key to use (defaults to agent, then ~/.ssh/id_*)
#   --install          accepted for compatibility (install-or-update is now
#                      always what runs; the installer detects which is needed)
#   --no-harden        do not disable SSH password authentication
#   -h, --help         show this help
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

HOST=""
PORT="22"
TARGET_USER="root"
ADMIN_USER="ryan"
IDENTITY=""
DO_HARDEN=1
SETUP_URL="https://raw.githubusercontent.com/ryanhellyer/server-setup2/master/install/setup.sh"
# INSTALL_DIR is resolved after option parsing (it depends on --admin-user).
INSTALL_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --host)       HOST="${2:?--host needs a value}"; shift 2 ;;
    --port)       PORT="${2:?--port needs a value}"; shift 2 ;;
    --user)       TARGET_USER="${2:?--user needs a value}"; shift 2 ;;
    --admin-user) ADMIN_USER="${2:?--admin-user needs a value}"; shift 2 ;;
    --identity)   IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
    --install)    shift ;;  # compatibility no-op: install-or-update is always run
    --no-harden)  DO_HARDEN=0; shift ;;
    -h|--help)    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

# The repo installs into the admin user's home (~/server-setup), not /opt.
INSTALL_DIR="${SERVER_SETUP_DIR:-/home/$ADMIN_USER/server-setup}"

[ -f "$REPO_DIR/scripts/create-admin-user.sh" ] || die "Run this from the repo root."
[ -f "$REPO_DIR/scripts/harden-sshd.sh" ] || die "Run this from the repo root."
case "$PORT" in ''|*[!0-9]*) die "--port must be a number." ;; esac

if [ -z "$HOST" ]; then
  printf 'Server host/IP: '
  read -r HOST
fi
[ -n "$HOST" ] || die "No host given."
TARGET="$TARGET_USER@$HOST"

# ---- choose an SSH key: --identity, else agent, else ~/.ssh/id_*, else generate ----
TMP_PUB=""
PUBKEY=""
PUBFILE=""
cleanup() { [ -n "$TMP_PUB" ] && rm -f "$TMP_PUB" 2>/dev/null || true; }
trap cleanup EXIT

if [ -n "$IDENTITY" ]; then
  [ -f "$IDENTITY" ] || die "Identity file not found: $IDENTITY"
  if [ -f "$IDENTITY.pub" ]; then
    PUBFILE="$IDENTITY.pub"
  else
    TMP_PUB="$(mktemp /tmp/ss-boot-pub.XXXXXX.pub)"; ssh-keygen -y -f "$IDENTITY" > "$TMP_PUB"; PUBFILE="$TMP_PUB"
  fi
  PUBKEY="$(cat "$PUBFILE")"
elif [ -n "${SSH_AUTH_SOCK:-}" ] && ssh-add -l >/dev/null 2>&1; then
  PUBKEY="$(ssh-add -L 2>/dev/null | head -1)"
  TMP_PUB="$(mktemp /tmp/ss-boot-pub.XXXXXX.pub)"; printf '%s\n' "$PUBKEY" > "$TMP_PUB"; PUBFILE="$TMP_PUB"
  ok "Using the SSH key already in your agent."
else
  for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
    if [ -f "$k" ]; then
      IDENTITY="$k"
      if [ -f "$k.pub" ]; then PUBFILE="$k.pub"; else TMP_PUB="$(mktemp /tmp/ss-boot-pub.XXXXXX.pub)"; ssh-keygen -y -f "$k" > "$TMP_PUB"; PUBFILE="$TMP_PUB"; fi
      PUBKEY="$(cat "$PUBFILE")"
      break
    fi
  done
fi

if [ -z "$PUBKEY" ]; then
  say "No SSH key found — generating ~/.ssh/server_setup_ed25519"
  IDENTITY="$HOME/.ssh/server_setup_ed25519"
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  ssh-keygen -t ed25519 -N '' -C "server-setup bootstrap" -f "$IDENTITY" >/dev/null
  PUBFILE="$IDENTITY.pub"
  PUBKEY="$(cat "$PUBFILE")"
fi
ok "Using public key: $(printf '%s' "$PUBKEY" | awk '{print $1, substr($2,1,12)"…", $3}')"

# ---- ssh/scp option arrays ----
# Pin to the one key we intend to use. A .pub path is fine for an agent-backed
# key (ssh finds the private half in the agent). IdentitiesOnly matters: without
# it ssh offers EVERY agent key, and a server with a low MaxAuthTries or
# fail2ban drops the connection before the password prompt — the "Connection
# closed by <host> port 22" failure.
if [ -n "$IDENTITY" ]; then SSH_ID_FILE="$IDENTITY"; else SSH_ID_FILE="$PUBFILE"; fi
SSH_OPTS=(-p "$PORT" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30
          -i "$SSH_ID_FILE" -o IdentitiesOnly=yes)
SCP_OPTS=(-P "$PORT" -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30
          -i "$SSH_ID_FILE")

run_ssh()   { ssh "${SSH_OPTS[@]}" "$@"; }
run_ssh_t() { ssh -t "${SSH_OPTS[@]}" "$@"; }

key_login_works() { # "$1" = user
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o PreferredAuthentications=publickey \
    "$1@$HOST" true >/dev/null 2>&1
}

# Append our public key over SSH using the PASSWORD, in a single attempt.
# Publickey auth is disabled for this one call so no (failing) key is offered
# and there is nothing to trip MaxAuthTries/fail2ban before the password prompt.
install_key_password() {
  cat "$PUBFILE" | ssh -p "$PORT" \
    -o StrictHostKeyChecking=accept-new \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o NumberOfPasswordPrompts=1 \
    "$TARGET" \
    'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'
}

# =============================================================================
# 1. Install the login user's key (single password prompt on first contact)
# =============================================================================
if key_login_works "$TARGET_USER"; then
  ok "Key-based login to $TARGET already works."
else
  say "First contact with $TARGET — you'll be asked for the password ONCE."
  if install_key_password && key_login_works "$TARGET_USER"; then
    ok "Key installed for $TARGET_USER."
  else
    warn "Could not install the key with the password."
    warn "Likely causes: wrong password; password auth disabled for '$TARGET_USER'; or the"
    warn "source IP is temporarily blocked (fail2ban) after earlier failed attempts."
    warn "Install the key manually (this prompts for the password):"
    printf '\n    cat %s | ssh -p %s -o PubkeyAuthentication=no -o PreferredAuthentications=password %s \\\n' \
      "$PUBFILE" "$PORT" "$TARGET"
    printf "      'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys'\n\n"
    die "Aborting; nothing was changed."
  fi
fi

# Cache sudo credentials for a non-root login user (piped steps can't prompt).
if [ "$TARGET_USER" != "root" ]; then
  say "Caching sudo credentials for $TARGET_USER"
  run_ssh_t "$TARGET" 'sudo -v'
fi
SUDO=""; [ "$TARGET_USER" = "root" ] || SUDO="sudo "

# =============================================================================
# 2. Create/refresh the admin user with the key + passwordless sudo
# =============================================================================
esc_key="${PUBKEY//\'/\'\\\'\'}"
say "Ensuring admin user '$ADMIN_USER' (key + NOPASSWD sudo)"
run_ssh "$TARGET" "${SUDO}env ADMIN_USER='${ADMIN_USER}' ADMIN_KEY='${esc_key}' ADMIN_NOPASSWD=1 bash -s" \
  < "$REPO_DIR/scripts/create-admin-user.sh"

if key_login_works "$ADMIN_USER"; then
  ok "Key-based login to $ADMIN_USER@$HOST works."
else
  warn "Could not confirm key login for '$ADMIN_USER' yet — check authorized_keys."
fi

# =============================================================================
# 3. Harden sshd (disable password auth)
# =============================================================================
if [ "$DO_HARDEN" -eq 1 ]; then
  say "Hardening sshd (keys only; root login by key)"
  run_ssh "$TARGET" "${SUDO}env ADMIN_USER='${ADMIN_USER}' bash -s -- --yes" \
    < "$REPO_DIR/scripts/harden-sshd.sh"
else
  warn "Skipping sshd hardening (--no-harden)."
fi

# =============================================================================
# 4. Run the installer (fresh bootstrap, or update + menu on an existing box)
# =============================================================================
# Always run the CURRENT install/setup.sh from GitHub. On a fresh box it
# bootstraps; on an existing install setup.sh refreshes the repo files in place
# and opens the menu. So a plain `bootstrap.sh` updates an already-installed
# server — it does not run the server's stale local copy. (--install is kept for
# compatibility; it is now the default.)
say "Running the server-setup installer on $HOST (install or update)"
if run_ssh "$TARGET" 'command -v curl >/dev/null 2>&1'; then
  run_ssh_t "$TARGET" "curl -fsSL '$SETUP_URL' -o /tmp/setup.sh && ${SUDO}env SERVER_SETUP_ADMIN_USER='$ADMIN_USER' bash /tmp/setup.sh"
else
  warn "curl not found on the server — copying install/setup.sh over instead."
  scp "${SCP_OPTS[@]}" "$REPO_DIR/install/setup.sh" "$TARGET:/tmp/setup.sh"
  run_ssh_t "$TARGET" "${SUDO}env SERVER_SETUP_ADMIN_USER='$ADMIN_USER' bash /tmp/setup.sh"
fi
