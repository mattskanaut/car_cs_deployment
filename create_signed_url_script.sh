az storage blob generate-sas \
    --account-name qualyscontainersensor \
    --container-name scripts \
    --name car_install_qualys_container_sensor_multi_windows.ps1 \
    --permissions r \
    --expiry 2025-07-05T23:59:00Z \
    --https-only \
    --output tsv

https://qualyscontainersensor.blob.core.windows.net/scripts/car_install_qualys_container_sensor_multi_windows.ps1?se=2025-07-05T23%3A59%3A00Z&sp=r&spr=https&sv=2022-11-02&sr=b&sig=Ip3p1zA%2BNRBeEuLHHcemOWh9sZdJglWv610Sh29zrro%3D