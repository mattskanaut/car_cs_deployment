#!/bin/bash

# Exit on undefined variables and errors
set -eu

# ==============================
# Configuration Section
# ==============================
# Set these variables before running the script

# LOCATION: Path to the tar.xz file downloaded from the Qualys UI. This is the
# best option, as it will install a self updating sensor. The tar.xz file 
# must be stored somewhere reachable from the target host. A signed URL
# should be used so that this script runs without credentials or the need
# for cloud CLIs. 
# For example for S3 use a URL of the form: 
# 	"s3://my-bucket/path/to/QualysContainerSensor.tar.xz"
# Notes on Signed URLs:
#   - For cloud storage (S3, Azure Blob, GCS, OCI), signed URLs provide temporary,
#     pre-authenticated access to files.
#   - Signed URLs respect bucket-level restrictions such as limiting access to specific
#     VPCs or networks.
#   - Ensure your client has network access to the storage location (e.g., via a VPC
#     endpoint or equivalent).
#
# Alteratively, you can pull the sensor image from docker hub, although in this case
# the sensor will NOT self update.
LOCATION=<#Location#>

# ACTIVATIONID: Your Qualys ActivationID (replace with your actual ID).
ACTIVATIONID=<#ActivationID#>

# CUSTOMERID: Your Qualys CustomerID (replace with your actual ID).
CUSTOMERID=<#CustomerID#>

# POD_URL: POD URL required for Dockerhub installation (replace with your actual URL).
POD_URL="https://cmsqagpublic.qg1.apps.qualys.co.uk/ContainerSensor"

# ==============================
# Script starts here
# ==============================

# Function to print help
print_help() {
  echo "This script installs the Qualys Docker Sensor."
  echo
  echo "Usage: Edit the variables in the 'Configuration Section' of this script:"
  echo "  - LOCATION: Path to tar.xz file or 'dockerhub' for Dockerhub"
  echo "    Example: LOCATION='s3://my-bucket/path/to/QualysContainerSensor.tar.xz'"
  echo "  - ACTIVATIONID: Your Qualys ActivationID"
  echo "  - CUSTOMERID: Your Qualys CustomerID"
  echo "  - POD_URL: POD URL (required for Dockerhub only)"
  echo
}

# Validate mandatory variables
if [[ -z "$LOCATION" || -z "$ACTIVATIONID" || -z "$CUSTOMERID" ]]; then
  echo "Error: LOCATION, ACTIVATIONID, and CUSTOMERID must be set in the script."
  print_help
  exit 1
fi

# Check if Docker is installed and running
if ! command -v docker &> /dev/null; then
  echo "Error: Docker is not installed."
  exit 2
fi

if ! docker info &> /dev/null; then
  echo "Error: Docker is not running or you lack permissions to manage Docker."
  exit 3
fi

# Check if any container using the qualys/qcs-sensor image is running
if docker ps --filter "ancestor=qualys/qcs-sensor" \
    --format '{{.Image}}' | grep -q "qualys/qcs-sensor"; then
  echo "Error: A container built from the image 'qualys/qcs-sensor' is already running."
  exit 4
fi

# Function to handle installation from tar.xz
install_from_tar() {
  echo "Downloading tar.xz file from $LOCATION..."
  curl -o QualysContainerSensor.tar.xz "$LOCATION"

  echo "Extracting tar.xz file..."
  sudo tar -xvf QualysContainerSensor.tar.xz
  sudo mkdir -p /usr/local/qualys/sensor/data
  sudo ./installsensor.sh ActivationId="$ACTIVATIONID" \
      CustomerId="$CUSTOMERID" Storage=/usr/local/qualys/sensor/data -s
}

# Function to handle installation from Dockerhub
install_from_dockerhub() {
  if [[ -z "$POD_URL" ]]; then
    echo "Error: POD_URL must be set when using Dockerhub."
    exit 5
  fi

  echo "Installing from Dockerhub..."
  sudo docker run -d --restart on-failure \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v /etc/qualys:/usr/local/qualys/qpa/data/conf/agent-data \
    -v /usr/local/qualys/sensor/data:/usr/local/qualys/qpa/data \
    -e ACTIVATIONID="$ACTIVATIONID" \
    -e CUSTOMERID="$CUSTOMERID" \
    -e POD_URL="$POD_URL" \
    --net=host --name qualys-container-sensor qualys/qcs-sensor:latest
}

# Main logic
case "$LOCATION" in
  dockerhub)
    install_from_dockerhub
    ;;
  *)
    install_from_tar
    ;;
esac

echo "Installation completed successfully."
exit 0
