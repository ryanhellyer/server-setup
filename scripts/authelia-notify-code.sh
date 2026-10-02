#!/usr/bin/env bash
# =============================================================================
# authelia-notify-code.sh — show the latest Authelia notification (used as the
# "email" during TOTP device registration on boxes with no mail server).
#
#   sudo bash scripts/authelia-notify-code.sh          # print + extract links
#   sudo bash scripts/authelia-notify-code.sh --json   # raw machinery output
#
# Authelia is configured with the FILESYSTEM notifier (authelia/configuration.yml
# → notifier.filesystem.filename = /data/notification.txt, host:
# ~/www/auth.hellyer.kiwi/notification.txt). When you click "Register device"
# for a second factor, Authelia would normally email you a confirmation link;
# instead it writes that email to this file. Read it, open the link in a
# browser, then the QR code is shown.
#
# Read-only: it never modifies the notification file.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-paths.sh

WWW_ROOT="$(resolve_www_root)"
FILE="$WWW_ROOT/auth.hellyer.kiwi/notification.txt"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$FILE" ] || die "No notification file yet at $FILE.
     Click 'Register device' in the Authelia portal first, then re-run this."

if [ ! -s "$FILE" ]; then
  warn "The notification file is empty."
  echo "     Click 'Register device' (or 'Reset password') in the portal, then re-run."
  exit 0
fi

say "Latest AUTHELIA notification ($FILE)"
echo "----------------------------------------------------------------------"
cat "$FILE"
echo "----------------------------------------------------------------------"
echo
say "Links / codes found (newest last):"
grep -oE 'https?://[^"[:space:]<>]+' "$FILE" | sort -u | while read -r url; do
  printf '  %s\n' "$url"
done || true
echo
echo "Open the confirmation link in a browser, then scan the QR code into your"
echo "authenticator app (scan into a SECOND app too, as a backup)."
