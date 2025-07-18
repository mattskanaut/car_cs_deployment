#!/bin/bash

# Exit on error and undefined variables
set -euo pipefail

# Function to print help
print_help() {
  echo "Usage: $0 [OPTIONS]"
  echo "Install the Qualys Docker Sensor."
  echo
  echo "Options:"
  echo "  -l, --location <path|dockerhub>    Path to the tar.xz file (supports"
  echo "                                     S3, Azure Blob, GCS, OCI) or"
  echo "                                     'dockerhub' to pull the image."
  echo "  -a, --activation-id <id>          ActivationID for the sensor."
  echo "  -c, --customer-id <id>            CustomerID for the sensor."
  echo "  -p, --pod-url <url>               POD URL for Dockerhub option."
  echo "  -h, --help, -?                    Show this help message."
  echo
  echo "Notes on Signed URLs and Restricted Buckets:"
  echo "  - For cloud storage (S3, Azure Blob, GCS, OCI), signed URLs provide"
  echo "    temporary, pre-authenticated access to files."
  echo "  - Signed URLs respect bucket-level restrictions such as limiting"
  echo "    access to specific VPCs or networks."
  echo "  - Ensure your client has network access to the storage location (e.g.,"
  echo "    via VPC endpoint or equivalent)."
  echo
}

# Parse command-line arguments
LOCATION=""
ACTIVATIONID=""
CUSTOMERID=""
POD_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--location)
      LOCATION="$2"
      shift 2
      ;;
    -a|--activation-id)
      ACTIVATIONID="$2"
      shift 2
      ;;
    -c|--customer-id)
      CUSTOMERID="$2"
      shift 2
      ;;
    -p|--pod-url)
      POD_URL="$2"
      shift 2
      ;;
    -h|--help|-?)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_help
      exit 1
      ;;
  esac
done

# Validate mandatory arguments
if [[ -z "$LOCATION" || -z "$ACTIVATIONID" || -z "$CUSTOMERID" ]]; then
  echo "Error: --location, --activation-id, and --customer-id are required."
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
  echo "Error: A container built from the image 'qualys/qcs-sensor' is already"
  echo "       running."
  exit 4
fi

# Ensure location includes the correct filename
resolve_location() {
  local loc="$1"
  if [[ "$loc" =~ QualysContainerSensor\.tar\.xz$ ]]; then
    echo "$loc"
  else
    echo "${loc%/}/QualysContainerSensor.tar.xz"
  fi
}

# Function to handle installation from tar.xz
install_from_tar() {
  # Resolve the full location with filename
  local resolved_location
  resolved_location=$(resolve_location "$LOCATION")

  echo "Downloading tar.xz file from $resolved_location..."

  # Attempt to download the file with curl
  if [[ "$resolved_location" =~ ^s3:// || "$resolved_location" =~ ^gs:// || \
        "$resolved_location" =~ ^https://.*\.blob\.core\.windows\.net || \
        "$resolved_location" =~ ^https://.*\.compat\.objectstorage ]]; then
    curl -o QualysContainerSensor.tar.xz "$resolved_location"
  elif [[ "$resolved_location" =~ ^https:// ]]; then
    curl -o QualysContainerSensor.tar.xz "$resolved_location"
  else
    cp "$resolved_location" ./QualysContainerSensor.tar.xz
  fi

  echo "Extracting tar.xz file..."
  sudo tar -xvf QualysContainerSensor.tar.xz
  sudo mkdir -p /usr/local/qualys/sensor/data
  sudo ./installsensor.sh ActivationId="$ACTIVATIONID" \
      CustomerId="$CUSTOMERID" Storage=/usr/local/qualys/sensor/data -s
}

# Function to handle installation from Dockerhub
install_from_dockerhub() {
  if [[ -z "$POD_URL" ]]; then
    echo "Error: --pod-url is required when using Dockerhub."
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
