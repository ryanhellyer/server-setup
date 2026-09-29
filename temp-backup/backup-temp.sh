#!/bin/bash

# Variables for your setup
HETZNER_USER="u513410"
HETZNER_HOST="u513410.your-storagebox.de"
HETZNER_PORT="23"

# Local sources to backup
LOCAL_SOURCES=(
    "/home/ryan/Documents/"
    "/home/ryan/Pictures/"
    "/var/www/"
)

# Remote destination names (subdirectories within snapshot)
REMOTE_NAMES=(
    "Documents"
    "Pictures"
    "www"
)

# The Hetzner storage path is /home/. We will create a base directory for these backups there.
REMOTE_BASE_PATH="/home/laptop"

# Create a unique, date-stamped name for the new snapshot
NEW_SNAP="$(date +%Y-%m-%d)"

# Find the most recent snapshot to use as link-dest reference
# This works around SFTP-only limitation where symlinks can't be created
PREV_SNAP=$(rsync -avz -e "ssh -p$HETZNER_PORT" --list-only $HETZNER_USER@$HETZNER_HOST:$REMOTE_BASE_PATH/ 2>/dev/null | \
    grep "^d.*" | awk '{print $NF}' | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}" | sort -r | head -1)

# Create the snapshot directory on the remote server first
echo "Creating snapshot directory $NEW_SNAP..."
ssh -p$HETZNER_PORT $HETZNER_USER@$HETZNER_HOST "mkdir -p $REMOTE_BASE_PATH/$NEW_SNAP"

# Backup each directory
for i in "${!LOCAL_SOURCES[@]}"; do
    LOCAL_SOURCE="${LOCAL_SOURCES[$i]}"
    REMOTE_NAME="${REMOTE_NAMES[$i]}"
    
    # Use the previous snapshot as link-dest if one exists
    if [ -n "$PREV_SNAP" ]; then
        LINK_DEST_ARG="--link-dest=$REMOTE_BASE_PATH/$PREV_SNAP/$REMOTE_NAME"
    else
        LINK_DEST_ARG=""
    fi
    
    echo "Backing up $LOCAL_SOURCE to $REMOTE_NAME..."
    
    # Perform the backup with hard linking to previous snapshot
    rsync -avz --delete \
        -e "ssh -p$HETZNER_PORT" \
        $LINK_DEST_ARG \
        $LOCAL_SOURCE \
        $HETZNER_USER@$HETZNER_HOST:$REMOTE_BASE_PATH/$NEW_SNAP/$REMOTE_NAME/
done

echo "Backup completed!"
