az storage blob generate-sas \
    --account-name mycheapstorageacct123 \
    --container-name qualys \
    --name QualysContainerSensor.tar.xz \
    --permissions r \
    --expiry 2024-12-12T23:59:00Z \
    --https-only \
    --auth-mode login \
    --as-user \
    --output tsv

https://mystorageaccount.blob.core.windows.net/qualys/QualysContainerSensor.tar.xz?sv=2022-11-02&sr=b&sig=8ANczH9L7smM3rS1GWQbDFUlhonetEaqkC6%2B8%2Bdhj1w%3D
