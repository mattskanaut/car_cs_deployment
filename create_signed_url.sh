az storage blob generate-sas \
    --account-name qualyscontainersensor \
    --container-name qualyssensorinstaller \
    --name QualysContainerSensor.tar.xz \
    --permissions r \
    --expiry 2025-06-20T23:59:00Z \
    --https-only \
    --output tsv