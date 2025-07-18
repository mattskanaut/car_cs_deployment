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

LOCATION="$1" # Download location for QualysContainerSensor.tar.xz installer, or enter "dockerhub" to pull sensor from docker
ACTIVATIONID="$2" # Activation ID
CUSTOMERID="$3" # Customer ID
POD_URL="$4" # Required for install from docker hub, NONE if not required
INSTALL_OPTIONS="$5" # Additional sensor install options, e.g. --registry-sensor, NONE if not required
FORCE_REINSTALL="$6" # Force a reinstall if the sensor is already deployed true|false

# ==============================
# Script starts here
# ==============================

# Function to print help
print_help() {
  echo "This script installs the Qualys Container Sensor (Docker or Podman)."
  echo
  echo "Usage: $0 <LOCATION> <ACTIVATIONID> <CUSTOMERID> <POD_URL> <INSTALL_OPTIONS> <FORCE_REINSTALL>"
  echo
  echo "Parameters:"
  echo "  LOCATION        - Path to tar.xz file or 'dockerhub' for Dockerhub"
  echo "  ACTIVATIONID    - Your Qualys ActivationID"
  echo "  CUSTOMERID      - Your Qualys CustomerID"
  echo "  POD_URL         - POD URL (required for Dockerhub only, use 'NONE' for tar.xz install)"
  echo "  INSTALL_OPTIONS - Additional sensor install options (use 'NONE' if not needed)"
  echo "  FORCE_REINSTALL - Force reinstall if sensor exists (true/false, defaults to true)"
  echo
  echo "Examples:"
  echo "  # Install from tar.xz without additional options:"
  echo "  $0 's3://bucket/QualysContainerSensor.tar.xz' 'activation-id' 'customer-id' NONE NONE true"
  echo
  echo "  # Install from Dockerhub with registry sensor option:"
  echo "  $0 'dockerhub' 'activation-id' 'customer-id' 'https://pod.url' '--registry-sensor' false"
  echo
  echo "Note: Use 'NONE' for optional parameters that are not needed."
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

# Detect container runtime
RUNTIME=""
if which docker &> /dev/null && docker info &> /dev/null; then
  if which podman &> /dev/null && podman info &> /dev/null; then
    error "Both Docker and Podman are installed and running. Please stop one before proceeding."
    exit 2
  fi
  RUNTIME="docker"
  info "Detected Docker runtime"
elif which podman &> /dev/null && podman info &> /dev/null; then
  RUNTIME="podman"
  info "Detected Podman runtime"
else
  error "No container runtime (Docker or Podman) detected or accessible."
  exit 2
fi

# Function to check for existing instances
check_existing() {
  info "Checking for existing qualys-container-sensor instances..."

  # Check if any container using the qualys/qcs-sensor image is running
  if $RUNTIME ps --filter "ancestor=qualys/sensor" --format '{{.ID}}' | grep -q '.'; then
    if [[ "$FORCE_REINSTALL" == "true" ]]; then
      info "Existing instance found. FORCE_REINSTALL is true. Removing the existing container..."
      $RUNTIME ps --filter "ancestor=qualys/sensor" --format '{{.ID}}' | xargs -r $RUNTIME rm -f
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

  # Create the storage directory if it doesn't exist
  info "Creating storage directory /usr/local/qualys/sensor/data..."
  sudo mkdir -p /usr/local/qualys/sensor/data
  
  info "Running sensor installation script..."
  
  # Build install command with runtime-specific options (removed quotes around parameter values)
  INSTALL_CMD="sudo ~/qualys_container_sensor_installer/installsensor.sh ActivationId=$ACTIVATIONID CustomerId=$CUSTOMERID Storage=/usr/local/qualys/sensor/data -s"
  
  if [[ "$RUNTIME" == "podman" ]]; then
    INSTALL_CMD="$INSTALL_CMD ContainerRuntime=podman StorageDriverType=overlay"
  else
    INSTALL_CMD="$INSTALL_CMD StorageDriverType=overlay2"
  fi
  
  # Add --perform-sca-scan as best practice
  INSTALL_CMD="$INSTALL_CMD --perform-sca-scan"
  
  # Add any additional install options if provided
  if [[ "$INSTALL_OPTIONS" != "NONE" ]]; then
    INSTALL_CMD="$INSTALL_CMD $INSTALL_OPTIONS"
  fi
  
  info "Executing command: $INSTALL_CMD"
  
  if eval $INSTALL_CMD; then
    info "Sensor installation completed successfully."
  else
    error "Sensor installation failed. Exiting."
    exit 13
  fi
}

# Function to handle installation from Dockerhub
install_from_dockerhub() {
  # Ensure required variables are set
  if [[ "$POD_URL" == "NONE" || -z "$POD_URL" ]]; then
    error "POD_URL must be set when using Dockerhub."
    exit 21
  fi

  info "Installing from Dockerhub..."

  # Set socket mount based on runtime
  if [[ "$RUNTIME" == "podman" ]]; then
    SOCKET_MOUNT="-v /run/podman/podman.sock:/var/run/docker.sock:ro"
  else
    SOCKET_MOUNT="-v /var/run/docker.sock:/var/run/docker.sock:ro"
  fi

  # Run container
  CONTAINER_ID=$(sudo $RUNTIME run -d --restart on-failure \
    $SOCKET_MOUNT \
    -v /usr/local/qualys/sensor/data:/usr/local/qualys/qpa/data \
    -e ACTIVATIONID="$ACTIVATIONID" \
    -e CUSTOMERID="$CUSTOMERID" \
    -e POD_URL="$POD_URL" \
    --net=host --name qualys-container-sensor qualys/qcs-sensor:latest \
    --perform-sca-scan $([ "$INSTALL_OPTIONS" != "NONE" ] && echo "$INSTALL_OPTIONS") 2>&1)

  # Check if the run command succeeded
  if [[ $? -ne 0 ]]; then
    error "Failed to start the Qualys container. $RUNTIME error on container ID $CONTAINER_ID"
    exit 24
  fi

  info "Container started with ID: $CONTAINER_ID"

  # Validate that the container is running
  RUNNING_STATUS=$(sudo $RUNTIME inspect -f '{{.State.Running}}' qualys-container-sensor 2>/dev/null)
  if [[ "$RUNNING_STATUS" != "true" ]]; then
    error "Container did not start successfully."
    error "Check the container logs for details:"
    sudo $RUNTIME logs qualys-container-sensor
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
