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
# Alternatively, you can pull the sensor image from docker hub, although in this case
# the sensor will NOT self update.

LOCATION="https://carqcs.blob.core.windows.net/qualys/QualysContainerSensor.tar.xz?se=2025-01-28T23%3A59%3A00Z&sp=r&spr=https&sv=2022-11-02&sr=b&skoid=290aff92-1a5d-40c1-9399-718b87183209&sktid=3f1e121d-d46f-4099-87e3-5ad85cc16607&skt=2025-01-22T13%3A39%3A34Z&ske=2025-01-28T23%3A59%3A00Z&sks=b&skv=2022-11-02&sig=1Oe7lX8jimVCl48AUwRxFwi%2BayM31kqI%2FlrvbJ1BAg0%3D"
#LOCATION="dockerhub"

ACTIVATIONID="f70e5b6a-0cb3-4a24-9994-843c5d40f028"

CUSTOMERID="dc965ac5-375a-dd6a-834d-788f666fad44"

# Required for docker hub
POD_URL=""
#POD_URL="https://cmsqagpublic.qg1.apps.qualys.co.uk/ContainerSensor"

# Add any install script options here
INSTALL_OPTIONS=""
#INSTALL_OPTIONS="--registry-sensor --perform-sca-scan --perform-malware-detection"

# Force a reinstall if existing sensor found
FORCE_REINSTALL=true

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

info() {
  while IFS= read -r line; do
    echo "[INFO] $line"
  done <<< "$1"
}

error() {
  while IFS= read -r line; do
    echo "[ERROR] $line"
  done <<< "$1"
}

# Validate mandatory variables
if [[ ! -v LOCATION || -z "$LOCATION" || \
      ! -v ACTIVATIONID || -z "$ACTIVATIONID" || \
      ! -v CUSTOMERID || -z "$CUSTOMERID" ]]; then
  error "LOCATION, ACTIVATIONID, and CUSTOMERID must be set and not empty in the script."
  print_help
  exit 1
fi

# Check if Docker is installed
if ! which docker &> /dev/null; then
  error "Docker is not installed or not in this users PATH."
  exit 2
fi

if ! docker info &> /dev/null; then
  error "Docker is not running or you lack permissions to manage Docker."
  exit 3
fi

# Function to check for existing instances
check_existing() {
  info "Checking for existing qualys-container-sensor instances..."

  # Check if any container using the qualys/qcs-sensor image is running
  if docker ps --filter "ancestor=qualys/sensor" --format '{{.ID}}' | grep -q '.'; then
    if [[ "$FORCE_REINSTALL" == "true" ]]; then
      info "Existing instance found. FORCE_REINSTALL is true. Removing the existing container..."
      docker ps --filter "ancestor=qualys/sensor" --format '{{.ID}}' | xargs -r docker rm -f
    else
      error "Existing instance found. FORCE_REINSTALL is set to false. Exiting."
      exit 4
    fi
  else
    info "No existing instances found. Proceeding with installation..."
  fi
}

# Function to handle installation from tar.xz
install_from_tar() {
  info "Downloading tar.xz file from $LOCATION..."
  curl -s -S -o QualysContainerSensor.tar.xz "$LOCATION"

  if [ $? -ne 0 ]; then
    error "Failed to download the tar.xz file. Exiting."
    exit 11
  fi

  info "Extracting tar.xz file..."
  mkdir -p ~/qualys_container_sensor_installer
  if sudo tar -xf QualysContainerSensor.tar.xz -C ~/qualys_container_sensor_installer; then
    info "Extraction successful."
  else
    error "Failed to extract the tar.xz file. Exiting."
    exit 12
  fi

  info "Running sensor installation script..."
  if sudo ~/qualys_container_sensor_installer/installsensor.sh ActivationId="$ACTIVATIONID" \
      CustomerId="$CUSTOMERID" --sensor-without-persistent-storage -s $INSTALL_OPTIONS ; then
    info "Sensor installation completed successfully."
  else
    info "Sensor installation failed. Exiting."
    exit 13
  fi
}

# Function to handle installation from Dockerhub
install_from_dockerhub() {
  # Ensure required variables are set
  if [[ -z "$POD_URL" ]]; then
    error "POD_URL must be set when using Dockerhub."
    exit 21
  fi

  info "Installing from Dockerhub..."

  # Run Docker container
  CONTAINER_ID=$(sudo docker run -d --restart on-failure \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -e ACTIVATIONID="$ACTIVATIONID" \
    -e CUSTOMERID="$CUSTOMERID" \
    -e POD_URL="$POD_URL" \
    --net=host --name qualys-container-sensor qualys/qcs-sensor:latest \
    $INSTALL_OPTIONS 2>&1)

  # Check if the docker run command succeeded
  if [[ $? -ne 0 ]]; then
    error "Failed to start the Qualys container. Docker error on container ID $CONTAINER_ID"
    exit 24
  fi

  info "Container started with ID: $CONTAINER_ID"

  # Validate that the container is running
  RUNNING_STATUS=$(sudo docker inspect -f '{{.State.Running}}' qualys-container-sensor 2>/dev/null)
  if [[ "$RUNNING_STATUS" != "true" ]]; then
    error "Container did not start successfully."
    error "Check the container logs for details:"
    sudo docker logs qualys-container-sensor
    exit 25
  fi

  info "Qualys container sensor installed and running successfully."
}

# Main logic
check_existing

case "$LOCATION" in
  dockerhub)
    install_from_dockerhub
    ;;
  *)
    install_from_tar
    ;;
esac

info "Installation completed successfully."
exit 0
