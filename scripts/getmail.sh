#!/usr/bin/env bash
# =============================================================================
# getmail.sh — fetch Gmail (IMAP) into the Maildir at ~/gmail using getmail6.
#
#   sudo bash scripts/getmail.sh                 # write config + fetch
#   sudo bash scripts/getmail.sh --config-only   # just (re)write the getmailrc
#
# Config (from .env):
#   GMAIL_USER          Gmail address (default: ryanhellyer@gmail.com)
#   GMAIL_APP_PASSWORD  Google app password (required)
#   GMAIL_MAILDIR       Maildir to deliver into (default: the admin user's ~/gmail)
#   GMAIL_MAILBOXES     optional "|"-separated IMAP mailbox list
#                       (default: the legacy list — see DEFAULT_MAILBOXES)
#
# Scheduled daily by scripts/install-systemd.sh (server-getmail.timer).
#
# The getmailrc is written to the admin user's ~/.getmail/ (mode 600) and the
# fetch runs AS THE ADMIN USER, so delivered Maildir files are owned by them
# (not root). ~/gmail is usually the sshfs mount of the storage box's
# /home/gmail share (see scripts/storage-mounts.sh); a local dir works too.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && set -a && source .env && set +a
source scripts/lib-paths.sh

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[xx]\033[0m %s\n' "$*" >&2; exit 1; }

CONFIG_ONLY=0
case "${1:-}" in
  --config-only) CONFIG_ONLY=1 ;;
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) die "Unknown option: $1" ;;
esac

ADMIN_USER="$(resolve_admin_user)"
ADMIN_HOME="$(resolve_admin_home)"
ADMIN_GROUP="$(id -gn "$ADMIN_USER" 2>/dev/null || id -gn)"

GMAIL_USER="${GMAIL_USER:-ryanhellyer@gmail.com}"
GMAIL_APP_PASSWORD="${GMAIL_APP_PASSWORD:-}"
GMAIL_MAILDIR="${GMAIL_MAILDIR:-$ADMIN_HOME/gmail}"
GETMAIL_DIR="${GETMAIL_DIR:-$ADMIN_HOME/.getmail}"
GETMAILRC="$GETMAIL_DIR/getmailrc"

# Google app passwords are 16 chars, but are often pasted in the spaced form
# ("xxxx xxxx xxxx xxxx"); strip whitespace (Google ignores the spaces) and
# require alphanumeric so the rendered getmailrc can't be corrupted.
GMAIL_APP_PASSWORD="$(printf '%s' "$GMAIL_APP_PASSWORD" | tr -d '[:space:]')"
if [ -z "$GMAIL_APP_PASSWORD" ]; then
  # Not configured on this server (yet) — that's a no-op, not an error, so a
  # fresh install without Gmail doesn't fail the daily timer every night.
  warn "GMAIL_APP_PASSWORD is not set in .env — skipping Gmail fetch."
  warn "Create one at https://myaccount.google.com/apppasswords, set it in .env, then re-run."
  exit 0
fi
case "$GMAIL_APP_PASSWORD" in
  *[!A-Za-z0-9]*) die "GMAIL_APP_PASSWORD must be alphanumeric (a Google app password)." ;;
esac

# ---- mailboxes (legacy list by default) -------------------------------------
DEFAULT_MAILBOXES=(
  "Inbox"
  "[Gmail]/Sent Mail"
  "Contact form"
  "Financial"
  "Insurance"
  "Landlord"
  "Medical"
  "Payments"
  "Pension"
  "Postal mail"
  "Potentially tax relevant"
)
if [ -n "${GMAIL_MAILBOXES:-}" ]; then
  IFS='|' read -r -a MAILBOXES <<< "$GMAIL_MAILBOXES"
else
  MAILBOXES=("${DEFAULT_MAILBOXES[@]}")
fi
mb=""
for m in "${MAILBOXES[@]}"; do mb+="\"$m\", "; done
mb="${mb%, }"    # "A", "B"  (or a single "A")
mb="${mb},"      # trailing comma so a single entry is still a Python tuple

# ---- Maildir + getmail dir --------------------------------------------------
if [ ! -d "$GMAIL_MAILDIR" ]; then
  say "Creating Maildir: $GMAIL_MAILDIR"
  install -d -m 775 -o "$ADMIN_USER" -g "$ADMIN_GROUP" \
    "$GMAIL_MAILDIR" "$GMAIL_MAILDIR/cur" "$GMAIL_MAILDIR/new" "$GMAIL_MAILDIR/tmp"
else
  for sub in cur new tmp; do
    [ -d "$GMAIL_MAILDIR/$sub" ] || install -d -m 775 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$GMAIL_MAILDIR/$sub"
  done
fi

say "Writing $GETMAILRC"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$GETMAIL_DIR"
umask 077
cat > "$GETMAILRC" <<EOF
[retriever]
type = SimpleIMAPSSLRetriever
server = imap.gmail.com
username = $GMAIL_USER
password = $GMAIL_APP_PASSWORD
mailboxes = ($mb)

[destination]
type = Maildir
path = $GMAIL_MAILDIR/

[options]
read_all = false
EOF
chown "$ADMIN_USER:$ADMIN_GROUP" "$GETMAILRC"
chmod 600 "$GETMAILRC"

if [ "$CONFIG_ONLY" = 1 ]; then
  say "Config written (no fetch requested)."
  exit 0
fi

command -v getmail >/dev/null 2>&1 \
  || die "getmail is not installed (apt-get install -y getmail6)."

say "Fetching mail into $GMAIL_MAILDIR as $ADMIN_USER"
if [ "$(id -un)" = "$ADMIN_USER" ]; then
  getmail --getmaildir="$GETMAIL_DIR" -r "$GETMAILRC"
else
  runuser -u "$ADMIN_USER" -- env HOME="$ADMIN_HOME" \
    getmail --getmaildir="$GETMAIL_DIR" -r "$GETMAILRC"
fi
say "Done."
