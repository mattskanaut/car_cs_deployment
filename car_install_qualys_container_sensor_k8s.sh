#!/bin/bash

# Exit on undefined variables and errors
set -eu

# ==============================
# Configuration Section
# ==============================

# Lock configuration for preventing concurrent Helm installations
LOCK_NAME="qualys-helm-install-lock"
LOCK_NAMESPACE="kube-system"
CRONJOB_NAME="clear-stale-qualys-lock"

# Script parameters
HELM_ARGS="${1:-}"
FORCE_REINSTALL="${2:-false}"
GENERATE="${3:-}"

# Normalize parameter values to lowercase for case-insensitive comparison
FORCE_REINSTALL="$(echo "$FORCE_REINSTALL" | tr '[:upper:]' '[:lower:]')"
GENERATE="$(echo "$GENERATE" | tr '[:upper:]' '[:lower:]')"

# Helm arguments passed to the script
# These should include all necessary values like:
#   --set activationId=xxx --set customerId=xxx --set image.registry=xxx
# Example usage:
#   ./car_install_qualys_container_sensor_k8s.sh "--set activationId=xxx --set customerId=xxx" install
#   ./car_install_qualys_container_sensor_k8s.sh "--set activationId=xxx --set customerId=xxx" install generate

# Helm release configuration
HELM_RELEASE_NAME="qualys-tc"
HELM_CHART_REPO="qualys-helm-chart/qualys-tc"
HELM_NAMESPACE="qualys"

# Lock timeout in seconds (15 minutes)
LOCK_TIMEOUT_SECONDS=900

# ==============================
# Script starts here
# ==============================

# Function to print help
print_help() {
  echo "This script installs the Qualys Container Sensor on Kubernetes using Helm."
  echo
  echo "Usage: $0 \"<helm-args>\" [FORCE_REINSTALL] [GENERATE]"
  echo
  echo "Parameters:"
  echo "  HELM_ARGS  - Helm arguments (quoted string)"
  echo "  FORCE_REINSTALL - Force reinstall even if release exists (default: false)"
  echo "  GENERATE   - Use 'generate' to create YAML version for environments without Helm"
  echo
  echo "FORCE_REINSTALL values:"
  echo "  false       - Install if missing, upgrade if present (default)"
  echo "  true        - Force reinstall regardless of current state"
  echo
  echo "Examples:"
  echo "  # Normal Helm installation:"
  echo "  $0 \"--set activationId=xxx --set customerId=xxx\" install"
  echo
  echo "  # Generate YAML version for kubectl-only environments:"
  echo "  $0 \"--set activationId=xxx --set customerId=xxx\" install generate"
  echo
  echo "The script will:"
  echo "  1. Detect if running in a Kubernetes environment"
  echo "  2. Acquire a cluster-wide lock to prevent concurrent installations"
  echo "  3. Install/upgrade the Qualys Helm chart OR use embedded YAML"
  echo "  4. Create a CronJob to clean up stale locks"
  echo
  echo "Generated script usage (no Helm required):"
  echo "  ./car_install_qualys_container_sensor_k8s_yaml.sh [ACTION]"
  echo
}

# Logging functions
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

warning() {
  while IFS= read -r line; do
    echo "[WARNING] $line"
  done <<< "$1"
}

# Generate YAML version of script for environments without Helm
generate_yaml_version() {
  local output_script="car_install_qualys_container_sensor_k8s_yaml.sh"
  
  info "Generating YAML version: $output_script"
  
  # Check if Helm is available for generation
  if ! check_helm; then
    error "Helm 3 is required to generate the YAML version."
    return 1
  fi
  
  # Generate YAML using helm template
  info "Generating YAML manifests using helm template..."
  local yaml_content
  yaml_content=$(helm template "$HELM_RELEASE_NAME" "$HELM_CHART_REPO" $HELM_ARGS --namespace "$HELM_NAMESPACE" --create-namespace 2>&1)
  
  if [[ $? -ne 0 ]]; then
    error "Failed to generate YAML: $yaml_content"
    return 1
  fi
  
  # Copy this script to new file
  cp "$0" "$output_script"
  
  # Modify the copied script for YAML version
  # Remove HELM_ARGS parameter requirement and add marker
  sed -i '1a\\n# YAML VERSION - Generated from helm template\\n# This version uses embedded YAML manifests and requires only kubectl' "$output_script"
  
  # Add embedded YAML and override functions at the end
  cat >> "$output_script" << 'EOF'

# ==============================
# EMBEDDED YAML CONTENT
# ==============================
EMBEDDED_YAML=$(cat << 'YAML_EOF'
YAML_CONTENT_PLACEHOLDER
YAML_EOF
)

# Override main function for YAML version
install_with_embedded_yaml() {
  local force_reinstall="$1"
  
  info "Deploying using embedded YAML manifests..."
  
  if [[ "$force_reinstall" == "true" ]]; then
    # Force reinstall - delete existing resources first
    info "Force reinstall requested - removing existing resources..."
    echo "$EMBEDDED_YAML" | kubectl delete -f - --ignore-not-found=true
    sleep 10
  fi
  
  # Apply the manifests
  echo "$EMBEDDED_YAML" | kubectl apply -f -
  
  return 0
}

# Override main execution for YAML version
main() {
  local force_reinstall="${FORCE_REINSTALL:-false}"
  
  # Validate FORCE_REINSTALL parameter
  case "$force_reinstall" in
    true|false)
      ;; # Valid values
    *)
      error "Invalid FORCE_REINSTALL: $force_reinstall. Valid values: true, false"
      print_help
      exit 1
      ;;
  esac
  
  # All existing logic for:
  # - Kubernetes environment detection
  # - Lock acquisition
  # - Error handling
  # - Logging
  
  # Check if we're in a Kubernetes environment
  if ! detect_kubernetes; then
    info "Kubernetes environment not detected. This script is intended to run on Kubernetes nodes."
    exit 0
  fi
  
  info "Kubernetes environment detected."
  
  # Check prerequisites (kubectl only)
  if ! check_kubectl; then
    error "kubectl is not properly configured. Exiting."
    exit 1
  fi
  
  # Use embedded YAML instead of Helm
  if acquire_lock; then
    info "Lock acquired. Proceeding with YAML deployment..."
    
    if install_with_embedded_yaml "$force_reinstall"; then
      info "Installation completed successfully."
    else
      error "Installation failed."
      kubectl delete configmap "$LOCK_NAME" -n "$LOCK_NAMESPACE" &>/dev/null || true
      exit 30
    fi
    
    kubectl delete configmap "$LOCK_NAME" -n "$LOCK_NAMESPACE" &>/dev/null || true
  else
    info "Could not acquire lock. Another installation may be in progress."
  fi
  
  # Ensure the cleanup CronJob is deployed
  create_cleanup_cronjob
  
  info "Script execution completed."
  exit 0
}

# Execute main function if this is the YAML version
if [[ -z "$HELM_ARGS" ]]; then
  main
fi
EOF
  
  # Replace placeholder with actual YAML (escape special characters)
  local escaped_yaml=$(printf '%s\n' "$yaml_content" | sed 's/[[\.*^$()+?{|\\]/\\&/g')
  sed -i "s/YAML_CONTENT_PLACEHOLDER/$escaped_yaml/" "$output_script"
  
  chmod +x "$output_script"
  
  info "Successfully generated: $output_script"
  info "Usage: ./$output_script [FORCE_REINSTALL]"
  info "This generated script requires only kubectl and works without Helm."
  
  return 0
}

# Function to detect Kubernetes environment
detect_kubernetes() {
  # Check multiple indicators of Kubernetes presence
  if pgrep -f kubelet >/dev/null 2>&1; then 
    return 0
  elif [ -f /etc/kubernetes/kubelet.conf ]; then 
    return 0
  elif [ -f /var/lib/kubelet/config.yaml ]; then 
    return 0
  elif command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then 
    return 0
  else 
    return 1
  fi
}

# Function to check if kubectl is available and configured
check_kubectl() {
  if ! command -v kubectl >/dev/null 2>&1; then
    error "kubectl command not found. Please ensure kubectl is installed."
    return 1
  fi
  
  if ! kubectl get nodes >/dev/null 2>&1; then
    error "kubectl cannot connect to the cluster. Please check your kubeconfig."
    return 1
  fi
  
  return 0
}

# Function to check if helm is available
check_helm() {
  if ! command -v helm >/dev/null 2>&1; then
    error "helm command not found. Please ensure Helm 3 is installed."
    return 1
  fi
  
  # Check Helm version (ensure it's Helm 3)
  local helm_version=$(helm version --short 2>/dev/null | grep -oE 'v[0-9]+' | head -1)
  if [[ "$helm_version" != "v3" ]]; then
    error "Helm 3 is required. Current version: $(helm version --short)"
    return 1
  fi
  
  return 0
}

# Function to create cleanup CronJob for stale locks
create_cleanup_cronjob() {
  info "Creating CronJob to clean up stale locks if not already present..."
  
  if ! kubectl get cronjob "$CRONJOB_NAME" -n "$LOCK_NAMESPACE" >/dev/null 2>&1; then
    kubectl apply -n "$LOCK_NAMESPACE" -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: $CRONJOB_NAME
  labels:
    app: qualys-lock-cleanup
    managed-by: qualys-installer
spec:
  schedule: "*/15 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: default
          containers:
          - name: cleanup
            image: bitnami/kubectl:latest
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              LOCK_NAME="$LOCK_NAME"
              LOCK_NAMESPACE="$LOCK_NAMESPACE"
              TIMEOUT_SECONDS=$LOCK_TIMEOUT_SECONDS
              
              if kubectl get configmap "\$LOCK_NAME" -n "\$LOCK_NAMESPACE" >/dev/null 2>&1; then
                CREATION_TIME=\$(kubectl get configmap "\$LOCK_NAME" -n "\$LOCK_NAMESPACE" -o jsonpath='{.metadata.creationTimestamp}')
                CREATION_SECONDS=\$(date -d "\$CREATION_TIME" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "\$CREATION_TIME" +%s)
                NOW_SECONDS=\$(date +%s)
                AGE=\$((NOW_SECONDS - CREATION_SECONDS))
                
                if [ "\$AGE" -gt "\$TIMEOUT_SECONDS" ]; then
                  echo "[INFO] Deleting stale lock (\$LOCK_NAME) older than \$((TIMEOUT_SECONDS/60)) minutes"
                  kubectl delete configmap "\$LOCK_NAME" -n "\$LOCK_NAMESPACE"
                else
                  echo "[INFO] Lock is still valid (age: \$((AGE/60)) minutes)"
                fi
              else
                echo "[INFO] No lock found"
              fi
          restartPolicy: OnFailure
          resources:
            limits:
              cpu: 100m
              memory: 128Mi
            requests:
              cpu: 50m
              memory: 64Mi
EOF
    info "CronJob created successfully."
  else
    info "CronJob already exists. Skipping creation."
  fi
}

# Function to acquire installation lock
acquire_lock() {
  local max_attempts=3
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    if kubectl create configmap "$LOCK_NAME" \
      -n "$LOCK_NAMESPACE" \
      --from-literal=owner="$(hostname)" \
      --from-literal=timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --from-literal=pid="$$" \
      >/dev/null 2>&1; then
      info "Acquired Helm install lock (attempt $attempt/$max_attempts)."
      return 0
    else
      if [ $attempt -lt $max_attempts ]; then
        info "Failed to acquire lock (attempt $attempt/$max_attempts). Retrying in 5 seconds..."
        sleep 5
      fi
    fi
    ((attempt++))
  done
  
  return 1
}

# Function to install or upgrade Helm chart
install_helm_chart() {
  local force_reinstall="$1"
  
  local mode="install/upgrade"
  if [[ "$force_reinstall" == "true" ]]; then
    mode="force reinstall"
  fi
  
  info "Performing '$mode' for Qualys Helm chart..."
  
  # Add Qualys Helm repository if not already added
  if ! helm repo list | grep -q "qualys-helm-chart"; then
    info "Adding Qualys Helm repository..."
    # Note: Replace with actual Qualys Helm repo URL when available
    # helm repo add qualys-helm-chart https://qualys.github.io/helm-charts
  fi
  
  # Update Helm repositories
  info "Updating Helm repositories..."
  helm repo update >/dev/null 2>&1 || true
  
  # Install or upgrade the chart (always use upgrade --install for Helm)
  local helm_command="upgrade --install"
  
  if helm $helm_command "$HELM_RELEASE_NAME" "$HELM_CHART_REPO" \
    $HELM_ARGS \
    --namespace "$HELM_NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout 10m; then
    info "Helm chart $action completed successfully."
    return 0
  else
    error "Helm chart $action failed."
    return 1
  fi
}

# Function to check if Qualys sensor is already installed
check_existing_installation() {
  if helm list -n "$HELM_NAMESPACE" | grep -q "$HELM_RELEASE_NAME"; then
    info "Qualys sensor Helm release already exists in namespace $HELM_NAMESPACE."
    local current_revision=$(helm list -n "$HELM_NAMESPACE" | grep "$HELM_RELEASE_NAME" | awk '{print $3}')
    info "Current revision: $current_revision"
    return 0
  else
    info "No existing Qualys sensor installation found."
    return 1
  fi
}

# Installation decision function
check_and_decide_installation() {
  local force_reinstall="$1"
  local installation_exists=false
  local pods_running=false
  
  # Check installation existence
  if check_existing_installation; then
    installation_exists=true
    
    # Check if pods are actually running
    local running_pods=$(kubectl get pods -n "$HELM_NAMESPACE" -l "release=$HELM_RELEASE_NAME" -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -c "Running" || echo "0")
    local total_pods=$(kubectl get pods -n "$HELM_NAMESPACE" -l "release=$HELM_RELEASE_NAME" -o json 2>/dev/null | jq '.items | length' || echo "0")
    
    if [[ "$running_pods" -gt 0 ]] && [[ "$running_pods" -eq "$total_pods" ]]; then
      pods_running=true
      info "All sensor pods are running ($running_pods/$total_pods)"
    else
      info "Sensor pods not fully running ($running_pods/$total_pods)"
    fi
  fi
  
  # Decide based on force_reinstall parameter
  if [[ "$force_reinstall" == "true" ]]; then
    if $installation_exists; then
      info "Force reinstall requested - removing existing installation..."
      helm uninstall "$HELM_RELEASE_NAME" -n "$HELM_NAMESPACE" --wait || true
      sleep 5
    fi
    return 0  # Always proceed with installation
  else
    # Default behavior: ensure running sensors
    if ! $installation_exists; then
      info "Installing new Helm release..."
      return 0  # Proceed with installation
    elif ! $pods_running; then
      info "Sensor pods not running properly - reinstalling..."
      helm uninstall "$HELM_RELEASE_NAME" -n "$HELM_NAMESPACE" --wait || true
      sleep 5
      return 0  # Proceed with reinstall
    else
      info "Existing Helm release with running pods found - upgrading..."
      return 0  # Proceed with upgrade (helm upgrade --install will handle it)
    fi
  fi
}

# ==============================
# Main execution
# ==============================

# Self-cloning functionality
if [[ "$GENERATE" == "generate" ]]; then
  generate_yaml_version
  exit 0
fi

# Check if help is requested
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]] || [[ -z "${1:-}" ]]; then
  print_help
  exit 0
fi

# Validate FORCE_REINSTALL parameter
if [[ "$FORCE_REINSTALL" != "true" && "$FORCE_REINSTALL" != "false" ]]; then
  error "Invalid FORCE_REINSTALL value: $FORCE_REINSTALL. Valid values: true, false (case-insensitive)"
  exit 1
fi

# Log the installation mode
if [[ "$FORCE_REINSTALL" == "true" ]]; then
  info "Running in FORCE REINSTALL mode - will remove and reinstall Helm release"
else
  info "Running in INSTALL/UPGRADE mode - will install if missing or upgrade if present"
fi

# Validate that we're in a Kubernetes environment
if ! detect_kubernetes; then
  info "Kubernetes environment not detected. This script is intended to run on Kubernetes nodes."
  info "Skipping Helm chart installation."
  exit 0
fi

info "Kubernetes environment detected."

# Check prerequisites
if ! check_kubectl; then
  error "kubectl is not properly configured. Exiting."
  exit 1
fi

if ! check_helm; then
  error "Helm 3 is not installed. Exiting."
  exit 1
fi

# Check if action should proceed
if ! check_and_decide_installation "$FORCE_REINSTALL"; then
  info "No action needed based on FORCE_REINSTALL parameter '$FORCE_REINSTALL'."
  exit 7
fi

# Try to acquire the installation lock
info "Attempting to acquire Helm install lock..."

if acquire_lock; then
  info "Lock acquired. Proceeding with Helm chart $ACTION..."
  
  # Perform the Helm installation
  if install_helm_chart "$FORCE_REINSTALL"; then
    info "Installation completed successfully."
  else
    error "Installation failed."

    # Release the lock on failure
    kubectl delete configmap "$LOCK_NAME" -n "$LOCK_NAMESPACE" >/dev/null 2>&1 || true
    exit 30
  fi
  # Release the lock on completion
  kubectl delete configmap "$LOCK_NAME" -n "$LOCK_NAMESPACE" >/dev/null 2>&1 || true
else
  info "Could not acquire install lock. Another node may be performing the installation."
  info "Checking lock status..."
  
  if kubectl get configmap "$LOCK_NAME" -n "$LOCK_NAMESPACE" >/dev/null 2>&1; then
    local lock_owner=$(kubectl get configmap "$LOCK_NAME" -n "$LOCK_NAMESPACE" -o jsonpath='{.data.owner}' 2>/dev/null || echo "unknown")
    local lock_time=$(kubectl get configmap "$LOCK_NAME" -n "$LOCK_NAMESPACE" -o jsonpath='{.data.timestamp}' 2>/dev/null || echo "unknown")
    info "Lock is held by: $lock_owner since $lock_time"
  fi
  
  info "Skipping Helm install to avoid conflicts."
fi

# Ensure the cleanup CronJob is deployed
# This will clean up stale locks if nodes fail during installation
create_cleanup_cronjob

info "Script execution completed."
exit 0
