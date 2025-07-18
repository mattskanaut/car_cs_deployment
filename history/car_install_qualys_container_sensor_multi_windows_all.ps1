# PowerShell script to install Qualys Container Sensor on Windows
# Deploys to ALL detected environments: Docker/Podman on Windows host AND Docker/Podman in WSL

# Exit on errors
$ErrorActionPreference = "Stop"

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

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$LOCATION,          # Download location for QualysContainerSensor.tar.xz installer, or enter "dockerhub" to pull sensor from docker
    
    [Parameter(Mandatory=$true, Position=1)]
    [string]$ACTIVATIONID,      # Activation ID
    
    [Parameter(Mandatory=$true, Position=2)]
    [string]$CUSTOMERID,        # Customer ID
    
    [Parameter(Mandatory=$true, Position=3)]
    [string]$POD_URL,           # Required for install from docker hub, NONE if not required
    
    [Parameter(Mandatory=$true, Position=4)]
    [string]$INSTALL_OPTIONS,   # Additional sensor install options, e.g. --registry-sensor, NONE if not required
    
    [Parameter(Mandatory=$true, Position=5)]
    [string]$FORCE_REINSTALL    # Force a reinstall if the sensor is already deployed true|false
)

# ==============================
# Script starts here
# ==============================

# Embedded bash script for WSL execution
$bashScript = @'
#!/bin/bash

# Exit on undefined variables and errors
set -eu

# Parameters passed from PowerShell
LOCATION="$1"
ACTIVATIONID="$2"
CUSTOMERID="$3"
POD_URL="$4"
INSTALL_OPTIONS="$5"
FORCE_REINSTALL="$6"
RUNTIME="$7"

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

# Function to check for existing instances
check_existing() {
  info "Checking for existing qualys-container-sensor instances in WSL $RUNTIME..."

  # Check if any container using the qualys/sensor image is running
  if $RUNTIME ps --filter "ancestor=qualys/sensor" --format '{{.ID}}' 2>/dev/null | grep -q '.'; then
    if [[ "$FORCE_REINSTALL" == "true" ]]; then
      info "Existing instance found. FORCE_REINSTALL is true. Removing the existing container..."
      $RUNTIME ps --filter "ancestor=qualys/sensor" --format '{{.ID}}' | xargs -r $RUNTIME rm -f
    else
      error "Existing instance found. FORCE_REINSTALL is set to false. Skipping WSL $RUNTIME installation."
      exit 0
    fi
  else
    info "No existing instances found. Proceeding with installation..."
  fi
}

# Function to handle installation from tar.xz
install_from_tar() {
  info "Downloading tar.xz file from $LOCATION..."
  curl -s -S -o /tmp/QualysContainerSensor.tar.xz "$LOCATION"

  if [ $? -ne 0 ]; then
    error "Failed to download the tar.xz file. Exiting."
    exit 11
  fi

  info "Extracting tar.xz file..."
  mkdir -p ~/qualys_container_sensor_installer
  if tar -xf /tmp/QualysContainerSensor.tar.xz -C ~/qualys_container_sensor_installer; then
    info "Extraction successful."
  else
    error "Failed to extract the tar.xz file. Exiting."
    exit 12
  fi

  # Create the storage directory if it doesn't exist
  info "Creating storage directory /usr/local/qualys/sensor/data..."
  sudo mkdir -p /usr/local/qualys/sensor/data
  
  info "Running sensor installation script..."
  
  # Build install command with runtime-specific options
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

  # Create data directory
  sudo mkdir -p /usr/local/qualys/sensor/data

  # Run container
  CONTAINER_ID=$(sudo $RUNTIME run -d --restart on-failure \
    $SOCKET_MOUNT \
    -v /usr/local/qualys/sensor/data:/usr/local/qualys/qpa/data \
    -e ACTIVATIONID="$ACTIVATIONID" \
    -e CUSTOMERID="$CUSTOMERID" \
    -e POD_URL="$POD_URL" \
    --net=host --name qualys-container-sensor-wsl qualys/qcs-sensor:latest \
    --perform-sca-scan $([ "$INSTALL_OPTIONS" != "NONE" ] && echo "$INSTALL_OPTIONS") 2>&1)

  # Check if the run command succeeded
  if [[ $? -ne 0 ]]; then
    error "Failed to start the Qualys container. $RUNTIME error: $CONTAINER_ID"
    exit 24
  fi

  info "Container started with ID: $CONTAINER_ID"

  # Validate that the container is running
  sleep 5
  RUNNING_STATUS=$(sudo $RUNTIME inspect -f '{{.State.Running}}' qualys-container-sensor-wsl 2>/dev/null)
  if [[ "$RUNNING_STATUS" != "true" ]]; then
    error "Container did not start successfully."
    error "Check the container logs for details:"
    sudo $RUNTIME logs qualys-container-sensor-wsl
    exit 25
  fi

  info "Qualys container sensor installed and running successfully in WSL."
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

info "WSL installation completed successfully."
'@

# Function to print help
function Show-Help {
    Write-Host "This script installs the Qualys Container Sensor on ALL detected Windows environments."
    Write-Host "It will deploy to:"
    Write-Host "  - Docker Desktop on Windows (if found)"
    Write-Host "  - Podman on Windows (if found)"
    Write-Host "  - Docker in WSL (if found)"
    Write-Host "  - Podman in WSL (if found)"
    Write-Host ""
    Write-Host "Usage: .\$($MyInvocation.MyCommand.Name) <LOCATION> <ACTIVATIONID> <CUSTOMERID> <POD_URL> <INSTALL_OPTIONS> <FORCE_REINSTALL>"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  LOCATION        - Path to tar.xz file or 'dockerhub' for Dockerhub"
    Write-Host "  ACTIVATIONID    - Your Qualys ActivationID"
    Write-Host "  CUSTOMERID      - Your Qualys CustomerID"
    Write-Host "  POD_URL         - POD URL (required for Dockerhub only, use 'NONE' for tar.xz install)"
    Write-Host "  INSTALL_OPTIONS - Additional sensor install options (use 'NONE' if not needed)"
    Write-Host "  FORCE_REINSTALL - Force reinstall if sensor exists (true/false)"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  # Install from tar.xz without additional options:"
    Write-Host "  .\$($MyInvocation.MyCommand.Name) 's3://bucket/QualysContainerSensor.tar.xz' 'activation-id' 'customer-id' NONE NONE true"
    Write-Host ""
    Write-Host "  # Install from Dockerhub with registry sensor option:"
    Write-Host "  .\$($MyInvocation.MyCommand.Name) 'dockerhub' 'activation-id' 'customer-id' 'https://pod.url' '--registry-sensor' false"
}

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

# Show help if requested
if ($LOCATION -eq "-h" -or $LOCATION -eq "--help" -or $LOCATION -eq "/?") {
    Show-Help
    exit 0
}

# Validate mandatory variables
if (-not $LOCATION -or -not $ACTIVATIONID -or -not $CUSTOMERID) {
    Write-Error-Message "LOCATION, ACTIVATIONID, and CUSTOMERID must be provided."
    Show-Help
    exit 1
}

# Convert FORCE_REINSTALL to boolean
$FORCE_REINSTALL_BOOL = $false
if ($FORCE_REINSTALL -eq "true") {
    $FORCE_REINSTALL_BOOL = $true
}

# Track installation results
$installationResults = @()

# ==============================
# Check Windows Host Runtimes
# ==============================

Write-Info "=== Checking for container runtimes on Windows host ==="

# Check for Docker Desktop
$dockerExists = $false
try {
    $null = docker version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $dockerExists = $true
        Write-Info "Found Docker Desktop on Windows host"
    }
} catch {
    $dockerExists = $false
}

# Check for Podman
$podmanExists = $false
try {
    $null = podman version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $podmanExists = $true
        Write-Info "Found Podman on Windows host"
    }
} catch {
    $podmanExists = $false
}

# ==============================
# Check WSL Distributions
# ==============================

Write-Info "=== Checking for WSL distributions ==="

$wslDistros = @()
try {
    $wslOutput = wsl --list --quiet 2>$null
    if ($LASTEXITCODE -eq 0 -and $wslOutput) {
        $wslDistros = $wslOutput | Where-Object { $_ -and $_ -notmatch '^\s*$' }
        Write-Info "Found WSL distributions: $($wslDistros -join ', ')"
    } else {
        Write-Info "No WSL distributions found"
    }
} catch {
    Write-Info "WSL not available on this system"
}

# ==============================
# Windows Host Installation Functions
# ==============================

function Test-ExistingWindowsInstances {
    param([string]$Runtime)
    
    Write-Info "Checking for existing qualys-container-sensor instances on Windows $Runtime..."
    
    $existingContainers = & $Runtime ps --filter "ancestor=qualys/sensor" --format '{{.ID}}' 2>$null
    
    if ($existingContainers) {
        if ($FORCE_REINSTALL_BOOL -eq $true) {
            Write-Info "Existing instance found. FORCE_REINSTALL is true. Removing the existing container..."
            $existingContainers | ForEach-Object {
                & $Runtime rm -f $_ 2>$null
            }
            return $true
        } else {
            Write-Warning "Existing instance found on Windows $Runtime. FORCE_REINSTALL is false. Skipping."
            return $false
        }
    } else {
        Write-Info "No existing instances found. Proceeding with installation..."
        return $true
    }
}

function Install-WindowsFromTar {
    param([string]$Runtime)
    
    Write-Info "Downloading tar.xz file for Windows $Runtime..."
    
    try {
        Invoke-WebRequest -Uri $LOCATION -OutFile "QualysContainerSensor.tar.xz" -UseBasicParsing
    } catch {
        Write-Error-Message "Failed to download the tar.xz file. Error: $_"
        return $false
    }
    
    Write-Info "Extracting tar.xz file..."
    $installerPath = "$env:USERPROFILE\qualys_container_sensor_installer"
    
    if (-not (Test-Path $installerPath)) {
        New-Item -ItemType Directory -Path $installerPath -Force | Out-Null
    }
    
    try {
        tar -xf QualysContainerSensor.tar.xz -C $installerPath
        Write-Info "Extraction successful."
    } catch {
        Write-Error-Message "Failed to extract tar.xz file. Ensure tar is available (Windows 10 1803+)"
        Write-Info "Falling back to Dockerhub method..."
        return Install-WindowsFromDockerhub -Runtime $Runtime
    }
    
    $storageDir = "C:\ProgramData\Qualys\sensor\data"
    Write-Info "Creating storage directory $storageDir..."
    if (-not (Test-Path $storageDir)) {
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
    }
    
    # Check if PowerShell install script exists
    $installScriptPath = "$installerPath\installsensor.ps1"
    if (-not (Test-Path $installScriptPath)) {
        Write-Warning "PowerShell installer not found. Falling back to Dockerhub method..."
        return Install-WindowsFromDockerhub -Runtime $Runtime
    }
    
    $installArgs = @(
        "ActivationId=$ACTIVATIONID",
        "CustomerId=$CUSTOMERID",
        "Storage=$storageDir",
        "-s",
        "--perform-sca-scan"
    )
    
    if ($Runtime -eq "podman") {
        $installArgs += "ContainerRuntime=podman"
        $installArgs += "StorageDriverType=overlay"
    } else {
        $installArgs += "StorageDriverType=overlay2"
    }
    
    if ($INSTALL_OPTIONS -ne "NONE") {
        $installArgs += $INSTALL_OPTIONS -split " "
    }
    
    Write-Info "Executing installation script..."
    
    try {
        & $installScriptPath @installArgs
        Write-Info "Sensor installation completed successfully on Windows $Runtime."
        return $true
    } catch {
        Write-Error-Message "Sensor installation failed. Error: $_"
        return $false
    }
}

function Install-WindowsFromDockerhub {
    param([string]$Runtime)
    
    if ($POD_URL -eq "NONE" -or -not $POD_URL) {
        Write-Error-Message "POD_URL must be set when using Dockerhub."
        return $false
    }
    
    Write-Info "Installing from Dockerhub on Windows $Runtime..."
    
    $volumeMounts = @()
    if ($Runtime -eq "podman") {
        $volumeMounts += "-v", "\\.\pipe\podman-machine-default:/var/run/docker.sock:ro"
    } else {
        $volumeMounts += "-v", "\\.\pipe\docker_engine:/var/run/docker.sock:ro"
    }
    
    $dataPath = "C:\ProgramData\Qualys\sensor\data"
    if (-not (Test-Path $dataPath)) {
        New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
    }
    $volumeMounts += "-v", "${dataPath}:/usr/local/qualys/qpa/data"
    
    $containerName = "qualys-container-sensor-win-$Runtime"
    
    $runArgs = @(
        "run", "-d", "--restart", "on-failure"
    ) + $volumeMounts + @(
        "-e", "ACTIVATIONID=$ACTIVATIONID",
        "-e", "CUSTOMERID=$CUSTOMERID",
        "-e", "POD_URL=$POD_URL",
        "--net=host",
        "--name", $containerName,
        "qualys/qcs-sensor:latest",
        "--perform-sca-scan"
    )
    
    if ($INSTALL_OPTIONS -ne "NONE") {
        $runArgs += $INSTALL_OPTIONS -split " "
    }
    
    try {
        Write-Info "Starting container..."
        $containerId = & $Runtime @runArgs 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Container failed to start: $containerId"
        }
        
        Start-Sleep -Seconds 5
        
        $runningStatus = & $Runtime inspect -f '{{.State.Running}}' $containerName 2>$null
        if ($runningStatus -ne "true") {
            Write-Error-Message "Container did not start successfully."
            & $Runtime logs $containerName
            return $false
        }
        
        Write-Info "Qualys container sensor installed successfully on Windows $Runtime."
        return $true
    } catch {
        Write-Error-Message "Failed to start container. Error: $_"
        return $false
    }
}

# ==============================
# Install on Windows Host
# ==============================

if ($dockerExists) {
    Write-Info ""
    Write-Info "=== Installing on Docker Desktop (Windows) ==="
    if (Test-ExistingWindowsInstances -Runtime "docker") {
        if ($LOCATION.ToLower() -eq "dockerhub") {
            $result = Install-WindowsFromDockerhub -Runtime "docker"
        } else {
            $result = Install-WindowsFromTar -Runtime "docker"
        }
        $installationResults += @{Runtime="Docker Desktop (Windows)"; Success=$result}
    } else {
        $installationResults += @{Runtime="Docker Desktop (Windows)"; Success=$false; Reason="Existing installation, FORCE_REINSTALL=false"}
    }
}

if ($podmanExists) {
    Write-Info ""
    Write-Info "=== Installing on Podman (Windows) ==="
    if (Test-ExistingWindowsInstances -Runtime "podman") {
        if ($LOCATION.ToLower() -eq "dockerhub") {
            $result = Install-WindowsFromDockerhub -Runtime "podman"
        } else {
            $result = Install-WindowsFromTar -Runtime "podman"
        }
        $installationResults += @{Runtime="Podman (Windows)"; Success=$result}
    } else {
        $installationResults += @{Runtime="Podman (Windows)"; Success=$false; Reason="Existing installation, FORCE_REINSTALL=false"}
    }
}

# ==============================
# Install in WSL Distributions
# ==============================

if ($wslDistros.Count -gt 0) {
    # Save the bash script to a temporary file
    $tempScriptPath = "$env:TEMP\qualys_wsl_install.sh"
    $bashScript | Out-File -FilePath $tempScriptPath -Encoding UTF8 -NoNewline
    
    # Convert Windows path to WSL path
    $wslScriptPath = "/mnt/c" + $tempScriptPath.Replace("C:", "").Replace("\", "/")
    
    foreach ($distro in $wslDistros) {
        $distro = $distro.Trim()
        if (-not $distro) { continue }
        
        Write-Info ""
        Write-Info "=== Checking WSL distribution: $distro ==="
        
        # Check for Docker in WSL
        try {
            $dockerCheck = wsl -d $distro -- which docker 2>$null
            if ($LASTEXITCODE -eq 0 -and $dockerCheck) {
                Write-Info "Found Docker in WSL distribution: $distro"
                Write-Info "Installing Qualys sensor on Docker in $distro..."
                
                $wslResult = wsl -d $distro -- bash $wslScriptPath "$LOCATION" "$ACTIVATIONID" "$CUSTOMERID" "$POD_URL" "$INSTALL_OPTIONS" "$FORCE_REINSTALL" "docker"
                $success = $LASTEXITCODE -eq 0
                $installationResults += @{Runtime="Docker in WSL ($distro)"; Success=$success}
            }
        } catch {
            Write-Warning "Could not check for Docker in $distro"
        }
        
        # Check for Podman in WSL
        try {
            $podmanCheck = wsl -d $distro -- which podman 2>$null
            if ($LASTEXITCODE -eq 0 -and $podmanCheck) {
                Write-Info "Found Podman in WSL distribution: $distro"
                Write-Info "Installing Qualys sensor on Podman in $distro..."
                
                $wslResult = wsl -d $distro -- bash $wslScriptPath "$LOCATION" "$ACTIVATIONID" "$CUSTOMERID" "$POD_URL" "$INSTALL_OPTIONS" "$FORCE_REINSTALL" "podman"
                $success = $LASTEXITCODE -eq 0
                $installationResults += @{Runtime="Podman in WSL ($distro)"; Success=$success}
            }
        } catch {
            Write-Warning "Could not check for Podman in $distro"
        }
    }
    
    # Clean up temporary script
    Remove-Item -Path $tempScriptPath -Force -ErrorAction SilentlyContinue
}

# ==============================
# Summary
# ==============================

Write-Info ""
Write-Info "========================================"
Write-Info "Installation Summary:"
Write-Info "========================================"

if ($installationResults.Count -eq 0) {
    Write-Warning "No container runtimes found on this system!"
    Write-Warning "Please install Docker Desktop, Podman, or set up WSL with Docker/Podman."
    exit 1
}

$successCount = 0
foreach ($result in $installationResults) {
    if ($result.Success) {
        Write-Info "✓ $($result.Runtime): SUCCESS"
        $successCount++
    } else {
        if ($result.Reason) {
            Write-Warning "✗ $($result.Runtime): SKIPPED - $($result.Reason)"
        } else {
            Write-Error-Message "✗ $($result.Runtime): FAILED"
        }
    }
}

Write-Info ""
Write-Info "Total successful installations: $successCount out of $($installationResults.Count) detected environments"

if ($successCount -eq 0) {
    Write-Error-Message "No installations succeeded!"
    exit 1
} else {
    Write-Info "Installation process completed."
    exit 0
}