#!/usr/bin/env bash
# =============================================================================
# provision-openwebui.sh — restore the Open WebUI data directory from the
# newest storage snapshot and (re)start the `open-webui` container.
#
# Open WebUI is its own container (not a PHP site). Its host data dir is the
# container's /app/backend/data (SQLite DB, uploads/, ChromaDB vector store).
#
#   sudo bash scripts/provision-openwebui.sh
#
# Always fresh: the data dir is rsynced with --delete (skipping the transient
# SQLite WAL/shm, cache/ and the old tooling).
#
# Options: --no-files, --drop-vector-db, --dry-run
#
# Config: see scripts/lib-storage.sh.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-paths.sh
source scripts/lib-storage.sh
source scripts/lib-env.sh
WWW_ROOT="$(resolve_www_root)"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

SITE_DIR="chat.hellyer.kiwi"
DO_FILES=1; DROP_VECTOR=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --no-files) DO_FILES=0; shift ;;
    --drop-vector-db) DROP_VECTOR=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

LOCAL_DIR="$WWW_ROOT/$SITE_DIR"
run() { if [ "$DRY" = 1 ]; then printf '    DRY: %s\n' "$*"; else "$@"; fi; }
ensure_default_env() { # KEY VALUE — only fill a missing/blank value in .env
  local key="$1" value="$2" current
  current="$(get_env .env "$key" 2>/dev/null || true)"
  if [ -n "$current" ]; then return 0; fi
  if [ "$DRY" = 1 ]; then
    printf '    DRY: set %s=%s in .env\n' "$key" "$value"
  else
    set_env ".env" "$key" "$value"
  fi
}

SNAP="$(newest_snapshot "$SITE_DIR")"
[ -n "$SNAP" ] || die "No snapshot containing $SITE_DIR under $SNAPSHOT_ROOT."
say "Using snapshot: $SNAP/$SITE_DIR"

# ---- OpenRouter API key (from the old install.sh) ---------------------------
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
  ok "OPENROUTER_API_KEY already set in .env."
else
  say "Reading OPENROUTER_API_KEY from the snapshot's install.sh"
  key="$(box_cat "$SNAP/$SITE_DIR/install.sh" \
        | grep -oE 'OPENROUTER_API_KEY=[^"'"'"' ]+' | head -1 | cut -d= -f2- || true)"
  if [ -n "$key" ]; then
    if [ "$DRY" = 1 ]; then
      echo "    DRY: set OPENROUTER_API_KEY=<redacted> in .env"
    else
      set_env ".env" OPENROUTER_API_KEY "$key"
      ok "Stored OPENROUTER_API_KEY in .env."
    fi
  else
    warn "Could not find OPENROUTER_API_KEY in $SNAP/$SITE_DIR/install.sh."
  fi
fi
# The key may have just been written to .env (set_env does not export it).
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  OPENROUTER_API_KEY="$(get_env .env OPENROUTER_API_KEY 2>/dev/null || true)"
fi

# ---- image generation defaults (idempotent) --------------------------------
# Open WebUI configures image generation separately from the chat connection.
# These point it at the internal `openrouter-images` adapter (OpenAI Images
# API -> OpenRouter Images API). Compose also has safe defaults, but writing
# them to .env makes the state visible and survives a compose-file change.
# Only blank values are filled, so an explicit operator choice always wins.
say "Ensuring image-generation defaults in .env"
ensure_default_env ENABLE_IMAGE_GENERATION True
ensure_default_env IMAGE_GENERATION_ENGINE openai
ensure_default_env IMAGES_OPENAI_API_BASE_URL http://openrouter-images:8080/v1
ensure_default_env IMAGE_GENERATION_MODEL openai/gpt-image-2
ensure_default_env IMAGE_SIZE 1024x1024
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  warn "OPENROUTER_API_KEY is still empty — image generation will fail until it is set in .env."
fi

# ---- data sync (always fresh) ----------------------------------------------
if [ "$DO_FILES" = 1 ]; then
  say "Syncing data -> $LOCAL_DIR"
  run mkdir -p "$LOCAL_DIR"
  run rsync -az --delete \
    --exclude='webui.db-shm' --exclude='webui.db-wal' \
    --exclude='cache' \
    --exclude='install.sh' --exclude='rebuild.sh' --exclude='upgrade.sh' \
    --exclude='TEMP_INSTALL_INSTRUCTIONS.md' \
    -e "ssh -i $STORAGE_KEY -p $STORAGE_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
    "$STORAGE_USER@$STORAGE_HOST:$SNAP/$SITE_DIR/" "$LOCAL_DIR/"
  if [ "$DROP_VECTOR" = 1 ]; then
    say "Dropping vector_db/ so ChromaDB rebuilds"
    run rm -rf "$LOCAL_DIR/vector_db"
  fi
  ADMIN_USER_OWUI="$(resolve_admin_user)"
  [ "$DRY" != 1 ] && chown -R "$ADMIN_USER_OWUI:$ADMIN_USER_OWUI" "$LOCAL_DIR" 2>/dev/null || true
fi

# ---- SQLite sanity check ----------------------------------------------------
# A webui.db captured while Open WebUI was running (WAL not checkpointed) can be
# corrupt, and a corrupt DB makes the container crash-loop on every start. If
# the restored DB fails `PRAGMA integrity_check`, move it aside so Open WebUI
# rebuilds a fresh one instead of looping. Runs the check via the php-fpm
# container (which ships sqlite3); falls back to a host sqlite3 if present.
if [ "$DO_FILES" = 1 ] && [ "$DRY" != 1 ]; then
  DB="$LOCAL_DIR/webui.db"
  CONT_DB="/var/www/$SITE_DIR/webui.db"
  result=""
  if [ -f "$DB" ]; then
    if podman container exists "$CONTAINER_PHP_FPM" 2>/dev/null \
       && podman exec "$CONTAINER_PHP_FPM" sh -c 'command -v sqlite3' >/dev/null 2>&1; then
      result="$(podman exec "$CONTAINER_PHP_FPM" sqlite3 "$CONT_DB" 'PRAGMA integrity_check;' 2>/dev/null | head -1 || true)"
    elif command -v sqlite3 >/dev/null 2>&1; then
      result="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>/dev/null | head -1 || true)"
    fi
    case "$result" in
      ok) ok "webui.db integrity check passed." ;;
      "") warn "Could not run sqlite integrity_check (no sqlite3) — skipping." ;;
      *)  warn "webui.db failed integrity_check ('$result') — moving it aside; Open WebUI will build a fresh DB."
          mv -f "$DB" "$DB.corrupt-$(date +%Y%m%d%H%M%S)" ;;
    esac
  fi
fi

# ---- bring up the containers ------------------------------------------------
say "Bringing up the openrouter-images and open-webui services"
if [ "$DRY" = 1 ]; then
  echo "    DRY: podman-compose up -d --build $CONTAINER_OPENROUTER_IMAGES $CONTAINER_OPENWEBUI"
else
  if podman compose version >/dev/null 2>&1; then
    podman compose up -d --build "$CONTAINER_OPENROUTER_IMAGES" "$CONTAINER_OPENWEBUI"
  else
    podman-compose up -d --build "$CONTAINER_OPENROUTER_IMAGES" "$CONTAINER_OPENWEBUI"
  fi
fi

# ---- wait for the image adapter --------------------------------------------
if [ "$DRY" != 1 ]; then
  say "Waiting for the OpenRouter image adapter"
  up=0
  for _ in $(seq 1 30); do
    if podman exec "$CONTAINER_OPENROUTER_IMAGES" python3 -c \
         "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=3).status==200 else 1)" \
         >/dev/null 2>&1; then
      ok "openrouter-images is up."; up=1; break
    fi
    sleep 2
  done
  [ "$up" = 1 ] || warn "openrouter-images did not answer — check: podman logs openrouter-images"
fi

# ---- wait for health --------------------------------------------------------
if [ "$DRY" != 1 ]; then
  say "Waiting for Open WebUI on http://127.0.0.1:3000/api/version"
  up=0
  for _ in $(seq 1 60); do
    if curl -sf --max-time 5 http://127.0.0.1:3000/api/version >/tmp/owui-version.json 2>/dev/null; then
      ok "Open WebUI is up: $(cat /tmp/owui-version.json)"; up=1; break
    fi
    sleep 5
  done
  [ "$up" = 1 ] || warn "Open WebUI did not answer in 5 min — check: podman logs open-webui"
fi

# ---- apply DB-backed image settings (optional) -----------------------------
# Env vars only seed Open WebUI's config DB on first boot; existing
# image_generation.* rows win. With an admin token we can update them through
# the same API the admin UI uses. Without one, the env defaults still apply on
# a fresh DB, and the settings can be applied once in Admin > Settings > Images.
if [ "$DRY" != 1 ]; then
  if [ -n "${OPENWEBUI_ADMIN_TOKEN:-}" ]; then
    say "Applying image-generation settings through the Open WebUI admin API"
    OPENWEBUI_ADMIN_TOKEN="$OPENWEBUI_ADMIN_TOKEN" \
      bash scripts/configure-openwebui-images.sh --base http://127.0.0.1:3000 \
      || warn "Could not apply image settings via the API — use Admin > Settings > Images."
  else
    warn "OPENWEBUI_ADMIN_TOKEN not set; if webui.db already has image_generation.* rows, apply them once via Admin > Settings > Images or scripts/configure-openwebui-images.sh."
  fi
fi

if [ "$DRY" != 1 ]; then
  podman exec "$CONTAINER_NGINX" nginx -t >/dev/null 2>&1 \
    && podman exec "$CONTAINER_NGINX" nginx -s reload >/dev/null 2>&1 || true
fi
ok "Done: $SITE_DIR (Open WebUI)"
