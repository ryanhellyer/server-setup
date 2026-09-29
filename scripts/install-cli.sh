#!/usr/bin/env bash
# =============================================================================
# install-cli.sh — install host-side command wrappers that run inside the
# right container (via bin/pod-exec), plus `pod-login` for an interactive shell.
# Creates symlinks in the admin user's ~/.local/bin (or the directory given as
# the first argument). The command list comes from scripts/lib-containers.sh
# (single source of truth).
#
#   ./scripts/install-cli.sh                       # -> the admin user's ~/.local/bin
#   ./scripts/install-cli.sh /some/other/bin       # explicit destination
#
# Run as root (deploy.sh does): it resolves the admin user from $SUDO_USER
# (falling back to `ryan`) so the wrappers land in THEIR home, not /root.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ---- pick the destination + the user who should own it ----
if [ -n "${1:-}" ]; then
  DEST_DIR="$1"
  OWNER=""
else
  OWNER="${SUDO_USER:-}"
  if [ -z "$OWNER" ] || [ "$OWNER" = "root" ]; then
    if id ryan >/dev/null 2>&1; then OWNER="ryan"; else OWNER="$(id -un)"; fi
  fi
  OWNER_HOME="$(getent passwd "$OWNER" 2>/dev/null | cut -d: -f6)"
  [ -n "$OWNER_HOME" ] || OWNER_HOME="$HOME"
  DEST_DIR="$OWNER_HOME/.local/bin"
fi

source "$REPO_DIR/scripts/lib-containers.sh"

install -d "$DEST_DIR"

for cmd in "${!CLI_CONTAINER[@]}"; do
  ln -sf "$REPO_DIR/bin/pod-exec" "$DEST_DIR/$cmd"
done
# Interactive / status helpers (not part of the command->container map).
for helper in pod-login pod-logs pod-status pod-restart pod-exec sites cert-status; do
  ln -sf "$REPO_DIR/bin/$helper" "$DEST_DIR/$helper"
done

# ---- hand ownership back to the admin user when run as root ----
if [ -n "$OWNER" ] && id "$OWNER" >/dev/null 2>&1; then
  OWNER_GROUP="$(id -gn "$OWNER")"
  chown "$OWNER:$OWNER_GROUP" "$DEST_DIR" 2>/dev/null || true
  chown -h "$OWNER:$OWNER_GROUP" "$DEST_DIR"/* 2>/dev/null || true
fi

# ---- make sure ~/.local/bin is on the admin user's PATH ----
if [ -n "$OWNER" ] && [ -n "${OWNER_HOME:-}" ] && [ -f "$OWNER_HOME/.bashrc" ]; then
  grep -qs 'HOME/.local/bin' "$OWNER_HOME/.bashrc" \
    || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$OWNER_HOME/.bashrc"
fi

echo "Installed wrappers to: $DEST_DIR"
if [ -n "$OWNER" ]; then
  echo "Owner: $OWNER  (PATH updated in their ~/.bashrc; log out/in to pick it up)"
else
  echo "Add this to ~/.bashrc (before /usr/bin):"
  echo "  export PATH=\"$DEST_DIR:\$PATH\""
fi
