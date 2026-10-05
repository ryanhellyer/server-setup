#!/usr/bin/env bash
# =============================================================================
# provision-mail.sh — validate the Telegram settings and (re)start the
# `mailrelay` container, then send a test message through the whole chain.
#
#   sudo bash scripts/provision-mail.sh [--dry-run] [--no-test]
#
# `mailrelay` is the catch-all SMTP sink that forwards every message to
# Telegram (EMAILS.md). It needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in
# .env; when they are absent this script is a no-op (so a deploy without
# Telegram configured still succeeds).
#
# What it does:
#   1. reads TELEGRAM_* from .env (skips with a warning if unset);
#   2. validates the bot token with getMe;
#   3. builds + starts the mailrelay service (`podman compose up -d --build`);
#   4. waits for it to accept SMTP, then sends a test email to the relay and
#      reports whether it reached Telegram.
#
# Re-running is safe (idempotent). Run from anywhere.
#
# Config: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, MAIL_FROM_ADDRESS (.env).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-containers.sh
source scripts/lib-env.sh

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

DRY=0; DO_TEST=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --no-test) DO_TEST=0; shift ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
run() { if [ "$DRY" = 1 ]; then printf '    DRY: %s\n' "$*"; else "$@"; fi; }

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
FROM_ADDR="${MAIL_FROM_ADDRESS:-server@hellyer.kiwi}"

if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
  warn "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID are not set in .env — skipping."
  warn "Create a bot with @BotFather, put both values in .env, then re-run:"
  warn "  sudo bash scripts/provision-mail.sh"
  exit 0
fi

# ---- 1. validate the bot token ---------------------------------------------
say "Validating the Telegram bot token (getMe)"
BOT_JSON="$(curl -fsS "https://api.telegram.org/bot${TOKEN}/getMe" 2>/dev/null || true)"
if [ -z "$BOT_JSON" ]; then
  die "Could not reach api.telegram.org with the token (network or token problem)."
fi
BOT_OK="$(printf '%s' "$BOT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok", False))' 2>/dev/null || echo False)"
if [ "$BOT_OK" != "True" ]; then
  die "Telegram rejected the token: $BOT_JSON"
fi
BOT_NAME="$(printf '%s' "$BOT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"].get("username",""))' 2>/dev/null || true)"
ok "bot @${BOT_NAME:-?} is valid; chat id ${CHAT_ID}"

# ---- 2. build + start the relay --------------------------------------------
if podman compose version >/dev/null 2>&1; then
  COMPOSE=(podman compose)
else
  COMPOSE=(podman-compose)
fi

say "Starting the mailrelay service"
run "${COMPOSE[@]}" up -d --build "$CONTAINER_MAILRELAY"

if [ "$DRY" = 1 ]; then
  say "dry-run: skipping the SMTP smoke test."
  exit 0
fi

# ---- 3. wait for the container to accept SMTP ------------------------------
say "Waiting for ${CONTAINER_MAILRELAY} to accept SMTP on 127.0.0.1:2525"
ready=0
for _ in $(seq 1 30); do
  if python3 - <<'PY' >/dev/null 2>&1
import smtplib
s = smtplib.SMTP("127.0.0.1", 2525, timeout=3)
s.ehlo(); s.quit()
PY
  then ready=1; break; fi
  sleep 2
done
if [ "$ready" != 1 ]; then
  warn "mailrelay did not accept SMTP after 60s."
  warn "Inspect it with: pod-logs mailrelay"
  exit 1
fi
ok "SMTP relay is up"

# ---- 4. smoke test through the full chain ----------------------------------
if [ "$DO_TEST" = 1 ]; then
  say "Sending a test message through the relay (check Telegram)"
  if python3 - <<PY
import smtplib
from email.message import EmailMessage
msg = EmailMessage()
msg["From"] = "$FROM_ADDR"
msg["To"] = "admin@hellyer.kiwi"
msg["Subject"] = "mailrelay test"
msg.set_content("If you can read this in Telegram, server mail is wired up correctly.")
with smtplib.SMTP("127.0.0.1", 2525, timeout=15) as s:
    s.send_message(msg)
PY
  then
    ok "Test message accepted by the relay — it should appear in Telegram shortly."
    warn "If it does not arrive, check: pod-logs mailrelay -f"
  else
    warn "Could not hand the test message to the relay."
    exit 1
  fi
fi
