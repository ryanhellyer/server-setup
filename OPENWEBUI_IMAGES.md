# Open WebUI image generation via OpenRouter

Open WebUI's `openai` image engine speaks the **OpenAI Images API**, not
OpenRouter's Images API. This repo therefore runs a tiny internal adapter
(`openrouter-images`) and points Open WebUI at it. No new public endpoint is
added: the adapter has no `ports:` mapping and is reachable only by container
name on the compose `web` network, in front of which nginx/Authelia are
unchanged.

```
browser -> nginx (Authelia) -> open-webui:8080
                                   |
                                   | POST http://openrouter-images:8080/v1/images/generations
                                   v
                             openrouter-images
                                   |
                                   | POST https://openrouter.ai/api/v1/images
                                   v
                             OpenRouter
```

## Step 1 findings (request shape and endpoint checks)

### What Open WebUI actually sends

Source: `backend/open_webui/routers/images.py` in
`ghcr.io/open-webui/open-webui:main` (the image tag in `compose.yaml`).

* Generation: `POST {IMAGES_OPENAI_API_BASE_URL}/images/generations`
  * `Authorization: Bearer {IMAGES_OPENAI_API_KEY}`
  * JSON body: `model`, `prompt`, `n`, `size` (from the request or
    `IMAGE_SIZE`), and `response_format: "b64_json"` unless the model matches
    `IMAGE_URL_RESPONSE_MODELS_REGEX_PATTERN` (default `^gpt-image`), plus any
    `IMAGES_OPENAI_API_PARAMS`.
* Edit: `POST {IMAGES_EDIT_OPENAI_API_BASE_URL}/images/edits` (multipart), with
  `model`, `prompt`, `n`, `size`, `background`, `response_format`, and one or
  more `image` / `image[]` file fields.

Open WebUI always appends `/images/generations`, so an env-only configuration
pointed at `https://openrouter.ai/api/v1` would request
`/api/v1/images/generations`, not OpenRouter's documented `/api/v1/images`.
It also sends an OpenAI pixel `size`, which some OpenRouter providers reject.
That is why an adapter is required (option 2b/2c in the task).

### OpenRouter endpoint probe (no key present in this environment)

| Request | Result |
| --- | --- |
| `POST https://openrouter.ai/api/v1/images` | `401` (endpoint exists, auth required) |
| `POST https://openrouter.ai/api/v1/images/generations` | `401` (gateway returns auth before routing; **not** treated as compatible) |
| `POST https://openrouter.ai/v1/images/generations` | `404` (not found) |
| `GET https://openrouter.ai/api/v1/images/models` | `200`, 62 image models; `openai/gpt-image-2` present |

The key itself cannot be validated from this workspace (no `.env` / secret
store is mounted here). Run the key check in "Verification" on the host.

OpenRouter's published OpenAPI document (`https://openrouter.ai/openapi.json`)
confirms the `/images` request schema used by the adapter: `aspect_ratio`
(enum), `resolution` (`512`/`768`/`1K`/`1.5K`/`2K`/`4K`), `output_format`,
`quality`, `seed`, and `input_references` as `ContentPartImage` objects
(`{"type":"image_url","image_url":{"url":...}}`).

## Configuration

`scripts/provision-openwebui.sh` fills only missing values in `.env` (an
explicit operator choice always wins) and compose passes the same
`OPENROUTER_API_KEY` to both Open WebUI and the adapter:

```dotenv
ENABLE_IMAGE_GENERATION=True
IMAGE_GENERATION_ENGINE=openai
IMAGES_OPENAI_API_BASE_URL=http://openrouter-images:8080/v1
IMAGE_GENERATION_MODEL=openai/gpt-image-2
IMAGE_SIZE=1024x1024
```

`IMAGES_OPENAI_API_KEY` is set in `compose.yaml` from `OPENROUTER_API_KEY`
(there is no second copy of the key). The adapter uses that same key.

The adapter translates the request:

* `size: "1024x1024"` -> `aspect_ratio: "1:1"` + `resolution: "1K"`
  (`1792x1024` -> `16:9` + `1.5K`, etc.).
* passes through `n`, `quality`, `background`, `output_format`, `seed`,
  `aspect_ratio`, `resolution`, and `input_references` when present;
* does **not** forward OpenAI's pixel `size` or `response_format`;
* normalises OpenRouter's `{"data":[{"b64_json":...,"media_type":...}]}`
  response into the OpenAI shape Open WebUI expects (`created`, `data`,
  `usage`);
* supports `/images/edits` by converting multipart `image` / `image[]` files
  into OpenRouter `input_references` `ContentPartImage` objects
  (`{"type":"image_url","image_url":{"url":"data:..."}}`).

Optional edit wiring is in `compose.yaml` but disabled by default. Set
`ENABLE_IMAGE_EDIT=True` in `.env` to enable it.

## Apply

```bash
# official provisioning path (repo data restore + compose up + health waits)
sudo bash scripts/provision-openwebui.sh

# or, to only rebuild/recreate the two services without restoring data
cd /workspace
sudo podman compose up -d --build openrouter-images open-webui
```

Environment values only seed Open WebUI's database on first boot. If the DB
already has `image_generation.*` rows (including a disabled state), the DB
wins. Apply the DB-backed settings with the opt-in helper or the Admin UI:

```bash
# admin API key/JWT from Open WebUI (Settings > Account > API Keys)
OPENWEBUI_ADMIN_TOKEN='<admin-api-key>' \
  bash scripts/configure-openwebui-images.sh --model '<workspace-model-id>'
```

The helper sets the image config, the default-user `features.image_generation`
permission, and (for each `--model`) the per-model capability plus
`defaultFeatureIds`. It never prints the key or token. If
`OPENWEBUI_ADMIN_TOKEN` is present in `.env`, `provision-openwebui.sh` calls it
automatically against the localhost publish (`http://127.0.0.1:3000`, so it
does not go through Authelia); without a token it warns and leaves the
DB-backed values to the Admin UI.

## Verification

Load the secret into the shell without printing it:

```bash
cd /workspace
set -a; . ./.env; set +a
```

### 1. From inside the Open WebUI container, adapter returns a real PNG

```bash
sudo podman exec open-webui sh -lc '
  curl -fsS -X POST http://openrouter-images:8080/v1/images/generations \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"openai/gpt-image-2\",\"prompt\":\"A white sign with HELLO in bold black text\",\"n\":1,\"size\":\"1024x1024\",\"response_format\":\"b64_json\"}" \
    -o /tmp/adapter.json &&
  python3 -c "import json,base64; d=json.load(open(\"/tmp/adapter.json\")); r=base64.b64decode(d[\"data\"][0][\"b64_json\"]); open(\"/tmp/adapter-test.png\",\"wb\").write(r); print(\"bytes\",len(r),\"magic\",r[:8])"
'
sudo podman cp open-webui:/tmp/adapter-test.png /tmp/adapter-test.png
file /tmp/adapter-test.png   # PNG image data, ...
```

### 2. Same path Open WebUI itself uses, through its own API

Create a user API key in Open WebUI (`Settings > Account > API Keys`), then use
the **localhost publish** (port 3000) so the request does not hit Authelia:

```bash
TOKEN='<openwebui-user-api-key>'
BASE=http://127.0.0.1:3000
RESP="$(curl -fsS -X POST "$BASE/api/v1/images/generations" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"prompt":"A white sign with HELLO in bold black text","size":"1024x1024","n":1}')"
ID="$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')"
curl -fsS "$BASE/api/v1/files/$ID/content" \
  -H "Authorization: Bearer $TOKEN" -o /tmp/owui-image.png
file /tmp/owui-image.png
```

This exercises Open WebUI's `/api/v1/images/generations` -> adapter path and
returns the stored PNG. (The same request through
`https://chat.hellyer.kiwi` must first pass Authelia, so it needs a browser
session or is better left to the UI.)

### 3. Model slug is valid

```bash
curl -fsS https://openrouter.ai/api/v1/images/models \
 | python3 -c 'import json,sys; ids=[m["id"] for m in json.load(sys.stdin)["data"]]; print("models:",len(ids)); print("openai/gpt-image-2:", "PRESENT" if "openai/gpt-image-2" in ids else "ABSENT")'
```

### 4. Key is valid (billable: generates one image)

```bash
curl -sS -o /tmp/or-keycheck.json -w 'HTTP %{http_code}\n' \
  -X POST https://openrouter.ai/api/v1/images \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"openai/gpt-image-2","prompt":"A plain white square","n":1,"aspect_ratio":"1:1","resolution":"512"}'
```

`200` means the key and model are valid. A `401` means the key is wrong or
missing; a `4xx` naming the model means the slug is unavailable to that key.

## Per-model, permission, and message-input toggle

All three gates must be open:

1. **Global**: Admin > Settings > Images -> enable image generation, engine
   `openai`, base URL `http://openrouter-images:8080/v1`, key, model
   `openai/gpt-image-2`, size `1024x1024`.
   API: `GET /api/v1/images/config`, `POST /api/v1/images/config/update`.
2. **Role permission**: Admin > Users > Default Permissions > Features >
   Image Generation. Groups can override this; check Admin > Users > Groups
   if a non-admin still lacks the feature.
   API: `GET/POST /api/v1/users/default/permissions` with
   `{"features":{"image_generation":true}}` merged into the full object.
3. **Per model**: Workspace > Models > Edit -> Capabilities -> Image
   Generation. On the same screen, Default Features -> Image Generation makes
   the message-input toggle start on.
   API: `GET /api/v1/models/model?id=<id>` then
   `POST /api/v1/models/model/update` with the full model payload and
   `meta.capabilities.image_generation=true`; add `"image_generation"` to
   `meta.defaultFeatureIds` for the default-on toggle.

The **Image toggle in the message input's Integrations menu** is client-side
per-chat state (it defaults from the model capability + default feature +
permission above). It is not a server setting and cannot be set through the
API; the helper makes it default to on, and the user can still toggle it.

## Rollback

Quick disable (no code change):

```bash
# Prefer the Admin UI (Settings > Images) or the API if the DB already has a value;
# env changes alone do not override an existing DB row.
sudo podman compose up -d --force-recreate open-webui
```

Full removal of this change:

```bash
cd /workspace
git revert <commit-that-added-this>     # or restore the edited files by hand
sudo podman rm -f openrouter-images
sudo podman compose up -d --force-recreate open-webui
# optional: sudo podman rmi localhost/openrouter-images
```

The `.env` image-generation values can stay (harmless) or be deleted. The
adapter is the only new container and it has no published port or volume, so
removing it leaves no host state behind.

## Security notes

* The adapter is attached to `web` only, with **no `ports:` mapping**; it is
  not publicly routable and Authelia/forward-auth is untouched.
* The OpenRouter key is passed as an environment variable to server-side
  containers only. It is never written into the frontend bundle or sent to the
  browser by this change. (Open WebUI's admin-only config API can read the key,
  as before.)
* The adapter never logs request headers, the key, or response bodies.
* Open WebUI's `IMAGES_OPENAI_API_KEY` and the adapter's `OPENROUTER_API_KEY`
  are the same value from the existing `.env` secret store; no second key is
  created.
