#!/usr/bin/env bash
# =============================================================================
# provision-all.sh — always-fresh import of every site + database + Open WebUI.
#
#   sudo bash scripts/provision-all.sh [--dry-run] [--files-only|--db-only]
#
# Runs, in order:
#   migrate-sites.sh --all        (files + per-site DBs -> ~/www)
#   provision-extras.sh           (non-site files -> ~/tools)
#   provision-openwebui.sh        (chat.hellyer.kiwi data)
#   provision-authelia.sh         (forward-auth user database + container)
#
# Called automatically by deploy.sh on every deploy.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a

rc=0
bash "$PWD/scripts/migrate-sites.sh" --all "$@" || rc=1
bash "$PWD/scripts/provision-extras.sh" "$@" || rc=1
bash "$PWD/scripts/provision-openwebui.sh" "$@" || rc=1
# Authelia has no storage snapshot to restore — this just (re)writes the user
# database from .env and starts the container. Skip it when no admin is set,
# so existing installs without the AUTHELIA_* block keep deploying cleanly.
if [ -n "${AUTHELIA_ADMIN_PASSWORD:-}" ]; then
  bash "$PWD/scripts/provision-authelia.sh" "$@" || rc=1
fi
exit "$rc"
