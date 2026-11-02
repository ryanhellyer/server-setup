"""Minimal OpenAI Images API -> OpenRouter Images API adapter.

Open WebUI's `openai` image engine always calls
`POST {IMAGES_OPENAI_API_BASE_URL}/images/generations` (JSON) and, for edits,
`POST {IMAGES_OPENAI_API_BASE_URL}/images/edits` (multipart).  OpenRouter's
image endpoint is `POST https://openrouter.ai/api/v1/images` and takes
`aspect_ratio` / `resolution` instead of an OpenAI pixel `size`.

This service translates between the two, is reachable only on the compose
`web` network, and never logs the API key or request headers.
"""

from __future__ import annotations

import base64
import logging
import math
import os
import time
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO").upper())
log = logging.getLogger("openrouter-images")

API_BASE = os.getenv("OPENROUTER_API_BASE", "https://openrouter.ai/api/v1").rstrip("/")
API_KEY = os.getenv("OPENROUTER_API_KEY", "").strip()
DEFAULT_MODEL = os.getenv("OPENROUTER_IMAGES_MODEL", "openai/gpt-image-2")
DEFAULT_SIZE = os.getenv("OPENROUTER_IMAGE_SIZE", "1024x1024")
DEFAULT_OUTPUT_FORMAT = os.getenv("OPENROUTER_IMAGE_OUTPUT_FORMAT", "png")
TIMEOUT = float(os.getenv("OPENROUTER_IMAGES_TIMEOUT", "180"))

# OpenRouter's documented aspect_ratio enum (plus a few common equivalents).
_KNOWN_RATIOS = (
    (1, 1, "1:1"),
    (4, 3, "4:3"),
    (3, 4, "3:4"),
    (3, 2, "3:2"),
    (2, 3, "2:3"),
    (5, 4, "5:4"),
    (4, 5, "4:5"),
    (16, 9, "16:9"),
    (9, 16, "9:16"),
    (21, 9, "21:9"),
)

app = FastAPI(
    title="OpenRouter Images adapter",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


def _dimensions(size: str | None) -> tuple[int, int] | None:
    if not size or "x" not in size.lower():
        return None
    try:
        w, h = (int(part) for part in size.lower().split("x", 1))
    except ValueError:
        return None
    return (w, h) if w > 0 and h > 0 else None


def _aspect_ratio(w: int, h: int) -> str:
    divisor = math.gcd(w, h)
    rw, rh = w // divisor, h // divisor
    for aw, ah, label in _KNOWN_RATIOS:
        if (rw, rh) == (aw, ah):
            return label
    target = w / h
    return min(_KNOWN_RATIOS, key=lambda r: abs(r[0] / r[1] - target))[2]


def _resolution(w: int, h: int) -> str:
    longest = max(w, h)
    for min_px, label in (
        (4096, "4K"),
        (2048, "2K"),
        (1536, "1.5K"),
        (1024, "1K"),
        (768, "768"),
        (512, "512"),
    ):
        if longest >= min_px:
            return label
    return "512"


def _references(items: Any) -> list[dict[str, Any]]:
    """Normalise to OpenRouter's ContentPartImage list.

    OpenRouter expects ``{"type": "image_url", "image_url": {"url": ...}}``;
    bare strings (from our multipart edit handler or a caller) are wrapped.
    """
    result: list[dict[str, Any]] = []
    if not isinstance(items, list):
        return result
    for item in items:
        if isinstance(item, str) and item:
            result.append({"type": "image_url", "image_url": {"url": item}})
        elif isinstance(item, dict) and item.get("image_url"):
            result.append(item)
    return result


def _payload(
    *,
    prompt: str,
    model: str | None = None,
    n: Any = None,
    size: str | None = None,
    quality: Any = None,
    background: Any = None,
    output_format: Any = None,
    seed: Any = None,
    aspect_ratio: Any = None,
    resolution: Any = None,
    input_references: Any = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "model": model or DEFAULT_MODEL,
        "prompt": prompt,
    }

    if n is not None:
        try:
            payload["n"] = max(1, min(10, int(n)))
        except (TypeError, ValueError):
            pass

    dims = _dimensions(size) or _dimensions(DEFAULT_SIZE)
    if dims:
        payload["aspect_ratio"] = _aspect_ratio(*dims)
        payload["resolution"] = _resolution(*dims)
    if aspect_ratio:
        payload["aspect_ratio"] = str(aspect_ratio)
    if resolution:
        payload["resolution"] = str(resolution)

    if quality:
        payload["quality"] = str(quality)
    if background:
        payload["background"] = str(background)
    fmt = output_format or DEFAULT_OUTPUT_FORMAT
    if fmt:
        payload["output_format"] = str(fmt)
    if seed is not None:
        payload["seed"] = seed
    references = _references(input_references)
    if references:
        payload["input_references"] = references

    return payload


def _normalize(response: Any) -> dict[str, Any]:
    if not isinstance(response, dict):
        raise ValueError("OpenRouter returned a non-object response")
    data = response.get("data")
    if not isinstance(data, list) or not data:
        raise ValueError("OpenRouter response has no image data")

    images: list[dict[str, Any]] = []
    for item in data:
        if not isinstance(item, dict):
            continue
        entry: dict[str, Any] = {}
        if item.get("b64_json"):
            entry["b64_json"] = item["b64_json"]
        elif item.get("url"):
            entry["url"] = item["url"]
        elif item.get("image_url"):
            entry["url"] = item["image_url"]
        else:
            continue
        if item.get("media_type"):
            entry["media_type"] = item["media_type"]
        if item.get("revised_prompt"):
            entry["revised_prompt"] = item["revised_prompt"]
        images.append(entry)

    if not images:
        raise ValueError("OpenRouter response has no usable image entries")

    result: dict[str, Any] = {
        "created": int(response.get("created") or time.time()),
        "data": images,
    }
    if response.get("usage"):
        result["usage"] = response["usage"]
    return result


def _bearer(request: Request) -> str:
    if API_KEY:
        return API_KEY
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        return header[7:].strip()
    return ""


async def _call(payload: dict[str, Any], request: Request) -> dict[str, Any]:
    key = _bearer(request)
    if not key:
        raise HTTPException(status_code=500, detail="OPENROUTER_API_KEY is not configured")

    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }
    timeout = httpx.Timeout(TIMEOUT, connect=10.0)
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            upstream = await client.post(f"{API_BASE}/images", json=payload, headers=headers)
    except httpx.HTTPError as exc:
        log.warning("OpenRouter request failed: %s", type(exc).__name__)
        raise HTTPException(status_code=502, detail=f"OpenRouter request failed: {type(exc).__name__}")

    if upstream.status_code >= 400:
        try:
            detail = upstream.json()
        except ValueError:
            detail = {"error": upstream.text[:500]}
        log.warning("OpenRouter returned HTTP %s", upstream.status_code)
        raise HTTPException(status_code=upstream.status_code, detail=detail)

    try:
        body = upstream.json()
    except ValueError:
        raise HTTPException(status_code=502, detail="OpenRouter returned non-JSON")

    try:
        return _normalize(body)
    except ValueError as exc:
        raise HTTPException(status_code=502, detail=str(exc))


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"status": True, "model": DEFAULT_MODEL}


@app.post("/v1/images/generations")
@app.post("/images/generations")
@app.post("/api/v1/images/generations")
async def generations(request: Request) -> JSONResponse:
    try:
        body = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="Request body must be JSON")

    prompt = body.get("prompt")
    if not prompt:
        raise HTTPException(status_code=400, detail="prompt is required")

    payload = _payload(
        prompt=str(prompt),
        model=body.get("model"),
        n=body.get("n"),
        size=body.get("size"),
        quality=body.get("quality"),
        background=body.get("background"),
        output_format=body.get("output_format"),
        seed=body.get("seed"),
        aspect_ratio=body.get("aspect_ratio"),
        resolution=body.get("resolution"),
        input_references=body.get("input_references"),
    )
    return JSONResponse(await _call(payload, request))


@app.post("/v1/images/edits")
@app.post("/images/edits")
@app.post("/api/v1/images/edits")
async def edits(request: Request) -> JSONResponse:
    content_type = request.headers.get("content-type", "")
    fields: dict[str, Any] = {}
    references: list[str] = []

    try:
        if content_type.startswith("multipart/form-data"):
            form = await request.form()
            for key in (
                "prompt",
                "model",
                "n",
                "size",
                "quality",
                "background",
                "output_format",
                "seed",
                "aspect_ratio",
                "resolution",
            ):
                value = form.get(key)
                if value is not None:
                    fields[key] = str(value)

            for key in ("image", "image[]", "input_references", "input_references[]"):
                for item in form.getlist(key):
                    if hasattr(item, "read"):
                        raw = await item.read()
                        media_type = getattr(item, "content_type", None) or "image/png"
                        references.append(
                            f"data:{media_type};base64,{base64.b64encode(raw).decode('ascii')}"
                        )
                    elif isinstance(item, str) and item:
                        references.append(item)
        else:
            body = await request.json()
            for key in (
                "prompt",
                "model",
                "n",
                "size",
                "quality",
                "background",
                "output_format",
                "seed",
                "aspect_ratio",
                "resolution",
            ):
                if body.get(key) is not None:
                    fields[key] = body[key]
            incoming = body.get("input_references") or body.get("image")
            if isinstance(incoming, str):
                references = [incoming]
            elif isinstance(incoming, list):
                references = [str(item) for item in incoming if item]
    except (ValueError, RuntimeError) as exc:
        raise HTTPException(status_code=400, detail=f"Invalid edit request: {type(exc).__name__}")

    prompt = fields.get("prompt")
    if not prompt:
        raise HTTPException(status_code=400, detail="prompt is required")
    if not references:
        raise HTTPException(status_code=400, detail="at least one input image is required")

    payload = _payload(
        prompt=str(prompt),
        model=fields.get("model"),
        n=fields.get("n"),
        size=fields.get("size"),
        quality=fields.get("quality"),
        background=fields.get("background"),
        output_format=fields.get("output_format"),
        seed=fields.get("seed"),
        aspect_ratio=fields.get("aspect_ratio"),
        resolution=fields.get("resolution"),
        input_references=references,
    )
    return JSONResponse(await _call(payload, request))
