#!/usr/bin/env bash
# =============================================================================
# configure-openwebui-images.sh — opt-in: apply image-generation settings
# through the Open WebUI admin API.
#
# Environment-backed defaults are only *seeded* into Open WebUI's database on
# first boot; once an image_generation.* row exists, the DB value wins. This
# helper updates those rows (and the default-user permission, and optionally
# per-model capabilities) through the same API the admin UI uses.
#
#   OPENWEBUI_ADMIN_TOKEN='<admin API key / JWT>' \
#     bash scripts/configure-openwebui-images.sh
#
#   # also enable image generation on specific workspace model entries and
#   # make the message-input Image toggle default to on for them:
#   OPENWEBUI_ADMIN_TOKEN='...' \
#     bash scripts/configure-openwebui-images.sh --model my-chat-model
#
# The token is read from the environment, passed to curl on stdin (never in
# argv) and the API's JSON (which includes the OpenRouter key) only ever lives
# in 0600 temp files. Nothing secret is printed.
#
# Options:
#   --base URL          Open WebUI base URL (default: $OPENWEBUI_API_BASE or
#                       http://127.0.0.1:3000 — the localhost publish, so the
#                       request does not go through Authelia)
#   --model ID          workspace model id to update (repeatable)
#   --no-image-config   skip /api/v1/images/config/update
#   --no-permission     skip /api/v1/users/default/permissions
#   -h, --help          this help
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

BASE="${OPENWEBUI_API_BASE:-http://127.0.0.1:3000}"
TOKEN="${OPENWEBUI_ADMIN_TOKEN:-}"
DO_CONFIG=1
DO_PERM=1
MODELS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:?--base needs a value}"; shift 2 ;;
    --model) MODELS+=("${2:?--model needs a value}"); shift 2 ;;
    --no-image-config) DO_CONFIG=0; shift ;;
    --no-permission) DO_PERM=0; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

BASE="${BASE%/}"
[ -n "$TOKEN" ] || die "Set OPENWEBUI_ADMIN_TOKEN to an admin API key/JWT (never hardcode it)."
command -v curl >/dev/null || die "curl is required."
command -v python3 >/dev/null || die "python3 is required."

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Token reaches curl via a config file on stdin, not argv.
api_get() { # PATH
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
    | curl -K - -fsS --max-time 30 "$BASE$1"
}
api_post_file() { # PATH JSON_FILE
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
    | curl -K - -fsS --max-time 60 -X POST "$BASE$1" \
        -H 'Content-Type: application/json' --data-binary "@$2"
}

merge_json() { # BASE PATCH OUT — recursive object merge, patch wins
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys

with open(sys.argv[1]) as fh:
    base = json.load(fh)
with open(sys.argv[2]) as fh:
    patch = json.load(fh)

def merge(dst, src):
    for key, value in src.items():
        if isinstance(value, dict) and isinstance(dst.get(key), dict):
            merge(dst[key], value)
        else:
            dst[key] = value
    return dst

with open(sys.argv[3], 'w') as fh:
    json.dump(merge(base, patch), fh, separators=(',', ':'))
PY
}

# ---- image generation config -------------------------------------------------
if [ "$DO_CONFIG" = 1 ]; then
  say "Reading current image configuration"
  api_get /api/v1/images/config >"$TMP/images.json"

  cat >"$TMP/images.patch.json" <<'JSON'
{
  "ENABLE_IMAGE_GENERATION": true,
  "IMAGE_GENERATION_ENGINE": "openai",
  "IMAGES_OPENAI_API_BASE_URL": "http://openrouter-images:8080/v1",
  "IMAGE_GENERATION_MODEL": "openai/gpt-image-2",
  "IMAGE_SIZE": "1024x1024"
}
JSON

  merge_json "$TMP/images.json" "$TMP/images.patch.json" "$TMP/images.out.json"
  if [ "$(python3 -c 'import json,sys; print("yes" if json.load(open(sys.argv[1])).get("IMAGES_OPENAI_API_KEY") else "no")' "$TMP/images.out.json")" != "yes" ]; then
    warn "Open WebUI reports no image API key — set OPENROUTER_API_KEY in .env and re-run provision-openwebui.sh."
  fi
  api_post_file /api/v1/images/config/update "$TMP/images.out.json" >/dev/null
  ok "Image generation config updated (engine=openai, adapter base, gpt-image-2, 1024x1024)."
fi

# ---- default-user feature permission ----------------------------------------
if [ "$DO_PERM" = 1 ]; then
  say "Reading default user permissions"
  api_get /api/v1/users/default/permissions >"$TMP/perm.json"
  cat >"$TMP/perm.patch.json" <<'JSON'
{"features": {"image_generation": true}}
JSON
  merge_json "$TMP/perm.json" "$TMP/perm.patch.json" "$TMP/perm.out.json"
  api_post_file /api/v1/users/default/permissions "$TMP/perm.out.json" >/dev/null
  ok "Default-user 'features.image_generation' permission enabled."
fi

# ---- per-model capability + default feature ---------------------------------
for model in "${MODELS[@]}"; do
  say "Reading workspace model: $model"
  encoded="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$model")"
  if ! api_get "/api/v1/models/model?id=$encoded" >"$TMP/model.json"; then
    warn "No editable workspace model '$model' (base/provider models must be added in Workspace > Models first)."
    continue
  fi
  python3 - "$TMP/model.json" "$TMP/model.out.json" <<'PY'
import json, sys

with open(sys.argv[1]) as fh:
    model = json.load(fh)

meta = model.get("meta") or {}
capabilities = meta.get("capabilities") or {}
capabilities["image_generation"] = True
meta["capabilities"] = capabilities
defaults = meta.get("defaultFeatureIds") or []
if "image_generation" not in defaults:
    defaults.append("image_generation")
meta["defaultFeatureIds"] = defaults

payload = {key: model.get(key) for key in ("id", "base_model_id", "name", "params", "is_active")}
payload["meta"] = meta
payload.setdefault("is_active", True)
with open(sys.argv[2], "w") as fh:
    json.dump(payload, fh, separators=(",", ":"))
PY
  api_post_file /api/v1/models/model/update "$TMP/model.out.json" >/dev/null
  ok "Model '$model': image_generation capability enabled and set as a default feature."
done

echo
ok "Done. Refresh the Open WebUI page; the Image toggle is in the Integrations menu of the message input."
