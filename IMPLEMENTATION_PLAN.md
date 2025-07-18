# Qualys Container Sensor CAR Scripts Implementation Plan

## Project Overview

### Purpose
The CAR (Custom Assessment and Remediation) scripts provide a unified method for deploying Qualys Container Sensors across different platforms using Qualys Cloud Agent's remote execution capabilities. These scripts support Docker and Podman container runtimes on Linux, Windows, and Kubernetes environments.

### Current State
- **Linux script**: Complete and working (`car_install_qualys_container_sensor_linux.sh`)
- **Windows script**: Basic Docker Hub support only (`car_install_qualys_container_sensor_win.ps1`)
- **Kubernetes script**: Advanced with ConfigMap locking (`car_install_qualys_container_sensor_k8s.sh`)

### Design Goals
1. **Unified behavior** across all platforms
2. **Intelligent upgrade detection** without consuming Docker Hub pull credits
3. **Flexible installation modes** to handle different deployment scenarios
4. **Consistent logging and error handling**
5. **Self-updating sensor support** (tar.xz method)

## Architecture Decisions

### Parameter Design Changes
The current implementation uses an `ACTION` parameter with 4 modes that creates unnecessary complexity. The new design simplifies this:
- `install` - Install only if not present (default behavior)
- `upgrade` - Upgrade only if present and outdated  
- `ensure` - Install if missing, upgrade if outdated (maintenance mode)
- `reinstall` - Force reinstall regardless of current state

**Rationale:**
- More intuitive than boolean flags
- Covers all deployment scenarios
- Self-documenting parameter values
- Extensible for future needs

### Version Checking Strategy
**For Docker Hub installations only** (tar.xz installations are self-updating):

```bash
# Get SHA of running container's image (local operation)
RUNNING_SHA=$(docker inspect qualys-container-sensor --format='{{.Image}}' 2>/dev/null)

# Get SHA that latest tag points to (API call - NO PULL CREDITS)
LATEST_SHA=$(curl -s "https://hub.docker.com/v2/repositories/qualys/qcs-sensor/tags/latest" | jq -r '.images[0].digest')

# Compare SHAs
if [[ "$RUNNING_SHA" != "$LATEST_SHA" ]]; then
    # Upgrade available
fi
```

**Benefits:**
- No Docker Hub pull credits consumed
- Reliable SHA comparison
- Fast execution
- Works with any container runtime

### Installation Methods

#### 1. Tar.xz Method (Preferred)
- **Self-updating sensors** - Automatically update themselves
- **No version checking needed** - Sensors handle their own updates
- **Better for production** - More reliable update mechanism
- **Signed URL support** - Secure access to installation files

#### 2. Docker Hub Method
- **Manual updates** - Requires script-based upgrade detection
- **Version checking required** - SHA comparison implementation
- **Simpler initial setup** - No file hosting needed
- **Rate limit considerations** - Only for actual pulls, not version checks

#### 3. Kubernetes Self-Cloning Method
- **User-controlled generation** - Generate YAML version on local machine with Helm
- **Self-cloning capability** - Original script generates YAML version for remote deployment
- **No Helm dependency** - Generated script works with kubectl only on target nodes
- **Preserves all functionality** - Locking, FORCE_REINSTALL parameter, error handling

## Technical Specifications

### Parameter Structure
All scripts must use consistent parameter ordering:

```bash
# Linux and Windows  
./script.sh <LOCATION> <ACTIVATIONID> <CUSTOMERID> <POD_URL> <INSTALL_OPTIONS> <FORCE_REINSTALL>

# Kubernetes - Normal usage (with Helm)
./script.sh "<HELM_ARGS>" <FORCE_REINSTALL>

# Kubernetes - Generate YAML version
./script.sh "<HELM_ARGS>" <FORCE_REINSTALL> generate

# Kubernetes - YAML version usage (no Helm required)
./car_install_qualys_container_sensor_k8s_yaml.sh <FORCE_REINSTALL>
```

**Parameter Details:**
1. `LOCATION` - Path to tar.xz file or "dockerhub"
2. `ACTIVATIONID` - Qualys activation ID
3. `CUSTOMERID` - Qualys customer ID  
4. `POD_URL` - Required for Docker Hub, "NONE" for tar.xz
5. `INSTALL_OPTIONS` - Additional options or "NONE"
6. `FORCE_REINSTALL` - true/false (default: false)

**Kubernetes Parameter Details:**
1. `HELM_ARGS` - Complete Helm arguments (quoted string)
2. `FORCE_REINSTALL` - true/false (default: false)
3. `GENERATE` - "generate" to create YAML version (optional)

**Note:** All parameters are positional to support CAR UI field mapping. No dash-style flags (--flag) are used. FORCE_REINSTALL accepts "true" or "false" values.

### Version Checking Implementation

#### Common Function Template
```bash
check_container_version() {
    local container_name="${1:-qualys-container-sensor}"
    local image_name="${2:-qualys/qcs-sensor:latest}"
    
    # Get running container's image SHA
    local running_sha=""
    if docker inspect "$container_name" &>/dev/null; then
        running_sha=$(docker inspect "$container_name" --format='{{.Image}}' 2>/dev/null)
    fi
    
    # Get latest SHA from Docker Hub (no pull credits)
    local latest_sha=$(curl -s "https://hub.docker.com/v2/repositories/qualys/qcs-sensor/tags/latest" | jq -r '.images[0].digest')
    
    # Return comparison result
    if [[ -n "$running_sha" && -n "$latest_sha" && "$running_sha" != "$latest_sha" ]]; then
        return 0  # Upgrade available
    else
        return 1  # Up to date or error
    fi
}
```

#### Platform-Specific Considerations

**Linux:**
- Docker and Podman support
- Socket paths: `/var/run/docker.sock` or `/run/podman/podman.sock`

**Windows:**
- Docker Desktop and Podman support
- Socket paths: `\\.\pipe\docker_engine` or `\\.\pipe\podman-machine-default`
- WSL integration (optional)
- PowerShell vs bash differences

**Kubernetes:**
- Helm-based deployment (original script) or embedded YAML (generated script)
- ConfigMap locking mechanism
- Node-level execution considerations
- User-controlled generation for environments without Helm

### Kubernetes Self-Cloning Implementation

#### Workflow Overview
The Kubernetes script supports two distinct modes of operation:

1. **Original Script Mode** - Requires Helm on target nodes
   - Directly uses `helm upgrade --install` commands
   - Provides immediate feedback if Helm is unavailable
   - Suitable for environments with Helm installed

2. **Generated Script Mode** - Requires only kubectl on target nodes
   - User generates YAML version on local machine (with Helm)
   - Generated script contains embedded YAML manifests
   - Suitable for deployment via CAR to nodes without Helm

**User Decision Point:**
- If Helm is available on target nodes → Use original script
- If Helm is not available on target nodes → Generate YAML version locally, deploy generated script

#### Core Self-Cloning Logic
```bash
#!/bin/bash
# car_install_qualys_container_sensor_k8s.sh

HELM_ARGS="$1"
FORCE_REINSTALL="${2:-false}"
GENERATE="${3:-}"

# Self-cloning functionality
if [[ "$GENERATE" == "generate" ]]; then
    generate_yaml_version
    exit 0
fi

# Main execution
main() {
    # Check if we're the YAML version (no HELM_ARGS parameter)
    if [[ -z "$HELM_ARGS" ]]; then
        # This is the generated YAML version - use embedded YAML
        install_with_embedded_yaml "$FORCE_REINSTALL"
    else
        # This is the original script - requires Helm
        if command -v helm &>/dev/null && helm list &>/dev/null 2>&1; then
            install_with_helm "$HELM_ARGS" "$FORCE_REINSTALL"
        else
            error "Helm is required but not available or not configured."
            error "To deploy without Helm:"
            error "1. Run this script with 'generate' parameter on a machine with Helm"
            error "2. Use the generated YAML version on target nodes"
            exit 2
        fi
    fi
}

# Generate YAML version of script
generate_yaml_version() {
    local output_script="car_install_qualys_container_sensor_k8s_yaml.sh"
    
    info "Generating YAML version: $output_script"
    
    # Generate YAML using helm template
    local yaml_content
    yaml_content=$(helm template qualys-tc qualys-helm-chart/qualys-tc $HELM_ARGS --namespace qualys --create-namespace 2>&1)
    
    if [[ $? -ne 0 ]]; then
        error "Failed to generate YAML: $yaml_content"
        return 1
    fi
    
    # Copy this script to new file
    cp "$0" "$output_script"
    
    # Modify the copied script
    # Remove HELM_ARGS parameter
    sed -i '/^HELM_ARGS=/d' "$output_script"
    
    # Add marker for YAML version
    sed -i '1a\\n# YAML VERSION - Generated from helm template' "$output_script"
    
    # Add embedded YAML at the end
    cat >> "$output_script" << 'EOF'

# ==============================
# EMBEDDED YAML CONTENT
# ==============================
EMBEDDED_YAML=$(cat << 'YAML_EOF'
YAML_CONTENT_PLACEHOLDER
YAML_EOF
)

# Override install function to use embedded YAML
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
}

# Update main function for YAML version
main() {
    local force_reinstall="${1:-false}"
    
    # All existing logic for:
    # - Kubernetes environment detection
    # - Lock acquisition
    # - Error handling
    # - Logging
    
    # Use embedded YAML instead of Helm
    if acquire_lock; then
        install_with_embedded_yaml "$force_reinstall"
        kubectl delete configmap "$LOCK_NAME" -n "$LOCK_NAMESPACE" &>/dev/null || true
    else
        info "Could not acquire lock. Another installation may be in progress."
    fi
}
EOF
    
    # Replace placeholder with actual YAML (escape for sed)
    local escaped_yaml=$(echo "$yaml_content" | sed 's/[[\.*^$()+?{|\\]/\\&/g')
    sed -i "s/YAML_CONTENT_PLACEHOLDER/$escaped_yaml/" "$output_script"
    
    chmod +x "$output_script"
    
    info "Successfully generated: $output_script"
    info "Usage: ./$output_script <FORCE_REINSTALL>"
}
```

#### Generated Script Characteristics
The generated `car_install_qualys_container_sensor_k8s_yaml.sh` will:

1. **Remove HELM_ARGS parameter** - Not needed for YAML version
2. **Add embedded YAML** - Complete Kubernetes manifests as heredoc
3. **Override install functions** - Use kubectl instead of helm
4. **Preserve all other logic** - Locking, FORCE_REINSTALL parameter, error handling
5. **Self-contained** - No external dependencies except kubectl

#### Usage Examples
```bash
# Generate YAML version from values file
./car_install_qualys_container_sensor_k8s.sh \
  "-f /path/to/values.yaml" \
  "false" \
  "generate"

# Generate YAML version from --set parameters  
./car_install_qualys_container_sensor_k8s.sh \
  "--set global.customerId=xxx --set global.activationId=yyy" \
  "false" \
  "generate"

# Use generated YAML version (no Helm required)
./car_install_qualys_container_sensor_k8s_yaml.sh false    # Install/upgrade mode
./car_install_qualys_container_sensor_k8s_yaml.sh true     # Force reinstall mode
```

### Logging Standards

#### Common Logging Functions
```bash
# Linux/Kubernetes (bash)
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
```

```powershell
# Windows (PowerShell)
function Write-Info {
    param([string]$Message)
    $Message -split "`n" | ForEach-Object {
        Write-Host "[INFO] $_" -ForegroundColor Green
    }
}

function Write-Error-Message {
    param([string]$Message)
    $Message -split "`n" | ForEach-Object {
        Write-Host "[ERROR] $_" -ForegroundColor Red
    }
}

function Write-Warning {
    param([string]$Message)
    $Message -split "`n" | ForEach-Object {
        Write-Host "[WARNING] $_" -ForegroundColor Yellow
    }
}
```

#### Log Message Format
- **Prefix all messages** with severity level: `[INFO]`, `[ERROR]`, `[WARNING]`
- **Support multi-line messages** with proper formatting
- **Use consistent terminology** across platforms
- **Include contextual information** (runtime, mode, etc.)

### Return Code Definitions

**Unified return codes for all scripts (0-255 range):**

#### Core Return Codes (0-9)
- `0` - Complete success (all deployments successful)
- `1` - User error (invalid parameters, help requested)
- `2` - System error (missing dependencies, permissions, no runtimes found)
- `3` - Container runtime error (Docker/Podman communication issues)
- `4` - Network error (download failures, API errors, connection issues)
- `5` - Installation/deployment error (sensor installation failures)
- `6` - Partial success (multi-deployment scenarios - some deployments succeeded, some failed)
- `7` - Action not needed (container up to date, already exists per FORCE_REINSTALL logic)
- `8` - Configuration error (missing required files, invalid configuration)
- `9` - Reserved for future use

#### Platform-Specific Error Codes
**Linux-specific (10-19):**
- `10` - tar.xz extraction error
- `11` - tar.xz download error
- `12` - Installer script execution error
- `13` - sudo/permission error
- `14` - Storage directory creation error

**Windows-specific (20-29):**
- `20` - PowerShell version incompatibility
- `21` - WSL2 not available or not configured
- `22` - Windows socket/pipe connection error
- `23` - WSL distribution execution error
- `24` - Multi-deployment tracking error

**Kubernetes-specific (30-39):**
- `30` - kubectl not available or not configured
- `31` - Helm not available (when required)
- `32` - Lock acquisition timeout
- `33` - Namespace creation error
- `34` - YAML manifest application error
- `35` - Helm chart installation/upgrade error

#### Return Code Guidelines
1. **Exit immediately on error** - Don't continue after critical failures
2. **Use specific codes** - Help CAR and users identify issues quickly
3. **Log before exiting** - Always log the error reason before exit
4. **Document in help** - Include return codes in script help output

### Deployment Summary Format

All scripts must provide a standardized deployment summary before exiting:

#### Standard Deployment Summary

**Linux Single Runtime Example:**
```
========================================
Deployment Summary:
========================================
Mode: Install/Upgrade
Target: Docker on Linux
Location: dockerhub
Status: SUCCESS - Installed

Container: qualys-container-sensor
State: Running
Version: sha256:abc123... (latest)
========================================
Exit code: 0
```

**Linux Multi-Runtime Example:**
```
========================================
Deployment Summary:
========================================
Mode: Install/Upgrade
Detected runtimes: 2

✓ Docker: SUCCESS - Upgraded
✓ Podman: SUCCESS - Installed

Total: 2/2 deployments successful
========================================
Exit code: 0
```

#### Multi-Deployment Summary (Windows)
```
========================================
Deployment Summary:
========================================
Mode: Force Reinstall
Detected environments: 4

✓ Windows Docker Desktop: SUCCESS - Reinstalled
✓ Windows Podman: SKIPPED - Not found
✓ WSL2 Docker (Ubuntu): SUCCESS - Reinstalled
✗ WSL2 Docker (Debian): FAILED - Network error
✓ WSL2 Podman (Ubuntu): SUCCESS - Reinstalled

Total: 3/3 deployments successful (1 skipped)
========================================
Exit code: 0
```

#### Summary Components
1. **Header/Footer** - Clear visual separation
2. **Mode** - "Install/Upgrade" or "Force Reinstall" based on FORCE_REINSTALL parameter
3. **Target Details** - Where deployment occurred
4. **Status** - SUCCESS/FAILED/SKIPPED with reason
5. **Statistics** - X/Y successful for multi-deployment
6. **Exit Code** - Actual return code for CAR

#### Status Values
- **SUCCESS** - Deployment completed successfully
- **FAILED** - Deployment attempted but failed (show error)
- **SKIPPED** - Not attempted due to FORCE_REINSTALL logic or not found
- **UPGRADED** - Successfully upgraded (when FORCE_REINSTALL=false)
- **UP-TO-DATE** - No action needed, already current

### Container Existence Detection

#### Common Detection Logic
```bash
container_exists() {
    local container_name="${1:-qualys-container-sensor}"
    local runtime="${2:-docker}"
    
    if $runtime ps -a --filter "name=$container_name" --format '{{.ID}}' | grep -q .; then
        return 0  # Container exists
    else
        return 1  # Container does not exist
    fi
}
```

#### Container State Verification
```bash
container_running() {
    local container_name="${1:-qualys-container-sensor}"
    local runtime="${2:-docker}"
    
    local status=$($runtime inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null)
    if [[ "$status" == "true" ]]; then
        return 0  # Running
    else
        return 1  # Not running
    fi
}
```

## Implementation Details

### Common Functions Needed

#### 1. Installation Decision Logic
```bash
check_and_decide_installation() {
    local force_reinstall="$1"
    local container_name="$2"
    local location="$3"
    
    local container_exists=false
    local is_outdated=false
    
    # Check container existence
    if container_exists "$container_name"; then
        container_exists=true
        info "Existing sensor container found"
        
        # Check if outdated (Docker Hub only)
        if [[ "$location" == "dockerhub" ]]; then
            if check_container_version "$container_name"; then
                is_outdated=true
                info "Container is outdated"
            else
                info "Container is up to date"
            fi
        fi
    else
        info "No existing sensor container found"
    fi
    
    # Decide based on force_reinstall parameter
    if [[ "$force_reinstall" == "true" ]]; then
        if $container_exists; then
            info "Force reinstall requested - removing existing container..."
            remove_existing_container "$container_name"
        fi
        return 0  # Always proceed with installation
    else
        # Default behavior: install if missing, upgrade if outdated
        if ! $container_exists; then
            info "Installing new container..."
            return 0  # Proceed with installation
        elif [[ "$location" == "dockerhub" ]] && $is_outdated; then
            info "Upgrading outdated container..."
            return 0  # Proceed with upgrade
        else
            info "Container exists and is up to date - no action needed."
            return 1  # Skip installation
        fi
    fi
}
```

#### 2. Container Removal Logic
```bash
remove_existing_container() {
    local container_name="$1"
    local runtime="${2:-docker}"
    
    info "Stopping and removing existing container: $container_name"
    
    # Stop if running
    if container_running "$container_name" "$runtime"; then
        $runtime stop "$container_name" >/dev/null 2>&1
    fi
    
    # Remove container
    $runtime rm -f "$container_name" >/dev/null 2>&1
    
    info "Existing container removed successfully"
}
```

#### 3. Installation Verification
```bash
verify_installation() {
    local container_name="$1"
    local runtime="${2:-docker}"
    local timeout="${3:-30}"
    
    info "Verifying installation..."
    
    # Wait for container to be running
    local count=0
    while ! container_running "$container_name" "$runtime"; do
        if [[ $count -ge $timeout ]]; then
            error "Container failed to start within $timeout seconds"
            return 1
        fi
        sleep 1
        ((count++))
    done
    
    info "Container is running successfully"
    return 0
}
```

### Platform-Specific Implementation

#### Linux Script Enhancements
**Current state:** Complete and working
**Required changes:**
1. **MAJOR CHANGE**: Remove restriction against both Docker and Podman being present
2. Implement multi-deployment to both runtimes when present
3. Add deployment tracking and summary reporting
4. Implement version checking for Docker Hub installations
5. Standardize logging and return codes with new unified system
6. Add common functions

**Key considerations:**
- Multi-deployment model (deploy to ALL container runtimes found)
- Deploy to both Docker and Podman if both are present
- Track each deployment separately
- Maintain tar.xz extraction functionality
- Keep sudo usage patterns
- Return appropriate code (0=all success, 6=partial success, other=failure)

#### Windows Script Enhancements  
**Current state:** Basic Docker Hub support only
**Required changes:**
1. Add tar.xz installation support (from historical scripts)
2. Replace ACTION with FORCE_REINSTALL parameter
3. Add version checking capability
4. Standardize logging and return codes
5. Improve Windows-specific socket handling

**Key considerations:**
- Windows socket paths: `\\.\pipe\docker_engine` vs `\\.\pipe\podman-machine-default`
- PowerShell error handling with `$ErrorActionPreference`
- Windows-specific storage paths: `C:\ProgramData\Qualys\sensor\data`
- Optional WSL integration support
- Windows tar.xz extraction (Windows 10 1803+)

**Historical script integration:**
- Use tar.xz extraction logic from `car_install_qualys_container_sensor_multi_windows.ps1`
- Preserve fallback mechanisms (tar.xz → Docker Hub)
- Maintain proper error handling patterns

**Multi-deployment strategy:**
- Detect ALL container runtime instances (Windows host + WSL2)
- Deploy to every instance found automatically
- Track each deployment separately
- Return appropriate code (0=all success, 6=partial success, other=failure)
- No user interaction required - fully automated

**Windows deployment targets:**
1. Docker Desktop on Windows host (via `\\.\pipe\docker_engine`)
2. Podman Desktop on Windows host (via `\\.\pipe\podman-machine-default`)
3. Docker in each WSL2 distribution
4. Podman in each WSL2 distribution

#### Kubernetes Script Enhancement
**Current state:** Advanced with ConfigMap locking
**Required changes:**
1. Add self-cloning capability for environments without Helm
2. Replace ACTION with FORCE_REINSTALL parameter
3. Add embedded YAML deployment function
4. Standardize logging format to match other scripts
5. Align return code definitions
6. Preserve existing Helm functionality

**Key considerations:**
- Preserve ConfigMap locking mechanism for both Helm and YAML modes
- Maintain CronJob cleanup functionality
- Keep Helm repository management for Helm mode
- Preserve cluster-wide installation logic
- Support dual-mode operation (Helm when available, YAML when not)
- UI-friendly positional parameters (no dash-style flags)

### Error Handling Patterns

#### Network Error Handling
```bash
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts="${3:-3}"
    local delay="${4:-5}"
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if curl -s -S -o "$output" "$url"; then
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            warning "Download failed (attempt $attempt/$max_attempts). Retrying in $delay seconds..."
            sleep $delay
        fi
        ((attempt++))
    done
    
    error "Download failed after $max_attempts attempts"
    return 4
}
```

#### Runtime Detection Error Handling
```bash
detect_runtime() {
    local runtime=""
    local docker_available=false
    local podman_available=false
    
    # Check Docker
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        docker_available=true
    fi
    
    # Check Podman
    if command -v podman &>/dev/null && podman info &>/dev/null; then
        podman_available=true
    fi
    
    # Validate runtime selection
    if $docker_available && $podman_available; then
        error "Both Docker and Podman are available. Please stop one service."
        return 3
    elif $docker_available; then
        runtime="docker"
    elif $podman_available; then
        runtime="podman"
    else
        error "No container runtime (Docker or Podman) detected."
        return 2
    fi
    
    info "Detected container runtime: $runtime"
    echo "$runtime"
    return 0
}
```

### Upgrade Logic Flow

#### For Docker Hub Installations
```bash
perform_upgrade() {
    local container_name="$1"
    local runtime="$2"
    local activation_id="$3"
    local customer_id="$4"
    local pod_url="$5"
    local install_options="$6"
    
    info "Starting upgrade process..."
    
    # Verify upgrade is needed
    if ! check_container_version "$container_name"; then
        info "Container is already up to date"
        return 0
    fi
    
    # Pull latest image
    info "Pulling latest sensor image..."
    if ! $runtime pull qualys/qcs-sensor:latest; then
        error "Failed to pull latest image"
        return 4
    fi
    
    # Stop existing container
    info "Stopping existing container..."
    if container_running "$container_name" "$runtime"; then
        $runtime stop "$container_name"
    fi
    
    # Remove existing container
    $runtime rm -f "$container_name"
    
    # Start new container with same configuration
    info "Starting updated container..."
    start_container "$container_name" "$runtime" "$activation_id" "$customer_id" "$pod_url" "$install_options"
    
    # Verify new container
    if verify_installation "$container_name" "$runtime"; then
        info "Upgrade completed successfully"
        return 0
    else
        error "Upgrade verification failed"
        return 6
    fi
}
```

#### For Tar.xz Installations
```bash
# Tar.xz installations are self-updating
# No manual upgrade logic needed
info "Tar.xz installations are self-updating. No manual upgrade required."
```

## Testing Strategy

### Test Scenarios

#### Force Reinstall Testing
For each script, test both FORCE_REINSTALL values:

1. **FORCE_REINSTALL=false** (default):
   - ✅ Install when no container exists
   - ✅ Upgrade when container exists and is outdated (Docker Hub only)
   - ✅ Skip when container exists and is up to date
   - ✅ Skip upgrade for tar.xz installations (self-updating)
   - ✅ Proper error handling for missing dependencies

2. **FORCE_REINSTALL=true**:
   - ✅ Remove and reinstall when container exists
   - ✅ Install when no container exists  
   - ✅ Force installation regardless of version
   - ✅ Works for both Docker Hub and tar.xz installations

#### Version Checking Testing
- ✅ Correct detection of outdated containers
- ✅ Proper handling of network errors
- ✅ No consumption of Docker Hub pull credits
- ✅ Fallback mechanisms for API failures

#### Platform-Specific Testing

**Linux:**
- ✅ Docker and Podman runtime detection
- ✅ Tar.xz extraction and installation
- ✅ Docker Hub installation
- ✅ Proper socket mounting

**Windows:**
- ✅ Docker Desktop and Podman detection
- ✅ Windows socket path handling
- ✅ Tar.xz extraction (Windows 10 1803+)
- ✅ PowerShell error handling
- ✅ WSL integration (if implemented)

**Kubernetes:**
- ✅ Helm chart installation
- ✅ ConfigMap locking mechanism
- ✅ CronJob cleanup functionality
- ✅ Multi-node deployment scenarios

#### Error Condition Testing
- ✅ Network connectivity issues
- ✅ Permission errors
- ✅ Invalid parameters
- ✅ Container runtime unavailable
- ✅ Disk space issues
- ✅ Corrupted download files

### Validation Criteria

#### Functional Validation
- Both FORCE_REINSTALL modes work correctly
- Version checking operates without pull credits
- Container upgrades preserve functionality
- Installation verification works reliably

#### Cross-Platform Consistency
- Identical parameter structure
- Consistent logging format
- Same return code meanings
- Equivalent error handling

#### Performance Validation
- Fast execution times
- Minimal network calls
- Efficient resource usage
- Proper cleanup on failures

## Future Enhancements

### Potential Improvements
1. **Configuration file support** - Store parameters in config files
2. **Batch deployment** - Deploy to multiple targets
3. **Health monitoring** - Periodic sensor health checks
4. **Rollback capability** - Revert to previous version on failures
5. **Metrics collection** - Track deployment success rates
6. **Container orchestration** - Better integration with Docker Compose/Swarm

### Kubernetes Enhancements
1. **Self-cloning script capability** - Generate YAML version for environments without Helm ✅
2. **DaemonSet consideration** - Evaluate vs CAR-based deployment
3. **Node labeling** - Track deployment status via node labels
4. **Namespace isolation** - Support for multiple Qualys tenants
5. **Values file support** - Support both -f values.yaml and --set parameters

### Windows Enhancements
1. **Windows Server support** - Docker EE compatibility
2. **Service registration** - Windows service integration
3. **Event log integration** - Windows event log support
4. **Group Policy support** - Enterprise deployment scenarios

## Implementation Timeline

### Phase 1: Foundation (Priority: High)
- ✅ Create this documentation
- ✅ Implement common functions
- ✅ Standardize logging across scripts
- ✅ Define return code standards

### Phase 2: Linux Script (Priority: High)
- ✅ Replace ACTION with FORCE_REINSTALL parameter
- ✅ Implement version checking
- ✅ Update help documentation
- ✅ Add comprehensive testing

### Phase 3: Windows Script (Priority: High)  
- ✅ Add tar.xz installation support
- ✅ Replace ACTION with FORCE_REINSTALL parameter
- ✅ Add version checking capability
- ✅ Standardize with other scripts

### Phase 4: Kubernetes Script (Priority: High)
- ✅ Add self-cloning capability
- ✅ Replace ACTION with FORCE_REINSTALL parameter
- ✅ Add embedded YAML deployment function
- ✅ Align logging and return codes
- ✅ Preserve Helm functionality for dual-mode operation
- ✅ Update documentation

### Phase 5: Integration Testing (Priority: High)
- ✅ Cross-platform testing
- ✅ End-to-end scenario validation
- ✅ Performance testing
- ✅ Documentation updates

## Conclusion

This implementation plan provides a comprehensive roadmap for enhancing the Qualys Container Sensor CAR scripts with:

- **Simplified FORCE_REINSTALL parameter** replacing complex ACTION modes
- **Intelligent default behavior** that handles both install and upgrade automatically
- **Intelligent version checking** without Docker Hub pull credit consumption
- **Consistent cross-platform behavior** with standardized logging and error codes
- **Robust error handling** and upgrade capabilities
- **Thorough testing strategy** to ensure reliability

The plan simplifies the user experience by providing just two clear behaviors: intelligent install/upgrade (default) or force reinstall, making the scripts more intuitive and suitable for production environments.