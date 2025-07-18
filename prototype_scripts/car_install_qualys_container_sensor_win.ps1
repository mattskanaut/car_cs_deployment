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

# PowerShell script to install Qualys Container Sensor on Windows
# Supports Docker Desktop and Podman

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

$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Error-Message {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# ==============================
# Script starts here
# ==============================

$FORCE_REINSTALL_BOOL = $false
if ($FORCE_REINSTALL -eq "true") {
    $FORCE_REINSTALL_BOOL = $true
}

# Detect Docker or Podman
$RUNTIME = ""
$dockerExists = $false
$podmanExists = $false

try {
    $null = docker version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $dockerExists = $true
    }
} catch {}

try {
    $null = podman version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $podmanExists = $true
    }
} catch {}

if ($dockerExists -and $podmanExists) {
    Write-Error-Message "Both Docker and Podman are installed. Please use only one."
    exit 1
} elseif ($dockerExists) {
    $RUNTIME = "docker"
    Write-Info "Docker detected."
} elseif ($podmanExists) {
    $RUNTIME = "podman"
    Write-Info "Podman detected."
} else {
    Write-Error-Message "No container runtime detected."
    exit 1
}

# Remove existing container if necessary
$existing = & $RUNTIME ps -a --filter "name=qualys-container-sensor" --format '{{.ID}}'
if ($existing) {
    if ($FORCE_REINSTALL_BOOL) {
        Write-Info "Removing existing sensor container..."
        & $RUNTIME rm -f qualys-container-sensor
    } else {
        Write-Error-Message "Sensor already running. Use FORCE_REINSTALL=true to replace it."
        exit 2
    }
}

if ($LOCATION -eq "dockerhub") {
    Write-Info "Pulling latest Qualys sensor image..."
    & $RUNTIME pull qualys/qcs-sensor:latest

    Write-Info "Running sensor installation..."

    $cmd = @(
        "run", "-d", "--restart", "on-failure",
        "--name", "qualys-container-sensor",
        "-v", "/var/run/docker.sock:/var/run/docker.sock",
        "-e", "ACTIVATIONID=$ACTIVATIONID",
        "-e", "CUSTOMERID=$CUSTOMERID",
        "-e", "POD_URL=$POD_URL",
        "qualys/qcs-sensor:latest",
        "--perform-sca-scan",
        "--sensor-without-persistent-storage"
    )

    if ($INSTALL_OPTIONS -ne "NONE") {
        $cmd += $INSTALL_OPTIONS -split " "
    }

    Write-Info "Executing: $RUNTIME $($cmd -join ' ')"
    & $RUNTIME @cmd

} else {
    Write-Error-Message "Only 'dockerhub' installation is currently supported by this script."
    exit 3
}

Write-Info "Installation process completed."
exit 0
