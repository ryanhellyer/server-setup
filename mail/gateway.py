#!/usr/bin/env python3
"""mailrelay — catch-all SMTP sink that forwards every message to Telegram.

See EMAILS.md. Configured entirely through environment variables (passed by
compose.yaml), so no secrets are ever written to disk:

  TELEGRAM_BOT_TOKEN   Bot API token from @BotFather          (required)
  TELEGRAM_CHAT_ID     target chat/group id                   (required)
  MAIL_TELEGRAM_MODE   all | local | allowlist                (default: all)
  MAIL_LOCAL_DOMAINS   comma list used by `local` mode
  MAIL_ALLOW_REGEX     regex used by `allowlist` mode
  MAIL_DENY_REGEX      regex; any match drops the message
  MAIL_FROM_ADDRESS    fallback From when a message has none  (server@hellyer.kiwi)
  MAIL_MAX_ATTEMPTS    send attempts before -> spool/failed   (default: 12)
  MAIL_SPOOL_DIR       spool directory                        (/var/spool/mailrelay)
  MAIL_HEALTH_PORT     health HTTP port                       (default: 8080)

Reliability: a message is written to the spool BEFORE the SMTP 250 is returned
and removed only after Telegram accepts it, so a Telegram/network outage defers
rather than drops. Failures retry with backoff; after MAIL_MAX_ATTEMPTS the
message is moved to spool/failed/ and logged.

This is a display-only, one-way relay. It never delivers mail to recipients.
"""

import email
import email.policy
import hashlib
import html
import json
import logging
import os
import re
import threading
import time
import uuid
from email.utils import parseaddr
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib import request as urlrequest
from urllib.error import HTTPError, URLError

from aiosmtpd.controller import Controller

log = logging.getLogger("mailrelay")


def env(name, default=""):
    return os.environ.get(name, default).strip()


BOT_TOKEN = env("TELEGRAM_BOT_TOKEN")
CHAT_ID = env("TELEGRAM_CHAT_ID")
MODE = env("MAIL_TELEGRAM_MODE", "all").lower() or "all"
LOCAL_DOMAINS = [d.strip().lower() for d in env("MAIL_LOCAL_DOMAINS").split(",") if d.strip()]
ALLOW_RE = env("MAIL_ALLOW_REGEX")
DENY_RE = env("MAIL_DENY_REGEX")
FROM_FALLBACK = env("MAIL_FROM_ADDRESS", "server@hellyer.kiwi")
MAX_ATTEMPTS = max(1, int(env("MAIL_MAX_ATTEMPTS", "12") or 12))
SPOOL = env("MAIL_SPOOL_DIR", "/var/spool/mailrelay")
HEALTH_PORT = int(env("MAIL_HEALTH_PORT", "8080") or 8080)
TG_TEXT_LIMIT = 4000  # Telegram's hard cap is 4096; leave headroom
BREAK_TAGS = ("br", "p", "div", "tr", "li", "h1", "h2", "h3", "blockquote")

SPOOL_FAILED = os.path.join(SPOOL, "failed")
DEDUP_WINDOW = 300  # seconds
_seen_lock = threading.Lock()
_seen = {}  # dedup key -> monotonic timestamp

# ---------------------------------------------------------------------------
# Telegram Bot API
# ---------------------------------------------------------------------------


def _multipart(fields, files):
    boundary = "----mailrelay" + uuid.uuid4().hex
    out = bytearray()
    for name, value in (fields or {}).items():
        out += (
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'
            f"{value}\r\n"
        ).encode("utf-8")
    for name, (filename, content, ctype) in (files or {}).items():
        out += (
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; '
            f'filename="{filename}"\r\nContent-Type: {ctype}\r\n\r\n'
        ).encode("utf-8")
        out += content + b"\r\n"
    out += f"--{boundary}--\r\n".encode("utf-8")
    return bytes(out), f"multipart/form-data; boundary={boundary}"


def tg_call(method, fields=None, files=None):
    """Call a Bot API method. Raises RuntimeError (with .retry_after) on failure."""
    if not BOT_TOKEN:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is not set")
    if files:
        data, ctype = _multipart(fields, files)
        headers = {"Content-Type": ctype}
    else:
        data = json.dumps(fields or {}).encode("utf-8")
        headers = {"Content-Type": "application/json"}
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/{method}"
    req = urlrequest.Request(url, data=data, headers=headers, method="POST")
    try:
        with urlrequest.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
    except HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        try:
            payload = json.loads(body)
        except ValueError:
            payload = {"ok": False, "description": body}
    except URLError as exc:
        raise RuntimeError(f"network error: {exc.reason}") from exc
    if not payload.get("ok"):
        err = RuntimeError(payload.get("description", "telegram error"))
        err.retry_after = (payload.get("parameters") or {}).get("retry_after")
        raise err
    return payload


def tg_send_message(text):
    tg_call(
        "sendMessage",
        {
            "chat_id": CHAT_ID,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": True,
        },
    )


def tg_send_document(filename, content, caption):
    # No parse_mode: the caption is plain text, so any < or & in a subject is
    # sent literally instead of being rejected as a bad HTML entity.
    tg_call(
        "sendDocument",
        {"chat_id": CHAT_ID, "caption": caption[:1020]},
        {"document": (filename, content, "message/rfc822")},
    )


# ---------------------------------------------------------------------------
# Message parsing / formatting
# ---------------------------------------------------------------------------


def html_to_text(markup):
    """Very small HTML -> text converter for message bodies."""

    class Parser(HTMLParser):
        def __init__(self):
            super().__init__(convert_charrefs=True)
            self.parts = []

        def handle_data(self, data):
            self.parts.append(data)

        def handle_starttag(self, tag, attrs):
            if tag in BREAK_TAGS:
                self.parts.append("\n")

    parser = Parser()
    try:
        parser.feed(markup)
    except Exception:
        return re.sub(r"<[^>]+>", "", markup)
    return re.sub(r"\n{3,}", "\n\n", "".join(parser.parts)).strip()


def get_body_text(msg):
    if msg is None:
        return ""
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain" and part.get_content_disposition() is None:
                try:
                    return part.get_content()
                except Exception:
                    continue
        for part in msg.walk():
            if part.get_content_type() == "text/html" and part.get_content_disposition() is None:
                try:
                    return html_to_text(part.get_content())
                except Exception:
                    continue
        return ""
    try:
        content = msg.get_content()
    except Exception:
        return ""
    if msg.get_content_type() == "text/html":
        return html_to_text(content)
    return content if isinstance(content, str) else ""


def has_attachment(msg):
    if msg is None or not msg.is_multipart():
        return False
    for part in msg.walk():
        if part.get_content_disposition() in ("attachment", "inline") and part.get_filename():
            return True
    return False


def _addr(value):
    return parseaddr(value or "")[1] or (value or "").strip()


def build_text(msg, mail_from, rcpt):
    subject = ""
    if msg is not None and msg["subject"]:
        try:
            subject = str(msg["subject"])
        except Exception:
            subject = ""
    frm = _addr(msg["from"]) if (msg is not None and msg["from"]) else mail_from
    to = _addr(msg["to"]) if (msg is not None and msg["to"]) else ", ".join(rcpt)
    date = ""
    if msg is not None and msg["date"]:
        try:
            date = str(msg["date"])
        except Exception:
            date = ""
    body = get_body_text(msg).strip()
    header = f"<b>📧 {html.escape(subject or '(no subject)')}</b>"
    meta = "\n".join(
        [
            f"From: {html.escape(frm or 'unknown')}",
            f"To:   {html.escape(to or 'unknown')}",
        ]
        + ([f"Date: {html.escape(date)}"] if date else [])
    )
    return f"{header}\n{meta}\n\n{html.escape(body)}" if body else f"{header}\n{meta}"


def format_simple(msg, mail_from, rcpt):
    """Plain-text caption for the document fallback (no HTML)."""
    subject = str(msg["subject"]) if (msg is not None and msg["subject"]) else "(no subject)"
    frm = _addr(msg["from"]) if (msg is not None and msg["from"]) else mail_from
    to = _addr(msg["to"]) if (msg is not None and msg["to"]) else ", ".join(rcpt)
    return f"📧 {subject}\nFrom: {frm or 'unknown'}\nTo: {to or 'unknown'}"


# ---------------------------------------------------------------------------
# Filtering + dedup
# ---------------------------------------------------------------------------


def should_forward(mail_from, rcpt, msg, subject):
    haystack = " ".join(filter(None, [mail_from, " ".join(rcpt), subject]))
    if DENY_RE:
        try:
            if re.search(DENY_RE, haystack):
                return False
        except re.error:
            log.warning("invalid MAIL_DENY_REGEX ignored: %r", DENY_RE)
    if MODE == "local":
        return any(_addr(r).lower().endswith("@" + d) for r in rcpt for d in LOCAL_DOMAINS)
    if MODE == "allowlist":
        if not ALLOW_RE:
            return False
        try:
            return bool(re.search(ALLOW_RE, haystack))
        except re.error:
            log.warning("invalid MAIL_ALLOW_REGEX ignored: %r", ALLOW_RE)
            return False
    return True


def dedup_key(msg, raw):
    if msg is not None and msg.get("Message-ID"):
        return "mid:" + str(msg.get("Message-ID")).strip()
    return "sha:" + hashlib.sha256(raw).hexdigest()


def is_duplicate(key):
    now = time.monotonic()
    with _seen_lock:
        for k in [k for k, t in _seen.items() if now - t > DEDUP_WINDOW]:
            _seen.pop(k, None)
        if key in _seen:
            return True
        _seen[key] = now
        return False


# ---------------------------------------------------------------------------
# Spool
# ---------------------------------------------------------------------------


def spool_write(mail_from, rcpt, raw):
    os.makedirs(SPOOL, exist_ok=True)
    mid = f"{int(time.time())}-{uuid.uuid4().hex}"
    eml = os.path.join(SPOOL, mid + ".eml")
    meta = os.path.join(SPOOL, mid + ".json")
    with open(eml, "wb") as fh:
        fh.write(raw)
    with open(meta, "w", encoding="utf-8") as fh:
        json.dump({"mail_from": mail_from, "rcpt": rcpt, "attempts": 0}, fh)
    return mid


def _load_meta(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _save_meta(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def _move_failed(mid):
    os.makedirs(SPOOL_FAILED, exist_ok=True)
    for ext in (".eml", ".json"):
        src = os.path.join(SPOOL, mid + ext)
        if os.path.exists(src):
            os.replace(src, os.path.join(SPOOL_FAILED, mid + ext))


# ---------------------------------------------------------------------------
# SMTP handler
# ---------------------------------------------------------------------------


class Handler:
    async def handle_DATA(self, server, session, envelope):
        raw = envelope.content
        mail_from = envelope.mail_from or ""
        rcpt = list(envelope.rcpt_tos or [])
        try:
            msg = email.message_from_bytes(raw, policy=email.policy.default)
        except Exception:
            msg = None
        try:
            subject = str(msg["subject"]) if (msg is not None and msg["subject"]) else ""
        except Exception:
            subject = ""
        desc = f"from={mail_from} to={','.join(rcpt)} subject={subject!r}"

        if not should_forward(mail_from, rcpt, msg, subject):
            log.info("drop (filter): %s", desc)
            return "250 Message accepted (filtered)"
        key = dedup_key(msg, raw)
        if is_duplicate(key):
            log.info("drop (duplicate): %s", desc)
            return "250 Message accepted (duplicate)"
        try:
            spool_write(mail_from, rcpt, raw)
        except Exception:
            log.exception("failed to spool message")
            return "451 4.3.0 mailrelay spool error, try again"
        log.info("queued: %s", desc)
        return "250 Message accepted"


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------


def _send_one(mid, meta):
    eml = os.path.join(SPOOL, mid + ".eml")
    with open(eml, "rb") as fh:
        raw = fh.read()
    try:
        msg = email.message_from_bytes(raw, policy=email.policy.default)
    except Exception:
        msg = None
    mail_from = meta.get("mail_from", "")
    rcpt = meta.get("rcpt", []) or []
    subject = str(msg["subject"]) if (msg is not None and msg["subject"]) else "(no subject)"

    if has_attachment(msg):
        caption = format_simple(msg, mail_from, rcpt)
        caption += "\n(message with attachments — original attached)"
        tg_send_document(f"{mid}.eml", raw, caption)
    else:
        text = build_text(msg, mail_from, rcpt)
        if len(text) > TG_TEXT_LIMIT:
            tg_send_document(f"{mid}.eml", raw, format_simple(msg, mail_from, rcpt))
        else:
            tg_send_message(text)


def process_spool():
    if not (BOT_TOKEN and CHAT_ID):
        return  # not configured yet: keep spooling, don't burn attempts
    try:
        names = sorted(n for n in os.listdir(SPOOL) if n.endswith(".json"))
    except FileNotFoundError:
        return
    for name in names:
        mid = name[:-5]
        meta_path = os.path.join(SPOOL, name)
        try:
            meta = _load_meta(meta_path)
        except Exception:
            log.exception("unreadable spool metadata: %s", name)
            continue
        try:
            _send_one(mid, meta)
        except Exception as exc:
            meta["attempts"] = int(meta.get("attempts", 0)) + 1
            retry_after = getattr(exc, "retry_after", None)
            if meta["attempts"] >= MAX_ATTEMPTS:
                log.error("giving up after %s attempts: %s (%s)", meta["attempts"], mid, exc)
                _move_failed(mid)
            else:
                log.warning("send failed (attempt %s/%s) for %s: %s",
                            meta["attempts"], MAX_ATTEMPTS, mid, exc)
                _save_meta(meta_path, meta)
            if retry_after:
                time.sleep(min(float(retry_after), 60))
            else:
                time.sleep(min(2 ** min(meta["attempts"], 6), 60))
        else:
            for ext in (".eml", ".json"):
                try:
                    os.remove(os.path.join(SPOOL, mid + ext))
                except FileNotFoundError:
                    pass
            log.info("sent: %s", mid)
            time.sleep(0.5)  # gentle rate limit


def worker_loop():
    while True:
        try:
            process_spool()
        except Exception:
            log.exception("spool worker error")
        time.sleep(3)


# ---------------------------------------------------------------------------
# Health endpoint
# ---------------------------------------------------------------------------


class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip("/") != "/health":
            self.send_response(404)
            self.end_headers()
            return
        try:
            pending = len([n for n in os.listdir(SPOOL) if n.endswith(".json")])
        except FileNotFoundError:
            pending = 0
        body = json.dumps(
            {"status": "ok", "configured": bool(BOT_TOKEN and CHAT_ID), "pending": pending}
        ).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def start_health():
    server = ThreadingHTTPServer(("0.0.0.0", HEALTH_PORT), HealthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    os.makedirs(SPOOL, exist_ok=True)
    os.makedirs(SPOOL_FAILED, exist_ok=True)
    if not (BOT_TOKEN and CHAT_ID):
        log.warning(
            "TELEGRAM_BOT_TOKEN and/or TELEGRAM_CHAT_ID not set — "
            "messages will be spooled but not forwarded until they are."
        )
    start_health()
    controller = Controller(Handler(), hostname="0.0.0.0", port=25)
    controller.start()
    log.info("mailrelay listening on SMTP :25 (mode=%s, spool=%s)", MODE, SPOOL)
    worker_loop()


if __name__ == "__main__":
    main()
