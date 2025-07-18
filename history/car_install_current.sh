#!/bin/bash

# Exit on undefined variables and errors
set -eu

# ==============================
# Configuration Section
# ==============================

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
LOCATION="https://mycheapstorageacct123.blob.core.windows.net/qualys/QualysContainerSensor.tar.xz?se=2025-01-12T23%3A59%3A00Z&sp=r&spr=https&sv=2022-11-02&sr=b&skoid=290aff92-1a5d-40c1-9399-718b87183209&sktid=3f1e121d-d46f-4099-87e3-5ad85cc16607&skt=2025-01-09T15%3A01%3A56Z&ske=2025-01-12T23%3A59%3A00Z&sks=b&skv=2022-11-02&sig=9ugtTDAX66r9eB4fBH3ti8shtE0Qr9wttVxMdLLhYYE%3D"
#LOCATION="dockerhub"

# ACTIVATIONID: Your Qualys ActivationID (replace with your actual ID).
ACTIVATIONID="f70e5b6a-0cb3-4a24-9994-843c5d40f028"

# CUSTOMERID: Your Qualys CustomerID (replace with your actual ID).
CUSTOMERID="dc965ac5-375a-dd6a-834d-788f666fad44"

# POD_URL: POD URL required for Dockerhub installation (replace with your actual URL).
POD_URL="https://cmsqagpublic.qg1.apps.qualys.co.uk/ContainerSensor"

# Install options to pass to installsensor.sh or docker run cmd, space separated list
INSTALL_OPTIONS="--registry-sensor --perform-sca-scan --perform-malware-detection"

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

# Check if Docker is installed
if ! which docker &> /dev/null; then
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
  echo "Checking if the URL is valid and accessible..."

  # Test the URL using a HEAD request
  HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}" -I "$LOCATION")

  if [ "$HTTP_STATUS" -eq 200 ]; then
    echo "URL is valid. Proceeding with download..."
  elif [ "$HTTP_STATUS" -eq 403 ]; then
    echo "Error: URL is expired or invalid. Exiting."
    exit 11
  elif [ "$HTTP_STATUS" -eq 404 ]; then
    echo "Error: Resource not found. Exiting."
    exit 12
  else
    echo "Unexpected error (HTTP status $HTTP_STATUS). Exiting."
    exit 13
  fi

  echo "Downloading tar.xz file from $LOCATION..."
  curl -o QualysContainerSensor.tar.xz "$LOCATION"

  if [ $? -ne 0 ]; then
    echo "Error: Failed to download the tar.xz file. Exiting."
    exit 14
  fi

  echo "Extracting tar.xz file..."
  if sudo tar -xvf QualysContainerSensor.tar.xz; then
    echo "Extraction successful."
  else
    echo "Error: Failed to extract the tar.xz file. Exiting."
    exit 15
  fi

  echo "Setting up Qualys directories..."
  sudo mkdir -p /usr/local/qualys/sensor/data

  echo "Running sensor installation script..."
  if sudo ./installsensor.sh ActivationId="$ACTIVATIONID" \
      CustomerId="$CUSTOMERID" Storage=/usr/local/qualys/sensor/data -s $INSTALL_OPTIONS ; then
    echo "Sensor installation completed successfully."
  else
    echo "Error: Sensor installation failed. Exiting."
    exit 16
  fi
}

# Function to handle installation from Dockerhub
install_from_dockerhub() {
  # Ensure required variables are set
  if [[ -z "$POD_URL" ]]; then
    echo "Error: POD_URL must be set when using Dockerhub."
    exit 21
  fi

  if [[ -z "$ACTIVATIONID" ]]; then
    echo "Error: ACTIVATIONID must be set."
    exit 22
  fi

  if [[ -z "$CUSTOMERID" ]]; then
    echo "Error: CUSTOMERID must be set."
    exit 23
  fi

  echo "Installing from Dockerhub..."

  # Run Docker container
  CONTAINER_ID=$(sudo docker run -d --restart on-failure \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v /etc/qualys:/usr/local/qualys/qpa/data/conf/agent-data \
    -v /usr/local/qualys/sensor/data:/usr/local/qualys/qpa/data \
    -e ACTIVATIONID="$ACTIVATIONID" \
    -e CUSTOMERID="$CUSTOMERID" \
    -e POD_URL="$POD_URL" \
    --net=host --name qualys-container-sensor qualys/qcs-sensor:latest \
    $INSTALL_OPTIONS 2>&1)

  # Check if the docker run command succeeded
  if [[ $? -ne 0 ]]; then
    echo "Error: Failed to start the Qualys container. Docker error:"
    echo "$CONTAINER_ID"
    exit 24
  fi

  echo "Container started with ID: $CONTAINER_ID"

  # Validate that the container is running
  RUNNING_STATUS=$(sudo docker inspect -f '{{.State.Running}}' qualys-container-sensor 2>/dev/null)
  if [[ "$RUNNING_STATUS" != "true" ]]; then
    echo "Error: Container did not start successfully."
    echo "Check the container logs for details:"
    sudo docker logs qualys-container-sensor
    exit 25
  fi

  echo "Qualys container sensor installed and running successfully."
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
