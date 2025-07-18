# PowerShell script to install Qualys Container Sensor on Windows
# Supports Docker Desktop and Podman

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

# Function to print help
function Show-Help {
    Write-Host "This script installs the Qualys Container Sensor (Docker or Podman) on Windows."
    Write-Host ""
    Write-Host "Usage: .\$($MyInvocation.MyCommand.Name) <LOCATION> <ACTIVATIONID> <CUSTOMERID> <POD_URL> <INSTALL_OPTIONS> <FORCE_REINSTALL>"
    Write-Host ""
    Write-Host "Parameters:"
    Write-Host "  LOCATION        - Path to tar.xz file or 'dockerhub' for Dockerhub"
    Write-Host "  ACTIVATIONID    - Your Qualys ActivationID"
    Write-Host "  CUSTOMERID      - Your Qualys CustomerID"
    Write-Host "  POD_URL         - POD URL (required for Dockerhub only, use 'NONE' for tar.xz install)"
    Write-Host "  INSTALL_OPTIONS - Additional sensor install options (use 'NONE' if not needed)"
    Write-Host "  FORCE_REINSTALL - Force reinstall if sensor exists (true/false, defaults to true)"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  # Install from tar.xz without additional options:"
    Write-Host "  .\$($MyInvocation.MyCommand.Name) 's3://bucket/QualysContainerSensor.tar.xz' 'activation-id' 'customer-id' NONE NONE true"
    Write-Host ""
    Write-Host "  # Install from Dockerhub with registry sensor option:"
    Write-Host "  .\$($MyInvocation.MyCommand.Name) 'dockerhub' 'activation-id' 'customer-id' 'https://pod.url' '--registry-sensor' false"
    Write-Host ""
    Write-Host "Note: Use 'NONE' for optional parameters that are not needed."
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

# Detect container runtime
$RUNTIME = ""
$dockerExists = $false
$podmanExists = $false

# Check for Docker
try {
    $null = docker version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $dockerExists = $true
    }
} catch {
    $dockerExists = $false
}

# Check for Podman
try {
    $null = podman version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $podmanExists = $true
    }
} catch {
    $podmanExists = $false
}

if ($dockerExists -and $podmanExists) {
    Write-Error-Message "Both Docker and Podman are installed and running. Please stop one before proceeding."
    exit 2
} elseif ($dockerExists) {
    $RUNTIME = "docker"
    Write-Info "Detected Docker Desktop runtime"
} elseif ($podmanExists) {
    $RUNTIME = "podman"
    Write-Info "Detected Podman runtime"
} else {
    Write-Error-Message "No container runtime (Docker Desktop or Podman) detected or accessible."
    exit 2
}

# Function to check for existing instances
function Test-ExistingInstances {
    Write-Info "Checking for existing qualys-container-sensor instances..."
    
    # Check if any container using the qualys/sensor image is running
    $existingContainers = & $RUNTIME ps --filter "ancestor=qualys/sensor" --format '{{.ID}}' 2>$null
    
    if ($existingContainers) {
        if ($FORCE_REINSTALL_BOOL -eq $true) {
            Write-Info "Existing instance found. FORCE_REINSTALL is true. Removing the existing container..."
            $existingContainers | ForEach-Object {
                & $RUNTIME rm -f $_ 2>$null
            }
        } else {
            Write-Error-Message "Existing instance found. FORCE_REINSTALL is set to false. Exiting."
            exit 4
        }
    } else {
        Write-Info "No existing instances found. Proceeding with installation..."
    }
}

# Function to handle installation from tar.xz
function Install-FromTar {
    Write-Info "Downloading tar.xz file from $LOCATION..."
    
    # Download the file
    try {
        Invoke-WebRequest -Uri $LOCATION -OutFile "QualysContainerSensor.tar.xz" -UseBasicParsing
    } catch {
        Write-Error-Message "Failed to download the tar.xz file. Error: $_"
        exit 11
    }
    
    Write-Info "Download completed successfully."
    
    # Note: Windows doesn't have native tar.xz support in older versions
    # For Windows 10 1803+ and Windows Server 2019+, tar is available
    # Otherwise, users need to install 7-Zip or similar
    
    Write-Info "Extracting tar.xz file..."
    $installerPath = "$env:USERPROFILE\qualys_container_sensor_installer"
    
    # Create directory if it doesn't exist
    if (-not (Test-Path $installerPath)) {
        New-Item -ItemType Directory -Path $installerPath -Force | Out-Null
    }
    
    # Try to extract using tar (Windows 10 1803+)
    try {
        tar -xf QualysContainerSensor.tar.xz -C $installerPath
        Write-Info "Extraction successful."
    } catch {
        Write-Error-Message "Failed to extract tar.xz file. Ensure tar is available (Windows 10 1803+ or install 7-Zip)."
        Write-Error-Message "Alternatively, you can manually extract the file and run installsensor.ps1"
        exit 12
    }
    
    # Create the storage directory if it doesn't exist
    $storageDir = "C:\ProgramData\Qualys\sensor\data"
    Write-Info "Creating storage directory $storageDir..."
    if (-not (Test-Path $storageDir)) {
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
    }
    
    Write-Info "Running sensor installation script..."
    
    # Check if PowerShell install script exists
    $installScriptPath = "$installerPath\installsensor.ps1"
    if (-not (Test-Path $installScriptPath)) {
        # If no PowerShell script, try the shell script with WSL or Git Bash
        $installScriptPath = "$installerPath\installsensor.sh"
        if (-not (Test-Path $installScriptPath)) {
            Write-Error-Message "Installation script not found in extracted files."
            exit 13
        }
        
        Write-Info "Note: Shell script found. This requires WSL or Git Bash to run on Windows."
        Write-Info "Please run the following command manually in WSL or Git Bash:"
        $installCmd = "sudo $installScriptPath ActivationId=$ACTIVATIONID CustomerId=$CUSTOMERID Storage=$storageDir -s --perform-sca-scan"
        if ($INSTALL_OPTIONS -ne "NONE") {
            $installCmd += " $INSTALL_OPTIONS"
        }
        Write-Info $installCmd
        
        # For Docker Desktop/Podman on Windows, we'll use the dockerhub method instead
        Write-Info "Switching to Dockerhub installation method for Windows compatibility..."
        Install-FromDockerhub
        return
    }
    
    # Build install command for PowerShell script
    $installArgs = @(
        "ActivationId=$ACTIVATIONID",
        "CustomerId=$CUSTOMERID",
        "Storage=$storageDir",
        "-s",
        "--perform-sca-scan"
    )
    
    if ($RUNTIME -eq "podman") {
        $installArgs += "ContainerRuntime=podman"
        $installArgs += "StorageDriverType=overlay"
    } else {
        $installArgs += "StorageDriverType=overlay2"
    }
    
    # Add any additional install options if provided
    if ($INSTALL_OPTIONS -ne "NONE") {
        $installArgs += $INSTALL_OPTIONS -split " "
    }
    
    Write-Info "Executing installation script with arguments: $($installArgs -join ' ')"
    
    try {
        & $installScriptPath @installArgs
        Write-Info "Sensor installation completed successfully."
    } catch {
        Write-Error-Message "Sensor installation failed. Error: $_"
        exit 13
    }
}

# Function to handle installation from Dockerhub
function Install-FromDockerhub {
    # Ensure required variables are set
    if ($POD_URL -eq "NONE" -or -not $POD_URL) {
        Write-Error-Message "POD_URL must be set when using Dockerhub."
        exit 21
    }
    
    Write-Info "Installing from Dockerhub..."
    
    # Prepare volume mounts based on runtime
    $volumeMounts = @()
    if ($RUNTIME -eq "podman") {
        # Podman on Windows uses named pipes
        $volumeMounts += "-v", "\\.\pipe\podman-machine-default:/var/run/docker.sock:ro"
    } else {
        # Docker Desktop on Windows uses named pipes
        $volumeMounts += "-v", "\\.\pipe\docker_engine:/var/run/docker.sock:ro"
    }
    
    # Add data volume
    $dataPath = "C:\ProgramData\Qualys\sensor\data"
    if (-not (Test-Path $dataPath)) {
        New-Item -ItemType Directory -Path $dataPath -Force | Out-Null
    }
    $volumeMounts += "-v", "${dataPath}:/usr/local/qualys/qpa/data"
    
    # Build docker/podman run command
    $runArgs = @(
        "run", "-d", "--restart", "on-failure"
    ) + $volumeMounts + @(
        "-e", "ACTIVATIONID=$ACTIVATIONID",
        "-e", "CUSTOMERID=$CUSTOMERID",
        "-e", "POD_URL=$POD_URL",
        "--net=host",
        "--name", "qualys-container-sensor",
        "qualys/qcs-sensor:latest",
        "--perform-sca-scan"
    )
    
    # Add additional options if provided
    if ($INSTALL_OPTIONS -ne "NONE") {
        $runArgs += $INSTALL_OPTIONS -split " "
    }
    
    # Run container
    try {
        Write-Info "Starting container with command: $RUNTIME $($runArgs -join ' ')"
        $containerId = & $RUNTIME @runArgs 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "Container failed to start: $containerId"
        }
        
        Write-Info "Container started with ID: $containerId"
    } catch {
        Write-Error-Message "Failed to start the Qualys container. Error: $_"
        exit 24
    }
    
    # Wait a moment for container to initialize
    Start-Sleep -Seconds 5
    
    # Validate that the container is running
    try {
        $runningStatus = & $RUNTIME inspect -f '{{.State.Running}}' qualys-container-sensor 2>$null
        if ($runningStatus -ne "true") {
            Write-Error-Message "Container did not start successfully."
            Write-Error-Message "Check the container logs for details:"
            & $RUNTIME logs qualys-container-sensor
            exit 25
        }
    } catch {
        Write-Error-Message "Failed to inspect container status. Error: $_"
        exit 25
    }
    
    Write-Info "Qualys container sensor installed and running successfully."
}

# Main logic
Test-ExistingInstances

switch ($LOCATION.ToLower()) {
    "dockerhub" {
        Install-FromDockerhub
    }
    default {
        # Try tar installation first, fall back to dockerhub if needed
        Install-FromTar
    }
}

Write-Info "Installation completed successfully."
exit 0