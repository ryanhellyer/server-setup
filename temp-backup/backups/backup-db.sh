#!/bin/bash
# This script handles the weekly database dump and the specific retention policy.
# Can be run independently or called from backup.sh
# Usage: ./backup-db.sh [--force]  (--force bypasses weekly day check)

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Check for force flag ---
FORCE_BACKUP=false
if [ "$1" = "--force" ] || [ "$1" = "-f" ]; then
    FORCE_BACKUP=true
    echo "Force mode enabled: Will perform backup regardless of day of week."
fi

# --- Load Configuration ---
# Source the configuration file. This must be present in the same directory.
CONFIG_FILE="$SCRIPT_DIR/backup.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Configuration file '$CONFIG_FILE' not found. Exiting."
    exit 1
fi

# --- Internal Date Variables ---
CURRENT_DATE=$(date +%Y-%m-%d)
CURRENT_DAY=$(date +%u) # %u: Day of week (1..7); 1 is Monday

# Convert DB_NAMES string to an array for iteration
IFS=' ' read -r -a DB_ARRAY <<< "$DB_NAMES"

# Should throw error here if /var/databases does not exist.

# =======================================================
# Database Backup (Weekly Check and Retention)
# =======================================================

if [ "$FORCE_BACKUP" = true ] || [ "$CURRENT_DAY" -eq "$WEEKLY_BACKUP_DAY" ]; then
    echo "--- Database Backup & Retention ---"
    if [ "$FORCE_BACKUP" = true ]; then
        echo "Force mode: Performing database backup on $CURRENT_DATE (Day $CURRENT_DAY)..."
    else
        echo "It's the designated weekly backup day ($CURRENT_DATE). Starting database dump..."
    fi

    # 1. Perform weekly database dumps
    for DB in "${DB_ARRAY[@]}"; do
        # Dump databases
        mysqldump -u "$MYSQL_USER" -p"$MYSQL_PASS" -h localhost "$DB" | gzip > "/var/databases/$DB-$CURRENT_DATE.sql.gz"
        if [ $? -eq 0 ]; then
            echo "   -> Dumped $DB successfully to /var/databases/$DB-$CURRENT_DATE.sql.gz"
        else
            echo "   -> ERROR: Failed to dump database $DB."
        fi
    done
    
    # 2. Apply the retention policy
    echo "Applying retention policy (Keep last 4 weekly + First backup of month)..."

    for DB in "${DB_ARRAY[@]}"; do
        echo "Processing retention for $DB..."

        # List all backups for this DB, sorted by date (oldest first)
        ALL_BACKUPS=$(ls -1 "/var/databases/$DB"-????-??-??.sql.gz 2>/dev/null | sort)
        
        if [ -z "$ALL_BACKUPS" ]; then
            echo "   -> No backups found for $DB. Skipping retention."
            continue
        fi

        # a) Identify the 4 most recent files to KEEP.
        FILES_TO_KEEP_LAST_FOUR=$(echo "$ALL_BACKUPS" | tail -n 4)
        
        # b) Identify files that are the "first of the month" (day 01-07) to KEEP as an exception.
        FILES_TO_KEEP_MONTHLY=$(echo "$ALL_BACKUPS" | grep -E "/var/databases/$DB-[0-9]{4}-[0-9]{2}-0[1-7].sql.gz")
        
        # c) Combine both lists and get a unique set of files to keep
        ALL_FILES_TO_KEEP=$(printf "%s\n%s" "$FILES_TO_KEEP_LAST_FOUR" "$FILES_TO_KEEP_MONTHLY" | sort -u)

        # d) Determine files to DELETE (all files NOT in the "to keep" list)
        FULL_LIST_FILE=$(mktemp)
        KEEP_LIST_FILE=$(mktemp)
        
        echo "$ALL_BACKUPS" > "$FULL_LIST_FILE"
        echo "$ALL_FILES_TO_KEEP" > "$KEEP_LIST_FILE"
        
        FILES_TO_DELETE=$(comm -23 "$FULL_LIST_FILE" "$KEEP_LIST_FILE")
        
        rm -f "$FULL_LIST_FILE" "$KEEP_LIST_FILE"

        # e) Execute deletion
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
    echo "To force a backup, run: ./backup-db.sh --force"
fi

# End of backup-db.sh
