#!/bin/bash
# Upgraded snapshot backup script for Hetzner Storage Box.
# Includes: database backups, getmail, config sync, and snapshot-based file backup.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Load Configuration ---
CONFIG_FILE="$SCRIPT_DIR/backups/backup.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file '$CONFIG_FILE' not found. Exiting."
    exit 1
fi

CURRENT_DATE=$(date +%Y-%m-%d)
CURRENT_DAY=$(date +%u)
IDENTITY_FILE="/home/ryan/.ssh/hetzner_backup"

# =======================================================
# PART 1: Database Backup (Weekly + Retention)
# =======================================================

IFS=' ' read -r -a DB_ARRAY <<< "$DB_NAMES"

if [ "$CURRENT_DAY" -eq "$WEEKLY_BACKUP_DAY" ]; then
    echo "--- Database Backup & Retention ---"
    echo "It's the designated weekly backup day ($CURRENT_DATE). Starting database dump..."

    for DB in "${DB_ARRAY[@]}"; do
        mysqldump -u "$MYSQL_USER" -p"$MYSQL_PASS" -h localhost "$DB" | gzip > "/var/databases/$DB-$CURRENT_DATE.sql.gz"
        if [ $? -eq 0 ]; then
            echo "   -> Dumped $DB successfully to /var/databases/$DB-$CURRENT_DATE.sql.gz"
        else
            echo "   -> ERROR: Failed to dump database $DB."
        fi
    done

    echo "Applying retention policy (Keep last 4 weekly + First backup of month)..."

    for DB in "${DB_ARRAY[@]}"; do
        echo "Processing retention for $DB..."

        ALL_BACKUPS=$(ls -1 "/var/databases/$DB"-????-??-??.sql.gz 2>/dev/null | sort)

        if [ -z "$ALL_BACKUPS" ]; then
            echo "   -> No backups found for $DB. Skipping retention."
            continue
        fi

        FILES_TO_KEEP_LAST_FOUR=$(echo "$ALL_BACKUPS" | tail -n 4)
        FILES_TO_KEEP_MONTHLY=$(echo "$ALL_BACKUPS" | grep -E "/var/databases/$DB-[0-9]{4}-[0-9]{2}-0[1-7].sql.gz")

        ALL_FILES_TO_KEEP=$(printf "%s\n%s" "$FILES_TO_KEEP_LAST_FOUR" "$FILES_TO_KEEP_MONTHLY" | sort -u)

        FULL_LIST_FILE=$(mktemp)
        KEEP_LIST_FILE=$(mktemp)

        echo "$ALL_BACKUPS" > "$FULL_LIST_FILE"
        echo "$ALL_FILES_TO_KEEP" > "$KEEP_LIST_FILE"

        FILES_TO_DELETE=$(comm -23 "$FULL_LIST_FILE" "$KEEP_LIST_FILE")

        rm -f "$FULL_LIST_FILE" "$KEEP_LIST_FILE"

        if [ -n "$FILES_TO_DELETE" ]; then
            echo "   -> Deleting old backups for $DB:"
            echo "$FILES_TO_DELETE" | while read -r FILE_TO_DELETE; do
                echo "      - DELETED: $FILE_TO_DELETE"
                rm -f "$FILE_TO_DELETE"
            done
        else
            echo "   -> No old backups needed to be deleted for $DB."
        fi
    done
else
    echo "Today is $CURRENT_DATE (Day $CURRENT_DAY). Skipping database dump and retention (Backup day is Day $WEEKLY_BACKUP_DAY)."
fi

# =======================================================
# PART 2: getmail + Config Sync
# =======================================================

echo "--- Running getmail ---"
getmail --getmaildir=/home/ryan/.getmail -r /home/ryan/.getmail/getmailrc
echo "getmail completed."

echo "Syncing /etc/nginx/..."
rsync -av /etc/nginx/ /var/www/backups/etc/nginx/
echo "Syncing /home/ryan/.getmail/..."
rsync -av /home/ryan/.getmail/ /var/www/backups/getmail/

# =======================================================
# PART 3: Snapshot File Backup to Secondary Hetzner
# =======================================================

LOCAL_SOURCE="/var/www/"
REMOTE_BASE_PATH="/home/pressabl"
NEW_SNAP="$(date +%Y-%m-%d)"

# --- Duplicate Check ---
if ssh -i "$IDENTITY_FILE" -p$SSH_PORT $HETZNER_SECONDARY_USER@$HETZNER_SECONDARY_HOST "ls -d $REMOTE_BASE_PATH/$NEW_SNAP" >/dev/null 2>&1; then
    echo "A backup for this time segment ($NEW_SNAP) has already happened. Skipping."
    exit 0
fi

# Find the most recent snapshot directory for hard-linking
PREV_SNAP=$(ssh -i "$IDENTITY_FILE" -p$SSH_PORT $HETZNER_SECONDARY_USER@$HETZNER_SECONDARY_HOST "ls -1 $REMOTE_BASE_PATH" 2>/dev/null | \
    grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" | \
    grep -v "$NEW_SNAP" | \
    sort -r | head -1)

echo "Previous snap found: $PREV_SNAP"

# Create the specific snapshot folder on the remote
echo "Creating snapshot directory $NEW_SNAP..."
ssh -i "$IDENTITY_FILE" -p$SSH_PORT $HETZNER_SECONDARY_USER@$HETZNER_SECONDARY_HOST "mkdir -p $REMOTE_BASE_PATH/$NEW_SNAP"

if [ -n "$PREV_SNAP" ]; then
    LINK_DEST_ARG="--link-dest=$REMOTE_BASE_PATH/$PREV_SNAP"
    echo "Linking against previous snapshot: $PREV_SNAP"
else
    LINK_DEST_ARG=""
    echo "No previous snapshot found. Performing full initial backup."
fi

echo "Starting backup for $LOCAL_SOURCE..."

# --- RSYNC with Optimized Flags ---
rsync -avz --delete \
    --size-only \
    --no-p --no-g --no-o \
    --omit-dir-times \
    --exclude='.Trash*' \
    --exclude='.cache' \
    --exclude='lost+found' \
    --exclude='*.log' \
    -e "ssh -i $IDENTITY_FILE -p$SSH_PORT" \
    $LINK_DEST_ARG \
    "$LOCAL_SOURCE" \
    $HETZNER_SECONDARY_USER@$HETZNER_SECONDARY_HOST:$REMOTE_BASE_PATH/$NEW_SNAP/

echo "Backup completed!"
