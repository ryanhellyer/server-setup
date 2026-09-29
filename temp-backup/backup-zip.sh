# Set variables for the backup file only
DATE=$(date +%Y-%m-%d)
BACKUP_FILE="pressabl-${DATE}.tar.gz"
TEMP_PATH="/tmp/${BACKUP_FILE}"

# Create the tar.gz archive
echo "Creating backup archive ${BACKUP_FILE}..."
tar -czf "${TEMP_PATH}" /var/www

# Check if archive was created successfully
if [ $? -eq 0 ]; then
    echo "Archive created successfully at ${TEMP_PATH}"
    
    # Transfer the archive using rsync with hardcoded connection details
    echo "Transferring archive to remote server..."
    rsync --progress -e "ssh -p23" "${TEMP_PATH}" u458814@u458814.your-storagebox.de:/home/backups/
    
    # Check if transfer was successful
    if [ $? -eq 0 ]; then
        echo "Transfer completed successfully."
    else
        echo "Error: Transfer failed."
        exit 1
    fi
    
    # Clean up the temporary file
    echo "Cleaning up local archive..."
    rm "${TEMP_PATH}"
    echo "Backup process completed."
else
    echo "Error: Failed to create archive."
    exit 1
fi
