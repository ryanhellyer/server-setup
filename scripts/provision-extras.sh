#!/usr/bin/env bash
# =============================================================================
# provision-extras.sh — copy the NON-website files from the storage snapshot
# into the admin user's ~/tools.
#
#   sudo bash scripts/provision-extras.sh [--dry-run] [--force]
#
# migrate-sites.sh puts the sites into ~/www. This script copies EVERYTHING
# ELSE from the newest snapshot — backup scripts, configs, cron, old site
# copies and misc data — into ~/tools, so the backup tooling travels with the
# server instead of being silently dropped.
#
# "Everything else" is the exact complement of the site list; both scripts get
# that list from lib-storage.sh:snapshot_site_dirs(), so they can't drift.
#
# The copy runs once per snapshot: a hidden $TOOLS_ROOT/.snapshot marker records
# which snapshot was copied, so trimming ~/tools by hand survives later deploys.
# Use --force to re-copy anyway.
#
# Config (see lib-storage.sh / lib-paths.sh):
#   TOOLS_ROOT        host dir to copy into (default ~/tools)
#   EXTRAS_EXCLUDE    space-separated top-level snapshot names to skip
#   PROVISION_EXTRAS  set to 0 in .env to disable this step entirely
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-paths.sh
source scripts/lib-storage.sh

TOOLS_ROOT="$(resolve_tools_root)"
ADMIN_USER="$(resolve_admin_user)"
WWW_ROOT="$(resolve_www_root)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }

DRY=0; FORCE=0; DO=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --force)   FORCE=1 ;;
    --files-only) : ;;                 # extras are files anyway
    --db-only) DO=0 ;;                 # nothing file-shaped to do
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

[ "$DO" = 1 ] || exit 0

# Safety: never rsync the snapshot over the web root (or vice-versa).
if [ "$TOOLS_ROOT" = "$WWW_ROOT" ]; then
  warn "TOOLS_ROOT equals WWW_ROOT ($TOOLS_ROOT) — refusing to run."
  exit 1
fi

if [ "${PROVISION_EXTRAS:-1}" = "0" ]; then
  say "PROVISION_EXTRAS=0 — skipping extras copy."
  exit 0
fi

SNAP="$(newest_snapshot)"
[ -n "$SNAP" ] || { warn "No snapshot found under $SNAPSHOT_ROOT — nothing to copy."; exit 0; }

SENTINEL="$TOOLS_ROOT/.snapshot"
if [ "$DRY" != 1 ] && [ "$FORCE" != 1 ] && [ -f "$SENTINEL" ] \
   && [ "$(cat "$SENTINEL" 2>/dev/null)" = "$SNAP" ]; then
  ok "Extras already copied from $SNAP (marker $SENTINEL). Use --force to re-copy."
  exit 0
fi

say "Extras: $STORAGE_USER@$STORAGE_HOST:$SNAP  ->  $TOOLS_ROOT"
[ "$DRY" = 1 ] && warn "dry-run: no changes will be made"

# ---- work out the site dirs (these go to ~/www, NOT ~/tools) ----------------
box_ssh "ls '$SNAP/'" >/dev/null 2>&1 || { warn "Could not list $SNAP on the box — aborting."; exit 1; }
declare -A IS_SITE=()
while IFS= read -r name; do
  [ -n "$name" ] && IS_SITE["$name"]=1
done <<< "$(snapshot_site_dirs "$SNAP")"
# Safety: if detection found nothing, refuse — otherwise every site would be
# copied into ~/tools as well as ~/www.
if [ "${#IS_SITE[@]}" -eq 0 ]; then
  warn "No site dirs detected in $SNAP — refusing to copy everything into $TOOLS_ROOT."
  warn "Check the box is reachable; or set PROVISION_EXTRAS=0 / EXTRAS_EXCLUDE as needed."
  exit 1
fi

# ---- rsync excludes: every site, plus any user EXTRAS_EXCLUDE ---------------
EXCLUDES=()
for name in "${!IS_SITE[@]}"; do
  EXCLUDES+=(--exclude="/$name")
done
for name in ${EXTRAS_EXCLUDE:-}; do
  [ -n "$name" ] || continue
  EXCLUDES+=(--exclude="/$name")
done

# ---- copy everything else ---------------------------------------------------
if [ "$DRY" != 1 ]; then
  mkdir -p "$TOOLS_ROOT"
  chown "$ADMIN_USER:$ADMIN_USER" "$TOOLS_ROOT" 2>/dev/null || true
fi

# -rlptD keeps permissions (so the backup scripts stay executable) but not the
# remote owner/group (uid 513410); no --delete — this is an archive, not a
# mirror, so it never removes local files.
RSYNC=(rsync -rlptD --no-owner --no-group --info=stats2
       -e "ssh -i $STORAGE_KEY -p $STORAGE_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
       "${EXCLUDES[@]}")
[ "$DRY" = 1 ] && RSYNC+=(--dry-run)
RSYNC+=("$STORAGE_USER@$STORAGE_HOST:$SNAP/" "$TOOLS_ROOT/")

"${RSYNC[@]}"

if [ "$DRY" != 1 ]; then
  chown -R "$ADMIN_USER:$ADMIN_USER" "$TOOLS_ROOT" 2>/dev/null || true
  printf '%s\n' "$SNAP" > "$SENTINEL"
  chown "$ADMIN_USER:$ADMIN_USER" "$SENTINEL" 2>/dev/null || true
fi
ok "Extras copied to $TOOLS_ROOT"
