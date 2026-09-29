#!/usr/bin/env bash
# =============================================================================
# harden-sshd.sh — disable password authentication once key access is working.
#
#   sudo bash scripts/harden-sshd.sh          # apply (asks before changing)
#   sudo bash scripts/harden-sshd.sh --yes    # apply without the prompt
#   sudo bash scripts/harden-sshd.sh --revert # undo
#
# What it does: writes /etc/ssh/sshd_config.d/99-server-setup.conf setting
#   PasswordAuthentication no
#   KbdInteractiveAuthentication no
#   PubkeyAuthentication yes
#   PermitRootLogin prohibit-password
# then validates and reloads sshd. If the main sshd_config does not include the
# sshd_config.d drop-in dir, it falls back to inserting a marked block at the
# top of /etc/ssh/sshd_config instead.
#
# Lockout safety: refuses unless root or ADMIN_USER already has an
# authorized_keys file, validates the config before reloading, and keeps a
# backup. Recovery if you do get locked out: use the Hetzner console/rescue
# and delete /etc/ssh/sshd_config.d/99-server-setup.conf (or run --revert).
#
# Config (env, optional):
#   ADMIN_USER  default: ryan  (used only for the safety check)
#   ROOT_LOGIN  default: prohibit-password
# =============================================================================
set -euo pipefail

SELF="$(readlink -f "$0")"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }

ADMIN_USER="${ADMIN_USER:-ryan}"
ROOT_LOGIN="${ROOT_LOGIN:-prohibit-password}"

DROPIN_DIR="${SSHD_CONFIG_D:-/etc/ssh/sshd_config.d}"
DROPIN="$DROPIN_DIR/99-server-setup.conf"
SSHD_CONFIG="${SSHD_CONFIG_FILE:-/etc/ssh/sshd_config}"
MARK_BEGIN='# BEGIN server-setup sshd hardening'
MARK_END='# END server-setup sshd hardening'

REVERT=0
YES=0
for arg in "$@"; do
  case "$arg" in
    --revert) REVERT=1 ;;
    --yes|-y) YES=1 ;;
    -h|--help)
      sed -n '2,26p' "$SELF" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) warn "Ignoring unknown argument: $arg" ;;
  esac
done

# Root is required from here on (checked after --help so it works unprivileged).
if [ "$(id -u)" -ne 0 ]; then
  exec sudo -E bash "$SELF" "$@"
fi

# Resolve the sshd binary (root's PATH may not include /usr/sbin).
if [ -n "${SSHD_BIN_OVERRIDE:-}" ]; then
  SSHD_BIN="$SSHD_BIN_OVERRIDE"
elif command -v sshd >/dev/null 2>&1; then
  SSHD_BIN="$(command -v sshd)"
elif [ -x /usr/sbin/sshd ]; then
  SSHD_BIN="/usr/sbin/sshd"
else
  SSHD_BIN=""
fi

reload_sshd() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
      || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  else
    service ssh reload 2>/dev/null || service sshd reload 2>/dev/null || true
  fi
}

# Print the effective value sshd would use for a directive.
effective() {
  [ -n "$SSHD_BIN" ] || return 1
  "$SSHD_BIN" -T 2>/dev/null | awk -v k="$(printf '%s' "$1" | tr 'A-Z' 'a-z')" \
    'tolower($1)==k {print $2; exit}'
}

have_key() {
  local home
  home="$(getent passwd "$1" 2>/dev/null | cut -d: -f6)" || return 1
  [ -n "$home" ] && [ -s "$home/.ssh/authorized_keys" ]
}

strip_block() { # "$1" file
  local tmp
  tmp="$(mktemp)"
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" \
    '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$1" > "$tmp"
  cat "$tmp" > "$1"
  rm -f "$tmp"
}

# =============================================================================
# Revert
# =============================================================================
if [ "$REVERT" -eq 1 ]; then
  say "Reverting sshd hardening"
  rm -f "$DROPIN"
  if [ -f "$SSHD_CONFIG" ] && grep -qsF "$MARK_BEGIN" "$SSHD_CONFIG"; then
    cp -a "$SSHD_CONFIG" "$SSHD_CONFIG.server-setup.bak"
    strip_block "$SSHD_CONFIG"
  fi
  reload_sshd
  ok "Reverted — password authentication is allowed again (per the base config)."
  exit 0
fi

# =============================================================================
# Safety: never disable password auth without a working key on at least one login
# =============================================================================
if have_key root; then
  ok "root has an authorized_keys file."
elif have_key "$ADMIN_USER"; then
  ok "'$ADMIN_USER' has an authorized_keys file."
else
  warn "No authorized_keys found for root or '$ADMIN_USER'."
  warn "Refusing to disable password authentication — that would lock you out."
  warn "Install a key first (scripts/create-admin-user.sh), then re-run."
  exit 1
fi

if [ "$YES" -ne 1 ] && [ -e /dev/tty ]; then
  printf 'Disable SSH password authentication on this host? [y/N] '
  read -r ans < /dev/tty || ans=""
  case "${ans,,}" in
    y|yes) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# =============================================================================
# Apply
# =============================================================================
CONTENT="$(cat <<EOF
# Managed by server-setup (scripts/harden-sshd.sh). Revert with: sudo bash scripts/harden-sshd.sh --revert
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin $ROOT_LOGIN
EOF
)"

install -d -m 755 "$DROPIN_DIR"
printf '%s\n' "$CONTENT" > "$DROPIN"
chmod 644 "$DROPIN"
say "Wrote $DROPIN"

if [ -n "$SSHD_BIN" ] && ! "$SSHD_BIN" -t 2>/dev/null; then
  warn "sshd rejected the config (sshd -t) — removing the drop-in."
  rm -f "$DROPIN"
  exit 1
fi

# Confirm the drop-in is actually honoured. If not, fall back to editing the
# main config. OpenSSH uses the FIRST value for a keyword, so the block must go
# at the TOP (appending it after an existing `PasswordAuthentication yes` would
# have no effect).
if [ -n "$SSHD_BIN" ] && [ "$(effective PasswordAuthentication)" != "no" ]; then
  warn "The sshd_config.d drop-in is not being included — prepending to $SSHD_CONFIG."
  rm -f "$DROPIN"
  [ -f "$SSHD_CONFIG.server-setup.bak" ] || cp -a "$SSHD_CONFIG" "$SSHD_CONFIG.server-setup.bak"
  grep -qsF "$MARK_BEGIN" "$SSHD_CONFIG" && strip_block "$SSHD_CONFIG"
  TMP="$(mktemp)"
  {
    printf '%s\n' "$MARK_BEGIN"
    printf '%s\n' "$CONTENT"
    printf '%s\n' "$MARK_END"
    cat "$SSHD_CONFIG"
  } > "$TMP"
  cat "$TMP" > "$SSHD_CONFIG"
  rm -f "$TMP"
  if ! "$SSHD_BIN" -t 2>/dev/null; then
    warn "sshd rejected $SSHD_CONFIG — restoring the backup."
    cp -a "$SSHD_CONFIG.server-setup.bak" "$SSHD_CONFIG"
    exit 1
  fi
fi

reload_sshd

echo
if [ -n "$SSHD_BIN" ]; then
  "$SSHD_BIN" -T 2>/dev/null | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|permitrootlogin)' \
    | sed 's/^/  /' || true
fi
ok "SSH hardened: keys only, root login by key ($ROOT_LOGIN)."
echo "  Test a NEW connection before closing this one."
echo "  Revert with: sudo bash scripts/harden-sshd.sh --revert"
