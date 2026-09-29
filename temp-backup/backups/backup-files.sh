#!/bin/bash
# This script handles file backups: getmail, config sync, and rsync to Hetzner.
# Can be run independently or called from backup.sh
# Usage: ./backup-files.sh

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Load Configuration ---
# Source the configuration file. This must be present in the same directory.
CONFIG_FILE="$SCRIPT_DIR/backup.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file '$CONFIG_FILE' not found. Exiting."
    exit 1
fi

# =======================================================
# File Backup Operations
# =======================================================

echo "--- Running File Backup Tasks (getmail, config sync, and rsync to Hetzner) ---"

# Download from Gmail
# Use explicit path to getmailrc to avoid path issues
# Specify --getmaildir to avoid error when run from cron (minimal environment)
getmail --getmaildir=/home/ryan/.getmail -r /home/ryan/.getmail/getmailrc
echo "getmail completed."

# Configs
echo "Syncing /etc/nginx/..."
rsync -av /etc/nginx/ /var/www/backups/etc/nginx/
echo "Syncing /home/ryan/.getmail/..."
rsync -av /home/ryan/.getmail/ /var/www/backups/getmail/

# Backing up to Hetzner
echo "Starting rsync to Hetzner Storage Box..."
rsync --progress -e "ssh -p$SSH_PORT" \
    --ignore-existing \
    --recursive \
    --exclude="$RSYNC_EXCLUDE" \
    /var/www/ "$HETZNER_USER"@"$HETZNER_HOST":"$HETZNER_PATH"

echo "File backup tasks completed successfully."

# End of backup-files.sh
