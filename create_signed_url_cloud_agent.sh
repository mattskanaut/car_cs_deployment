az storage blob generate-sas \
    --account-name qualyscontainersensor \
    --container-name qualyscloudagentinstaller \
    --name QualysCloudAgent.rpm \
    --permissions r \
    --expiry 2025-06-30T23:59:00Z \
    --output tsv



https://qualyscontainersensor.blob.core.windows.net/qualyscloudagentinstaller/QualysCloudAgent.rpm?se=2025-07-30T23%3A59%3A00Z&sp=r&sv=2022-11-02&sr=b&sig=YMDpeOZLQhSjDvRK9GsAMZg3S1LXG97TCOOiMxV%2BZrg%3D


