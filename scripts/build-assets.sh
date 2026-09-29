#!/usr/bin/env bash
# =============================================================================
# build-assets.sh — build a site's front-end assets inside the `node` container.
#
#   sudo bash scripts/build-assets.sh instantattend.com
#   sudo bash scripts/build-assets.sh spam-destroyer.com ryan.hellyer.kiwi
#   sudo bash scripts/build-assets.sh --all
#   sudo bash scripts/build-assets.sh --all --force
#   sudo bash scripts/build-assets.sh --dry-run --all
#
# For each site with a package.json `build` script it runs (in the node
# container, which shares the host web root at /var/www):
#
#   npm ci   (falls back to `npm install`; or install directly with no lockfile)
#   npm run build
#
# Why this exists: build output (e.g. Laravel/Vite public/build/) lives in the
# site snapshot, and a snapshot can capture the Vite manifest.json and its
# hashed assets/ from two different builds. After a restore the manifest then
# points at CSS/JS files that no longer exist, so the site serves 404s and looks
# unstyled. Rebuilding makes them consistent again.
#
# By default only sites whose Vite output is MISSING or INCONSISTENT are built
# (manifest.json references files that are not on disk), so ordinary deploys of
# healthy sites cost nothing. Use --force to rebuild unconditionally.
#
# The stack must be up (the node container must be running).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh
WWW_ROOT="$(resolve_www_root)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

ALL=0; FORCE=0; DRY=0; SITES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *) SITES+=("$1"); shift ;;
  esac
done

if [ "$ALL" = 1 ] && [ "${#SITES[@]}" -eq 0 ]; then
  for d in "$WWW_ROOT"/*/; do
    [ -f "$d/package.json" ] && SITES+=("$(basename "${d%/}")")
  done
fi
[ "${#SITES[@]}" -gt 0 ] || die "Usage: build-assets.sh <site> [site...] | --all"

# ---- helpers ----------------------------------------------------------------
has_build_script() { # DIR
  python3 - "$1/package.json" <<'PY'
import json, sys
try:
    pkg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(pkg.get("scripts"), dict) and pkg["scripts"].get("build") else 1)
PY
}

# Vite output is healthy when manifest.json exists and every file it references
# is present under public/build/.
vite_output_ok() { # DIR
  local manifest="$1/public/build/manifest.json"
  [ -f "$manifest" ] || return 1
  python3 - "$1" <<'PY'
import json, os, sys
site = sys.argv[1]
build = os.path.join(site, "public", "build")
try:
    data = json.load(open(os.path.join(build, "manifest.json")))
except Exception:
    sys.exit(1)
for entry in data.values():
    if not isinstance(entry, dict):
        continue
    files = []
    if entry.get("file"):
        files.append(entry["file"])
    files += entry.get("css", []) or []
    files += entry.get("assets", []) or []
    for f in files:
        if not os.path.exists(os.path.join(build, f)):
            sys.exit(1)
sys.exit(0)
PY
}

needs_build() { # DIR
  local dir="$1"
  if [ "$FORCE" = 1 ]; then return 0; fi
  # Only Vite has the manifest/assets split-brain problem; leave hand-rolled
  # single-file builds (esbuild/tsc) alone unless --force is given.
  if ! grep -q 'vite' "$dir/package.json" 2>/dev/null; then return 1; fi
  if vite_output_ok "$dir"; then return 1; fi
  return 0
}

node_running() {
  podman container exists "$CONTAINER_NODE" 2>/dev/null || return 1
  [ "$(podman inspect -f '{{.State.Running}}' "$CONTAINER_NODE" 2>/dev/null)" = "true" ] || return 1
}

# ---- build each site --------------------------------------------------------
FAILED=()
for site in "${SITES[@]}"; do
  dir="$WWW_ROOT/$site"
  if [ ! -d "$dir" ]; then
    warn "$site: no such directory ($dir) — skipping"
    FAILED+=("$site"); continue
  fi
  if [ ! -f "$dir/package.json" ]; then
    warn "$site: no package.json — skipping"
    continue
  fi
  if ! has_build_script "$dir"; then
    say "$site: no build script — skipping"
    continue
  fi
  if ! needs_build "$dir"; then
    ok "$site: no rebuild needed (assets look fine, or not a Vite site) — use --force to rebuild"
    continue
  fi

  say "Building assets: $site"
  cmd='if [ -f package-lock.json ]; then npm ci --no-audit --no-fund || npm install --no-audit --no-fund; else npm install --no-audit --no-fund; fi && npm run build'
  if [ "$DRY" = 1 ]; then
    printf '    DRY: podman exec -u 0 -w %s/%s %s sh -lc %q\n' \
      "$CONTAINER_WWW" "$site" "$CONTAINER_NODE" "$cmd"
    continue
  fi

  if ! node_running; then
    warn "$site: $CONTAINER_NODE container is not running — start the stack (sudo podman compose up -d node)"
    FAILED+=("$site"); continue
  fi

  if podman exec -u 0 -w "$CONTAINER_WWW/$site" "$CONTAINER_NODE" sh -lc "$cmd"; then
    # The build ran as root inside the container; restore the web perms model.
    bash "$PWD/scripts/fix-perms.sh" "$dir" >/dev/null
    ok "Built: $site"
  else
    warn "Build FAILED: $site"
    FAILED+=("$site")
  fi
done

echo
if [ "${#FAILED[@]}" -gt 0 ]; then
  warn "Failures: ${FAILED[*]}"
  exit 1
fi
ok "Done."
