#!/usr/bin/env bash
# =============================================================================
# authelia-notify-code.sh — legacy shim; Authelia notifications now go to
# Telegram via the mailrelay container (EMAILS.md).
#
#   sudo bash scripts/authelia-notify-code.sh
#
# BACKGROUND: Authelia used to use its FILESYSTEM notifier, writing the
# TOTP-registration / password-reset "email" to
# ~/www/auth.hellyer.kiwi/notification.txt, and this script printed it. Authelia
# now uses the SMTP notifier pointed at `mailrelay`, so those messages arrive in
# the Telegram chat instead — there is nothing to read here any more.
#
# This script is kept so existing docs/automation that call it don't break. If a
# legacy notification.txt still exists (a box mid-migration), it is printed.
# Otherwise it just points you at Telegram.
#
# Usage: sudo bash scripts/authelia-notify-code.sh [--json]
#        (--json is accepted for backwards compatibility and ignored)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-paths.sh

WWW_ROOT="$(resolve_www_root)"
FILE="$WWW_ROOT/auth.hellyer.kiwi/notification.txt"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }

case "${1:-}" in
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  --json|"") ;;
  *) warn "Unknown option: $1"; exit 1 ;;
esac

if [ -s "$FILE" ]; then
  warn "Found a LEGACY Authelia notification file at $FILE"
  echo "----------------------------------------------------------------------"
  cat "$FILE"
  echo "----------------------------------------------------------------------"
  echo
  say "This is from the old filesystem notifier. New notifications go to Telegram."
  echo
  echo "Links / codes found (newest last):"
  grep -oE 'https?://[^"[:space:]<>]+' "$FILE" | sort -u | while read -r url; do
    printf '  %s\n' "$url"
  done || true
  exit 0
fi

say "Authelia notifications now arrive in Telegram"
cat <<'EOF'

  Authelia's notifier is SMTP -> the `mailrelay` container -> your Telegram
  chat (see EMAILS.md). When you click "Register device" (or "Reset password")
  in the portal, read the message in Telegram instead of on the server.

  If it does not arrive, check the relay:
    pod-logs mailrelay -f
    sudo bash scripts/provision-mail.sh          # validates config + test
EOF
