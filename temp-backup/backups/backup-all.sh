#!/bin/bash
# Main backup script that orchestrates database and file backups.
# Runs backup-db.sh first, then backup-files.sh sequentially.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =======================================================
# PART 1: Database Backup
# =======================================================

echo "--- Calling Database Backup and Retention Script ---"

# Call the database backup script. It loads the config itself.
"$SCRIPT_DIR/backup-db.sh"

# =======================================================
# PART 2: File Backup
# =======================================================

echo -e "\n--- Calling File Backup Script ---"

# Call the file backup script. It loads the config itself.
"$SCRIPT_DIR/backup-files.sh"

echo -e "\nAll backup tasks completed successfully."
