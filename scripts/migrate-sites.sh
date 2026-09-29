#!/usr/bin/env bash
# =============================================================================
# migrate-sites.sh — provision every site found in the newest storage snapshot.
#
#   sudo bash scripts/migrate-sites.sh                 # all sites
#   sudo bash scripts/migrate-sites.sh cvs.hellyer.kiwi spam-destroyer.com
#   sudo bash scripts/migrate-sites.sh --dry-run
#
# With no site arguments it lists the newest dated snapshot under SNAPSHOT_ROOT
# and keeps the directories that look like sites (contain public/ or public_html/
# or .env or wp-config.php), skipping backup scripts / config dirs.
#
# Flags passed through to provision-site.sh: --files-only --db-only --dry-run.
#
# Config: see scripts/lib-storage.sh.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-paths.sh
source scripts/lib-storage.sh

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }

ALL=0; OPTS=(); SITE_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --dry-run) OPTS+=("$arg") ;;
    --files-only|--db-only) OPTS+=("$arg") ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $arg" >&2; exit 1 ;;
    *) SITE_ARGS+=("$arg") ;;
  esac
done

SNAP="$(newest_snapshot)"
[ -n "$SNAP" ] || { echo "No snapshot found under $SNAPSHOT_ROOT." >&2; exit 1; }
export SNAPSHOT_DIR="$SNAP"   # so provision-site.sh doesn't re-discover per site

# ---- collect site dirs ------------------------------------------------------
# Discovery lives in lib-storage.sh (snapshot_site_dirs) so that
# provision-extras.sh can copy exactly the complement into ~/tools.
SITES=()
if [ "$ALL" = 1 ] || [ "${#SITE_ARGS[@]}" -eq 0 ]; then
  say "Discovering sites in $STORAGE_USER@$STORAGE_HOST:$SNAP"
  box_ssh "ls '$SNAP/'" >/dev/null 2>&1 || { echo "Could not list $SNAP on the box." >&2; exit 1; }
  while IFS= read -r name; do
    [ -n "$name" ] && SITES+=("$name")
  done <<< "$(snapshot_site_dirs "$SNAP")"
else
  SITES=("${SITE_ARGS[@]}")
fi

[ "${#SITES[@]}" -gt 0 ] || { warn "No sites to provision."; exit 0; }
say "Sites: ${SITES[*]}"
echo

FAILED=()
for site in "${SITES[@]}"; do
  echo "================================================================"
  say "Provisioning $site"
  if bash "$PWD/scripts/provision-site.sh" "$site" "${OPTS[@]}"; then
    :
  else
    warn "FAILED: $site"; FAILED+=("$site")
  fi
  echo
done

echo "================================================================"
echo "Provisioned: $(( ${#SITES[@]} - ${#FAILED[@]} ))/${#SITES[@]}"
if [ "${#FAILED[@]}" -gt 0 ]; then
  warn "Failures: ${FAILED[*]}"
  exit 1
fi
