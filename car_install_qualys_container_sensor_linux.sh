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
FORCE_REINSTALL="${6:-false}" # Force reinstall even if container exists and is up to date

# Normalize all parameter values to lowercase for case-insensitive comparison
LOCATION="$(echo "$LOCATION" | tr '[:upper:]' '[:lower:]')"
POD_URL="$(echo "$POD_URL" | tr '[:upper:]' '[:lower:]')"
INSTALL_OPTIONS="$(echo "$INSTALL_OPTIONS" | tr '[:upper:]' '[:lower:]')"
FORCE_REINSTALL="$(echo "$FORCE_REINSTALL" | tr '[:upper:]' '[:lower:]')"

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
  echo "  FORCE_REINSTALL - Force reinstall even if container exists and is up to date (default: false)"
  echo ""
  echo "Note: All parameter values are case-insensitive (e.g., 'NONE', 'none', 'None' all work)."
  echo
  echo "FORCE_REINSTALL values:"
  echo "  false       - Install if missing, upgrade if outdated (default)"
  echo "  true        - Force reinstall regardless of current state"
  echo
  echo "Examples:"
  echo "  # Install from tar.xz without additional options:"
  echo "  $0 's3://bucket/QualysContainerSensor.tar.xz' 'activation-id' 'customer-id' NONE NONE false"
  echo
  echo "  # Install from Dockerhub with registry sensor option:"
  echo "  $0 'dockerhub' 'activation-id' 'customer-id' 'https://pod.url' '--registry-sensor' false"
  echo
  echo "  # Examples with different case variations:"
  echo "  $0 'DOCKERHUB' 'activation-id' 'customer-id' 'https://pod.url' 'none' TRUE"
  echo "  $0 'DockerHub' 'activation-id' 'customer-id' 'https://pod.url' 'None' False"
  echo ""
  echo "Note: Use 'NONE' for optional parameters that are not needed. All values are case-insensitive."
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

# Additional logging functions
warning() {
  while IFS= read -r line; do
    echo "[WARNING] $line"
  done <<< "$1"
}

# Version checking function for Docker Hub installations
check_container_version() {
  local container_name="${1:-qualys-container-sensor}"
  
  # Get running container's image SHA
  local running_sha=""
  if $RUNTIME inspect "$container_name" &>/dev/null; then
    running_sha=$($RUNTIME inspect "$container_name" --format='{{.Image}}' 2>/dev/null)
  fi
  
  # Get latest SHA from Docker Hub (no pull credits)
  local latest_sha=$(curl -s "https://hub.docker.com/v2/repositories/qualys/qcs-sensor/tags/latest" | jq -r '.images[0].digest' 2>/dev/null)
  
  if [[ -n "$running_sha" && -n "$latest_sha" && "$running_sha" != "$latest_sha" ]]; then
    return 0  # Upgrade available
  else
    return 1  # Up to date or error
  fi
}

# Container existence checking
container_exists() {
  local container_name="${1:-qualys-container-sensor}"
  
  if $RUNTIME ps -a --filter "name=$container_name" --format '{{.ID}}' | grep -q .; then
    return 0  # Container exists
  else
    return 1  # Container does not exist
  fi
}

# Container running check
container_running() {
  local container_name="${1:-qualys-container-sensor}"
  
  local status=$($RUNTIME inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)
  if [[ "$status" == "true" ]]; then
    return 0  # Running
  else
    return 1  # Not running
  fi
}

# Remove existing container
remove_existing_container() {
  local container_name="${1:-qualys-container-sensor}"
  
  info "Stopping and removing existing container: $container_name"
  
  # Stop if running
  if container_running "$container_name"; then
    $RUNTIME stop "$container_name" >/dev/null 2>&1
  fi
  
  # Remove container
  $RUNTIME rm -f "$container_name" >/dev/null 2>&1
  
  info "Existing container removed successfully"
}

# Validate mandatory variables
if [[ -z "$LOCATION" || -z "$ACTIVATIONID" || -z "$CUSTOMERID" ]]; then
  error "LOCATION, ACTIVATIONID, and CUSTOMERID must be set and not empty."
  print_help
  exit 1
fi

# Detect container runtimes - support multi-deployment
DOCKER_AVAILABLE=false
PODMAN_AVAILABLE=false
RUNTIMES=()
if which docker &> /dev/null && docker info &> /dev/null; then
  DOCKER_AVAILABLE=true
  RUNTIMES+=("docker")
  info "Detected Docker runtime"
fi

if which podman &> /dev/null && podman info &> /dev/null; then
  PODMAN_AVAILABLE=true
  RUNTIMES+=("podman")
  info "Detected Podman runtime"
fi

if [[ ${#RUNTIMES[@]} -eq 0 ]]; then
  error "No container runtime (Docker or Podman) detected or accessible."
  exit 2
fi

info "Found ${#RUNTIMES[@]} container runtime(s): ${RUNTIMES[*]}"

# Track deployment results
declare -A DEPLOYMENT_RESULTS

# Validate FORCE_REINSTALL parameter
if [[ "$FORCE_REINSTALL" != "true" && "$FORCE_REINSTALL" != "false" ]]; then
  error "Invalid FORCE_REINSTALL value: $FORCE_REINSTALL. Valid values: true, false (case-insensitive)"
  exit 1
fi

# Log the installation mode
if [[ "$FORCE_REINSTALL" == "true" ]]; then
  info "Running in FORCE REINSTALL mode - will remove and reinstall all containers"
else
  info "Running in INSTALL/UPGRADE mode - will install if missing or upgrade if outdated"
fi

# Installation decision function
check_and_decide_installation() {
  local force_reinstall="$1"
  local container_name="$2"
  local runtime="$3"
  local location="$4"
  
  local container_exists=false
  local is_outdated=false
  local is_running=false
  
  # Check container existence
  if container_exists "$container_name"; then
    container_exists=true
    info "Existing sensor container found for $runtime"
    
    # Check if container is running
    local container_status=$($runtime inspect -f '{{.State.Status}}' "$container_name" 2>/dev/null)
    if [[ "$container_status" == "running" ]]; then
      is_running=true
    fi
    info "Container status: $container_status"
    
    # Check if outdated (Docker Hub only, and only if running)
    if [[ "$location" == "dockerhub" ]] && $is_running; then
      if check_container_version "$container_name"; then
        is_outdated=true
        info "Container is outdated for $runtime"
      else
        info "Container is up to date for $runtime"
      fi
    fi
  else
    info "No existing sensor container found for $runtime"
  fi
  
  # Decide based on force_reinstall parameter
  if [[ "$force_reinstall" == "true" ]]; then
    if $container_exists; then
      info "Force reinstall requested - removing existing container for $runtime..."
      remove_existing_container "$container_name"
    fi
    return 0  # Always proceed with installation
  else
    # Default behavior: ensure a running, up-to-date sensor
    if ! $container_exists; then
      info "Installing new container for $runtime..."
      return 0  # Proceed with installation
    elif ! $is_running; then
      info "Container exists but is not running (status: $container_status) - reinstalling for $runtime..."
      remove_existing_container "$container_name"
      return 0  # Proceed with reinstall
    elif [[ "$location" == "dockerhub" ]] && $is_outdated; then
      info "Upgrading outdated container for $runtime..."
      remove_existing_container "$container_name"
      return 0  # Proceed with upgrade
    else
      info "Container exists, is running, and is up to date for $runtime - no action needed."
      return 1  # Skip installation
    fi
  fi
}

# Deploy to a specific runtime
deploy_to_runtime() {
  local runtime="$1"
  local location="$2"
  local activation_id="$3"
  local customer_id="$4"
  local pod_url="$5"
  local install_options="$6"
  
  info "Starting deployment to $runtime..."
  
  if [[ "$location" == "dockerhub" ]]; then
    deploy_from_dockerhub "$runtime" "$activation_id" "$customer_id" "$pod_url" "$install_options"
  else
    deploy_from_tar "$runtime" "$location" "$activation_id" "$customer_id" "$install_options"
  fi
}

# Function to handle installation from tar.xz
deploy_from_tar() {
  local runtime="$1"
  local location="$2"
  local activation_id="$3"
  local customer_id="$4"
  local install_options="$5"
  
  info "Downloading tar.xz file from $location for $runtime..."
  curl -s -S -o QualysContainerSensor.tar.xz "$location"

  if [ $? -ne 0 ]; then
    error "Failed to download the tar.xz file for $runtime."
    return 4
  fi

  info "Extracting tar.xz file for $runtime..."
  mkdir -p ~/qualys_container_sensor_installer
  if sudo tar -xf QualysContainerSensor.tar.xz -C ~/qualys_container_sensor_installer; then
    info "Extraction successful for $runtime."
  else
    error "Failed to extract the tar.xz file for $runtime."
    return 12
  fi

  # Create the storage directory if it doesn't exist
  info "Creating storage directory /usr/local/qualys/sensor/data for $runtime..."
  sudo mkdir -p /usr/local/qualys/sensor/data
  
  info "Running sensor installation script for $runtime..."
  
  # Build install command with runtime-specific options
  INSTALL_CMD="sudo ~/qualys_container_sensor_installer/installsensor.sh ActivationId=$activation_id CustomerId=$customer_id Storage=/usr/local/qualys/sensor/data -s"
  
  if [[ "$runtime" == "podman" ]]; then
    INSTALL_CMD="$INSTALL_CMD ContainerRuntime=podman StorageDriverType=overlay"
  else
    INSTALL_CMD="$INSTALL_CMD StorageDriverType=overlay2"
  fi
  
  # Add --perform-sca-scan as best practice
  INSTALL_CMD="$INSTALL_CMD --perform-sca-scan"
  
  # Add any additional install options if provided
  if [[ "$install_options" != "none" ]]; then
    INSTALL_CMD="$INSTALL_CMD $install_options"
  fi
  
  info "Executing command: $INSTALL_CMD"
  
  if eval $INSTALL_CMD; then
    info "Sensor installation completed successfully for $runtime."
    return 0
  else
    error "Sensor installation failed for $runtime."
    return 13
  fi
}

# Function to handle installation from Dockerhub
deploy_from_dockerhub() {
  local runtime="$1"
  local activation_id="$2"
  local customer_id="$3"
  local pod_url="$4"
  local install_options="$5"
  
  # Ensure required variables are set
  if [[ "$pod_url" == "none" || -z "$pod_url" ]]; then
    error "POD_URL must be set when using Dockerhub for $runtime."
    return 21
  fi

  info "Installing from Dockerhub for $runtime..."

  # Set socket mount based on runtime
  if [[ "$runtime" == "podman" ]]; then
    SOCKET_MOUNT="-v /run/podman/podman.sock:/var/run/docker.sock:ro"
  else
    SOCKET_MOUNT="-v /var/run/docker.sock:/var/run/docker.sock:ro"
  fi

  # Run container
  CONTAINER_ID=$(sudo $runtime run -d --restart on-failure \
    $SOCKET_MOUNT \
    -v /usr/local/qualys/sensor/data:/usr/local/qualys/qpa/data \
    -e ACTIVATIONID="$activation_id" \
    -e CUSTOMERID="$customer_id" \
    -e POD_URL="$pod_url" \
    --net=host --name qualys-container-sensor qualys/qcs-sensor:latest \
    --perform-sca-scan $([ "$install_options" != "none" ] && echo "$install_options") 2>&1)

  # Check if the run command succeeded
  if [[ $? -ne 0 ]]; then
    error "Failed to start the Qualys container for $runtime. Error: $CONTAINER_ID"
    return 24
  fi

  info "Container started with ID: $CONTAINER_ID for $runtime"

  # Validate that the container is running
  sleep 3
  RUNNING_STATUS=$(sudo $runtime inspect -f '{{.State.Running}}' qualys-container-sensor 2>/dev/null)
  if [[ "$RUNNING_STATUS" != "true" ]]; then
    error "Container did not start successfully for $runtime."
    error "Check the container logs for details:"
    sudo $runtime logs qualys-container-sensor
    return 25
  fi

  info "Qualys container sensor installed and running successfully for $runtime."
  return 0
}

# Deploy to each runtime
for runtime in "${RUNTIMES[@]}"; do
  info "Processing deployment for $runtime..."
  
  # Check if installation should proceed for this runtime
  if check_and_decide_installation "$FORCE_REINSTALL" "qualys-container-sensor" "$runtime" "$LOCATION"; then
    if deploy_to_runtime "$runtime" "$LOCATION" "$ACTIVATIONID" "$CUSTOMERID" "$POD_URL" "$INSTALL_OPTIONS"; then
      DEPLOYMENT_RESULTS["$runtime"]="SUCCESS:Deployed successfully"
      info "Deployment successful for $runtime"
    else
      DEPLOYMENT_RESULTS["$runtime"]="FAILED:Deployment failed"
      error "Deployment failed for $runtime"
    fi
  else
    DEPLOYMENT_RESULTS["$runtime"]="SKIPPED:No action needed based on FORCE_REINSTALL parameter"
    info "Skipping deployment for $runtime"
  fi
done

# Generate deployment summary
echo ""
echo "========================================"
echo "Deployment Summary:"
echo "========================================"
mode="Install/Upgrade"
if [[ "$FORCE_REINSTALL" == "true" ]]; then
  mode="Force Reinstall"
fi
echo "Mode: $mode"
echo "Detected runtimes: ${#DEPLOYMENT_RESULTS[@]}"
echo ""

success_count=0
failed_count=0
skipped_count=0

for runtime in "${!DEPLOYMENT_RESULTS[@]}"; do
  status="${DEPLOYMENT_RESULTS[$runtime]%%:*}"
  message="${DEPLOYMENT_RESULTS[$runtime]#*:}"
  
  case "$status" in
    "SUCCESS")
      echo "[OK] $runtime: $status - $message"
      ((success_count++))
      ;;
    "FAILED")
      echo "[FAIL] $runtime: $status - $message"
      ((failed_count++))
      ;;
    "SKIPPED")
      echo "- $runtime: $status - $message"
      ((skipped_count++))
      ;;
  esac
done

echo ""
if [[ $skipped_count -gt 0 ]]; then
  echo "Total: $success_count/${#DEPLOYMENT_RESULTS[@]} deployments successful ($skipped_count skipped)"
else
  echo "Total: $success_count/${#DEPLOYMENT_RESULTS[@]} deployments successful"
fi
echo "========================================"

# Determine exit code
if [[ $failed_count -eq 0 && $success_count -gt 0 ]]; then
  info "All deployments completed successfully."
  exit 0
elif [[ $success_count -gt 0 && $failed_count -gt 0 ]]; then
  warning "Partial success: $success_count/${#DEPLOYMENT_RESULTS[@]} deployments succeeded."
  exit 6
elif [[ $success_count -eq 0 && $failed_count -gt 0 ]]; then
  error "All deployments failed."
  exit 5
else
  info "No deployments were needed."
  exit 7
fi
