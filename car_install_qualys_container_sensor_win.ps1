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

    [Parameter(Mandatory=$false, Position=5)]
    [string]$FORCE_REINSTALL = "false"    # Force reinstall even if container exists and is up to date (true/false)
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
    # Clean up any control characters that might interfere with formatting
    $cleanMessage = $Message -replace '[\r\n\x1B\x7F]', '' -replace '\s+', ' '
    $cleanMessage = $cleanMessage.Trim()
    # Simple, clean output without cursor manipulation
    Write-Host "[INFO] $cleanMessage" -ForegroundColor Green
}

function Write-Error-Message {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

# Version checking function for Docker Hub installations
function Test-ContainerVersion {
    param(
        [string]$ContainerName,
        [string]$Runtime
    )
    
    # Get running container's image SHA
    $runningShaTry = & $Runtime inspect $ContainerName --format='{{.Image}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    
    # Get latest SHA from Docker Hub (no pull credits)
    try {
        $response = Invoke-RestMethod -Uri "https://hub.docker.com/v2/repositories/qualys/qcs-sensor/tags/latest" -Method Get
        $latestSha = $response.images[0].digest
        
        if ($runningShaTry -ne $latestSha) {
            return $true  # Upgrade available
        } else {
            return $false # Up to date
        }
    } catch {
        Write-Warning "Could not check version from Docker Hub: $_"
        return $false
    }
}

# Container existence checking
function Test-ContainerExists {
    param(
        [string]$ContainerName,
        [string]$Runtime
    )
    
    $existing = & $Runtime ps -a --filter "name=$ContainerName" --format '{{.ID}}' 2>$null
    return [bool]$existing
}

# Remove existing container
function Remove-ExistingContainer {
    param(
        [string]$ContainerName,
        [string]$Runtime
    )
    
    # Check current container state
    $containerState = & $Runtime inspect -f '{{.State.Status}}' $ContainerName 2>$null
    Write-Info "Current container state: $containerState"
    
    Write-Info "Stopping and removing existing container: $ContainerName"
    
    # Stop if running
    if ($containerState -eq "running") {
        Write-Info "Stopping running container..."
        & $Runtime stop $ContainerName 2>$null | Out-Null
    }
    
    # Remove container
    Write-Info "Removing container..."
    & $Runtime rm -f $ContainerName 2>$null | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Existing container removed successfully"
    } else {
        Write-Warning "Failed to remove container, but continuing..."
    }
}

# ==============================
# Script starts here
# ==============================

# Normalize all parameter values to lowercase for case-insensitive comparison
$LOCATION = $LOCATION.ToLower()
$POD_URL = $POD_URL.ToLower()
$INSTALL_OPTIONS = $INSTALL_OPTIONS.ToLower()
$FORCE_REINSTALL = $FORCE_REINSTALL.ToLower()

# Convert string parameter to boolean and validate
$forceReinstallBool = $false
if ($FORCE_REINSTALL -eq "true") {
    $forceReinstallBool = $true
} elseif ($FORCE_REINSTALL -eq "false") {
    $forceReinstallBool = $false
} else {
    Write-Error-Message "Invalid FORCE_REINSTALL value: $FORCE_REINSTALL. Valid values: true, false (case-insensitive)"
    exit 1
}

# Log the installation mode
if ($forceReinstallBool) {
    Write-Info "Running in FORCE REINSTALL mode - will remove and reinstall all containers"
} else {
    Write-Info "Running in INSTALL/UPGRADE mode - will install if missing or upgrade if outdated"
}

# Detect container runtimes - support multi-deployment
$RUNTIMES = @()
$dockerExists = $false
$podmanExists = $false

try {
    $null = docker version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $dockerExists = $true
        $RUNTIMES += "docker"
        Write-Info "Detected Docker runtime"
    }
} catch {}

try {
    $null = podman version 2>&1
    if ($LASTEXITCODE -eq 0) {
        $podmanExists = $true
        $RUNTIMES += "podman"
        Write-Info "Detected Podman runtime"
    }
} catch {}

if ($RUNTIMES.Count -eq 0) {
    Write-Error-Message "No container runtime (Docker or Podman) detected or accessible."
    exit 2
}

Write-Info "Found $($RUNTIMES.Count) container runtime(s): $($RUNTIMES -join ', ')"

# WSL Detection and Enumeration
function Get-WSLDistributions {
    Write-Info "Detecting WSL distributions..."
    $wslDistros = @()
    
    try {
        # Get list of WSL distributions
        $wslOutput = wsl --list --verbose 2>$null
        if ($LASTEXITCODE -eq 0) {
            # Parse WSL output (skip header lines and empty lines)
            $lines = $wslOutput -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Skip 1
            
            foreach ($line in $lines) {
                # Clean up Unicode characters and extra whitespace
                $cleanLine = $line -replace '[^\x20-\x7E]', '' -replace '\s+', ' '
                $cleanLine = $cleanLine.Trim()
                
                # Parse distribution info - more flexible regex
                if ($cleanLine -match '^\*?\s*([^\s]+)\s+(\w+)\s+(\d+)') {
                    $distroName = $Matches[1].Trim()
                    $state = $Matches[2].Trim()
                    $version = $Matches[3].Trim()
                    
                    if ($state -eq "Running") {
                        $wslDistros += @{
                            Name = $distroName
                            Version = $version
                            State = $state
                        }
                        Write-Info "Found WSL distribution: $distroName (WSL$version)"
                    }
                }
            }
        }
    } catch {
        Write-Warning "Could not enumerate WSL distributions: $_"
    }
    
    return $wslDistros
}

# Check for container runtimes in a specific WSL distribution
function Test-WSLContainerRuntimes {
    param(
        [string]$DistroName
    )
    
    $runtimes = @()
    
    # Check for Docker in WSL
    $dockerCheck = wsl -d $DistroName -- sh -c "command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1 && echo 'found'" 2>$null
    if ($dockerCheck -match "found") {
        # Skip docker-desktop WSL as it has restrictions
        if ($DistroName -ne "docker-desktop") {
            $runtimes += "docker"
            Write-Info "Found Docker in WSL distribution: $DistroName"
        } else {
            Write-Info "Skipping Docker in docker-desktop WSL (restricted)"
        }
    }
    
    # Check for Podman in WSL
    $podmanCheck = wsl -d $DistroName -- sh -c "command -v podman >/dev/null 2>&1 && podman version >/dev/null 2>&1 && echo 'found'" 2>&1
    
    # Also try just checking if podman command exists
    $podmanExists = wsl -d $DistroName -- sh -c "command -v podman >/dev/null 2>&1 && echo 'exists'" 2>&1
    
    if ($podmanCheck -match "found") {
        $runtimes += "podman"
        Write-Info "Found Podman in WSL distribution: $DistroName"
    } elseif ($podmanExists -match "exists") {
        # Podman exists but version check failed - try anyway
        $runtimes += "podman"
        Write-Info "Found Podman in WSL distribution: $DistroName"
    }
    
    return $runtimes
}

# Deploy to WSL instance
function Deploy-ToWSL {
    param(
        [string]$DistroName,
        [string]$Runtime,
        [string]$Location,
        [string]$ActivationId,
        [string]$CustomerId,
        [string]$PodUrl,
        [string]$InstallOptions
    )
    
    Write-Info "Deploying to $Runtime in WSL distribution: $DistroName"
    
    try {
        # Execute deployment steps directly in WSL
        Write-Info "Starting deployment steps in WSL as root"
        
        # Step 1: Check if container already exists and remove if needed
        Write-Info "Checking for existing container"
        $existingContainer = wsl -d $DistroName -u root -- $Runtime ps -a --filter "name=qualys-container-sensor" --format '{{.ID}}' 2>&1
        
        if ($existingContainer -and $existingContainer -notmatch "^$") {
            Write-Info "Removing existing container"
            wsl -d $DistroName -u root -- $Runtime stop qualys-container-sensor 2>&1 | Out-Null
            wsl -d $DistroName -u root -- $Runtime rm -f qualys-container-sensor 2>&1 | Out-Null
        }
        
        # Step 2: Pull the image
        Write-Info "Pulling Qualys sensor image"
        try {
            $job = Start-Job -ScriptBlock { 
                param($distro, $runtime)
                wsl -d $distro -u root -- $runtime pull docker.io/qualys/qcs-sensor:latest 2>&1
            } -ArgumentList $DistroName, $Runtime
            $job | Wait-Job | Out-Null
            if ($job.State -eq "Completed") {
                $pullExitCode = 0
            } else {
                $pullExitCode = 1
            }
            $job | Remove-Job
        } catch {
            $pullExitCode = 1
        }
        
        # Check if pull was successful
        try {
            $imageCheckJob = Start-Job -ScriptBlock { 
                param($distro, $runtime)
                wsl -d $distro -u root -- $runtime images --format '{{.Repository}}:{{.Tag}}' 2>$null | Select-String "qualys/qcs-sensor:latest" -Quiet
            } -ArgumentList $DistroName, $Runtime
            $imageExists = $imageCheckJob | Wait-Job | Receive-Job
            $imageCheckJob | Remove-Job
        } catch {
            $imageExists = $false
        }
        
        if ($imageExists) {
            Write-Info "Image pulled successfully"
        } else {
            throw "Failed to pull image (exit code: $pullExitCode)"
        }
        
        # Step 3: Find socket path for Podman
        if ($Runtime -eq "podman") {
            Write-Info "Finding Podman socket"
            $socketPath = ""
            $socketLocations = @("/run/podman/podman.sock", "/var/run/podman/podman.sock", "/run/user/0/podman/podman.sock")
            
            foreach ($socket in $socketLocations) {
                $socketExists = wsl -d $DistroName -u root -- test -S $socket 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $socketPath = $socket
                    Write-Info "Found Podman socket at: $socketPath"
                    break
                }
            }
            
            if (-not $socketPath) {
                throw "Podman socket not found"
            }
        }
        
        # Step 4: Create required directories
        Write-Info "Creating required directories"
        wsl -d $DistroName -u root -- mkdir -p /root/.config/qualys 2>&1 | Out-Null
        wsl -d $DistroName -u root -- mkdir -p /root/.local/share/qualys/sensor/data 2>&1 | Out-Null
        
        # Step 5: Run the container
        Write-Info "Running Qualys container"
        try {
            if ($Runtime -eq "podman") {
                $runJob = Start-Job -ScriptBlock { 
                    param($distro, $runtime, $socketPath, $activationId, $customerId, $podUrl)
                    wsl -d $distro -u root -- $runtime run -d --restart on-failure --privileged=true --name qualys-container-sensor -v "$socketPath`:$socketPath`:ro" -e ACTIVATIONID=$activationId -e CUSTOMERID=$customerId -e POD_URL=$podUrl --net=host docker.io/qualys/qcs-sensor:latest --container-runtime podman --perform-sca-scan --sensor-without-persistent-storage 2>&1
                } -ArgumentList $DistroName, $Runtime, $socketPath, $ActivationId, $CustomerId, $PodUrl
            } else {
                $runJob = Start-Job -ScriptBlock { 
                    param($distro, $runtime, $activationId, $customerId, $podUrl)
                    wsl -d $distro -u root -- $runtime run -d --restart on-failure --name qualys-container-sensor -v /var/run/docker.sock:/var/run/docker.sock -e ACTIVATIONID=$activationId -e CUSTOMERID=$customerId -e POD_URL=$podUrl docker.io/qualys/qcs-sensor:latest --perform-sca-scan --sensor-without-persistent-storage 2>&1
                } -ArgumentList $DistroName, $Runtime, $ActivationId, $CustomerId, $PodUrl
            }
            $runJob | Wait-Job | Out-Null
            if ($runJob.State -eq "Completed") {
                $runExitCode = 0
            } else {
                $runExitCode = 1
            }
            $runJob | Remove-Job
        } catch {
            $runExitCode = 1
        }
        
        # Check if container run was successful by verifying container exists
        try {
            $containerCheckJob = Start-Job -ScriptBlock { 
                param($distro, $runtime)
                wsl -d $distro -u root -- $runtime ps -a --filter "name=qualys-container-sensor" --format '{{.ID}}' 2>$null
            } -ArgumentList $DistroName, $Runtime
            $containerCheck = $containerCheckJob | Wait-Job | Receive-Job
            $containerCheckJob | Remove-Job
        } catch {
            $containerCheck = $null
        }
        
        if ($containerCheck) {
            Write-Info "Container started successfully"
        } else {
            throw "Failed to run container (exit code: $runExitCode)"
        }
        
        # Step 6: Verify deployment
        Write-Info "Verifying deployment"
        Start-Sleep -Seconds 5
        $containerStatus = wsl -d $DistroName -u root -- $Runtime ps --filter "name=qualys-container-sensor" --format '{{.Status}}' 2>$null
        
        if ($containerStatus -match "Up") {
            Write-Info "Container started successfully"
            $exitCode = 0
        } else {
            $logs = wsl -d $DistroName -u root -- $Runtime logs qualys-container-sensor 2>$null | Select-Object -First 10
            throw "Container failed to start. Status: $containerStatus. Logs: $($logs -join '; ')"
        }
        
        if ($exitCode -eq 0) {
            # Set up auto-start via WSL boot command
            Write-Info "Setting up container auto-start for WSL"
            try {
                $autoStartJob = Start-Job -ScriptBlock { 
                    param($distro)
                    wsl -d $distro -u root -- bash -c "
                        # Create or update /etc/wsl.conf
                        if [ ! -f /etc/wsl.conf ]; then
                            echo '[boot]' > /etc/wsl.conf
                            echo 'command = \"podman start qualys-container-sensor 2>/dev/null || true\"' >> /etc/wsl.conf
                        else
                            # Check if boot section exists
                            if ! grep -q '^\[boot\]' /etc/wsl.conf; then
                                echo '' >> /etc/wsl.conf
                                echo '[boot]' >> /etc/wsl.conf
                                echo 'command = \"podman start qualys-container-sensor 2>/dev/null || true\"' >> /etc/wsl.conf
                            else
                                # Remove existing qualys command if present
                                sed -i '/^command.*qualys-container-sensor/d' /etc/wsl.conf
                                # Add new command after [boot] section
                                sed -i '/^\[boot\]/a command = \"podman start qualys-container-sensor 2>/dev/null || true\"' /etc/wsl.conf
                            fi
                        fi
                    "
                } -ArgumentList $DistroName
                $autoStartJob | Wait-Job | Out-Null
                if ($autoStartJob.State -eq "Completed") {
                    Write-Info "Auto-start configured successfully"
                } else {
                    Write-Warning "Failed to configure auto-start"
                }
                $autoStartJob | Remove-Job
            } catch {
                Write-Warning "Failed to set up auto-start: $_"
            }
            
            return @{
                Status = "SUCCESS"
                Message = "Deployed to $Runtime in WSL:$DistroName with auto-start"
            }
        } else {
            return @{
                Status = "FAILED"
                Message = "Failed to deploy to $Runtime in WSL:$DistroName"
            }
        }
    } catch {
        Write-Error-Message "WSL deployment error: $_"
        return @{
            Status = "FAILED"
            Message = "WSL deployment exception: $_"
        }
    }
}

# Track deployment results
$DEPLOYMENT_RESULTS = @{}

# Deploy to a specific runtime
function Deploy-ToRuntime {
    param(
        [string]$Runtime,
        [string]$Location,
        [string]$ActivationId,
        [string]$CustomerId,
        [string]$PodUrl,
        [string]$InstallOptions
    )
    
    try {
        Write-Info "Starting deployment to $Runtime..."
        
        if ($Location -eq "dockerhub") {
            return Deploy-FromDockerHub -Runtime $Runtime -ActivationId $ActivationId -CustomerId $CustomerId -PodUrl $PodUrl -InstallOptions $InstallOptions
        } else {
            return Deploy-FromTarXz -Runtime $Runtime -Location $Location -ActivationId $ActivationId -CustomerId $CustomerId -InstallOptions $InstallOptions
        }
    } catch {
        Write-Error-Message "Deployment to $Runtime failed: $_"
        return @{
            Status = "FAILED"
            Message = "Deployment failed: $_"
        }
    }
}

# Deploy from Docker Hub
function Deploy-FromDockerHub {
    param(
        [string]$Runtime,
        [string]$ActivationId,
        [string]$CustomerId,
        [string]$PodUrl,
        [string]$InstallOptions
    )
    
    # Ensure required variables are set
    if ($PodUrl -eq "none" -or [string]::IsNullOrEmpty($PodUrl)) {
        Write-Error-Message "POD_URL must be set when using Dockerhub for $Runtime."
        return @{
            Status = "FAILED"
            Message = "POD_URL required for Docker Hub installation"
        }
    }
    
    Write-Info "Pulling latest Qualys sensor image for $Runtime..."
    & $Runtime pull docker.io/qualys/qcs-sensor:latest
    if ($LASTEXITCODE -ne 0) {
        return @{
            Status = "FAILED"
            Message = "Failed to pull image"
        }
    }
    
    Write-Info "Running sensor installation for $Runtime..."
    
    # Build runtime-specific command
    if ($Runtime -eq "podman") {
        $cmd = @(
            "run", "-d", "--restart", "on-failure",
            "--privileged=true",
            "--name", "qualys-container-sensor",
            "-v", "/run/podman/podman.sock:/run/podman/podman.sock:ro",
            "-v", "/var/lib/containers/storage:/var/lib/containers/storage:ro",
            "-v", "/etc/qualys:/usr/local/qualys/qpa/data/conf/agent-data",
            "-v", "/usr/local/qualys/sensor/data:/usr/local/qualys/qpa/data",
            "-e", "ACTIVATIONID=$ActivationId",
            "-e", "CUSTOMERID=$CustomerId",
            "-e", "POD_URL=$PodUrl",
            "--net=host",
            "docker.io/qualys/qcs-sensor:latest",
            "--container-runtime", "podman",
            "--perform-sca-scan",
            "--storage-driver-type", "overlay"
        )
    } else {
        # Docker command
        $cmd = @(
            "run", "-d", "--restart", "on-failure",
            "--name", "qualys-container-sensor",
            "-v", "/var/run/docker.sock:/var/run/docker.sock",
            "-e", "ACTIVATIONID=$ActivationId",
            "-e", "CUSTOMERID=$CustomerId",
            "-e", "POD_URL=$PodUrl",
            "docker.io/qualys/qcs-sensor:latest",
            "--perform-sca-scan",
            "--sensor-without-persistent-storage"
        )
    }
    
    
    if ($InstallOptions -ne "none") {
        $cmd += $InstallOptions -split " "
    }
    
    Write-Info "Executing: $Runtime $($cmd -join ' ')"
    & $Runtime @cmd
    
    if ($LASTEXITCODE -ne 0) {
        return @{
            Status = "FAILED"
            Message = "Container failed to start"
        }
    }
    
    # Verify installation
    Write-Info "Waiting for container to start..."
    Start-Sleep -Seconds 5
    
    $status = & $Runtime inspect -f '{{.State.Running}}' qualys-container-sensor 2>$null
    Write-Info "Container running status: $status"
    
    if ($status -eq "true") {
        Write-Info "Container started successfully for $Runtime"
        return @{
            Status = "SUCCESS"
            Message = "Deployed successfully from Docker Hub"
        }
    } else {
        # Get more detailed information about why it failed
        $containerState = & $Runtime inspect -f '{{.State.Status}}' qualys-container-sensor 2>$null
        $exitCode = & $Runtime inspect -f '{{.State.ExitCode}}' qualys-container-sensor 2>$null
        $logs = & $Runtime logs qualys-container-sensor 2>$null | Select-Object -First 10
        
        Write-Error-Message "Container status: $containerState, Exit code: $exitCode"
        Write-Error-Message "Container logs (first 10 lines):"
        if ($logs) {
            $logs | ForEach-Object { Write-Error-Message "  $_" }
        }
        
        return @{
            Status = "FAILED"
            Message = "Container failed to start properly (status: $containerState, exit: $exitCode)"
        }
    }
}

# Deploy from tar.xz (placeholder for future implementation)
function Deploy-FromTarXz {
    param(
        [string]$Runtime,
        [string]$Location,
        [string]$ActivationId,
        [string]$CustomerId,
        [string]$InstallOptions
    )
    
    Write-Error-Message "Tar.xz installation is not yet implemented for Windows."
    return @{
        Status = "FAILED"
        Message = "Tar.xz installation not yet supported"
    }
}

# Generate deployment summary
function Write-DeploymentSummary {
    param(
        [bool]$ForceReinstall,
        [hashtable]$Results
    )
    
    $mode = if ($ForceReinstall) { "Force Reinstall" } else { "Install/Upgrade" }
    
    # Use Out-Host to bypass any console redirection issues
    "" | Out-Host
    "========================================" | Out-Host
    "Deployment Summary:" | Out-Host
    "========================================" | Out-Host
    "Mode: $mode" | Out-Host
    "Detected runtimes: $($Results.Count)" | Out-Host
    "" | Out-Host
    
    foreach ($runtime in $Results.Keys) {
        $result = $Results[$runtime]
        $symbol = switch ($result.Status) {
            "SUCCESS" { "[OK]  " }
            "FAILED" { "[FAIL]" }
            "SKIPPED" { "[SKIP]" }
            default { "[?]   " }
        }
        
        $message = if ($result.Message) { " - $($result.Message)" } else { "" }
        "$symbol $runtime`: $($result.Status)$message" | Out-Host
    }
    
    $successCount = ($Results.Values | Where-Object { $_.Status -eq "SUCCESS" }).Count
    $failedCount = ($Results.Values | Where-Object { $_.Status -eq "FAILED" }).Count
    $skippedCount = ($Results.Values | Where-Object { $_.Status -eq "SKIPPED" }).Count
    
    "" | Out-Host
    if ($skippedCount -gt 0) {
        "Total: $successCount/$($Results.Count) deployments successful ($skippedCount skipped)" | Out-Host
    } else {
        "Total: $successCount/$($Results.Count) deployments successful" | Out-Host
    }
    "========================================" | Out-Host
}

# Installation decision function
function Test-InstallationDecision {
    param(
        [bool]$ForceReinstall,
        [string]$ContainerName,
        [string]$Runtime,
        [string]$Location
    )
    
    $containerExists = Test-ContainerExists -ContainerName $ContainerName -Runtime $Runtime
    $isOutdated = $false
    $isRunning = $false
    
    if ($containerExists) {
        Write-Info "Existing sensor container found for $Runtime"
        
        # Check if container is running
        $containerStatus = & $Runtime inspect -f '{{.State.Status}}' $ContainerName 2>$null
        $isRunning = ($containerStatus -eq "running")
        Write-Info "Container status: $containerStatus"
        
        # Check if outdated (Docker Hub only)
        if ($Location -eq "dockerhub" -and $isRunning) {
            $isOutdated = Test-ContainerVersion -ContainerName $ContainerName -Runtime $Runtime
            if ($isOutdated) {
                Write-Info "Container is outdated for $Runtime"
            } else {
                Write-Info "Container is up to date for $Runtime"
            }
        }
    } else {
        Write-Info "No existing sensor container found for $Runtime"
    }
    
    # Decide based on force_reinstall parameter
    if ($ForceReinstall) {
        if ($containerExists) {
            Write-Info "Force reinstall requested - removing existing container for $Runtime..."
            Remove-ExistingContainer -ContainerName $ContainerName -Runtime $Runtime
        }
        return $true  # Always proceed with installation
    } else {
        # Default behavior: ensure a running, up-to-date sensor
        if (-not $containerExists) {
            Write-Info "Installing new container for $Runtime..."
            return $true  # Proceed with installation
        } elseif (-not $isRunning) {
            Write-Info "Container exists but is not running (status: $containerStatus) - reinstalling for $Runtime..."
            Remove-ExistingContainer -ContainerName $ContainerName -Runtime $Runtime
            return $true  # Proceed with reinstall
        } elseif (($Location -eq "dockerhub") -and $isOutdated) {
            Write-Info "Upgrading outdated container for $Runtime..."
            Remove-ExistingContainer -ContainerName $ContainerName -Runtime $Runtime
            return $true  # Proceed with upgrade
        } else {
            Write-Info "Container exists, is running, and is up to date for $Runtime - no action needed."
            return $false  # Skip installation
        }
    }
}

# Deploy to each runtime
foreach ($runtime in $RUNTIMES) {
    Write-Info "Processing deployment for $runtime..."
    
    # Check if installation should proceed for this runtime
    if (Test-InstallationDecision -ForceReinstall $forceReinstallBool -ContainerName "qualys-container-sensor" -Runtime $runtime -Location $LOCATION) {
        $deploymentResult = Deploy-ToRuntime -Runtime $runtime -Location $LOCATION -ActivationId $ACTIVATIONID -CustomerId $CUSTOMERID -PodUrl $POD_URL -InstallOptions $INSTALL_OPTIONS
        $DEPLOYMENT_RESULTS[$runtime] = $deploymentResult
    } else {
        $DEPLOYMENT_RESULTS[$runtime] = @{
            Status = "SKIPPED"
            Message = "No action needed based on FORCE_REINSTALL parameter"
        }
        Write-Info "Skipping deployment for $runtime"
    }
}

# Deploy to WSL distributions
Write-Info ""
Write-Info "Checking for WSL distributions..."
$wslDistros = Get-WSLDistributions

if ($wslDistros.Count -gt 0) {
    Write-Info "Found $($wslDistros.Count) running WSL distribution(s)"
    
    foreach ($distro in $wslDistros) {
        $distroName = $distro.Name
        Write-Info ""
        Write-Info "Checking container runtimes in WSL: $distroName"
        
        # Check what runtimes are available in this WSL instance
        $wslRuntimes = Test-WSLContainerRuntimes -DistroName $distroName
        
        if ($wslRuntimes.Count -eq 0) {
            Write-Info "No container runtimes found in WSL: $distroName"
            $DEPLOYMENT_RESULTS["WSL:$distroName"] = @{
                Status = "SKIPPED"
                Message = "No container runtimes found"
            }
        } else {
            # Deploy to each runtime found in WSL
            foreach ($runtime in $wslRuntimes) {
                $deploymentKey = "WSL:$distroName-$runtime"
                Write-Info "Processing deployment for $runtime in WSL: $distroName"
                
                if ($LOCATION -ne "dockerhub") {
                    Write-Warning "WSL deployment currently only supports dockerhub location"
                    $DEPLOYMENT_RESULTS[$deploymentKey] = @{
                        Status = "SKIPPED"
                        Message = "Only dockerhub location supported for WSL"
                    }
                    continue
                }
                
                # Check if we should proceed with installation
                $shouldInstall = $forceReinstallBool
                if (-not $shouldInstall) {
                    # Check if container exists in WSL
                    $containerCheck = wsl -d $distroName -- $runtime ps -a --filter "name=qualys-container-sensor" --format '{{.ID}}' 2>$null
                    if ([string]::IsNullOrEmpty($containerCheck)) {
                        $shouldInstall = $true
                        Write-Info "No existing container found in WSL, proceeding with installation"
                    } else {
                        # Check if running
                        $runningCheck = wsl -d $distroName -- $runtime ps --filter "name=qualys-container-sensor" --format '{{.Status}}' 2>$null
                        if ($runningCheck -notmatch "Up") {
                            $shouldInstall = $true
                            Write-Info "Container exists but not running in WSL, proceeding with reinstallation"
                        }
                    }
                }
                
                if ($shouldInstall) {
                    $deploymentResult = Deploy-ToWSL -DistroName $distroName -Runtime $runtime -Location $LOCATION -ActivationId $ACTIVATIONID -CustomerId $CUSTOMERID -PodUrl $POD_URL -InstallOptions $INSTALL_OPTIONS
                    $DEPLOYMENT_RESULTS[$deploymentKey] = $deploymentResult
                } else {
                    $DEPLOYMENT_RESULTS[$deploymentKey] = @{
                        Status = "SKIPPED"
                        Message = "Container already running"
                    }
                    Write-Info "Skipping deployment - container already running in WSL"
                }
            }
        }
    }
} else {
    Write-Info "No running WSL distributions found"
}

# Generate deployment summary
Write-DeploymentSummary -ForceReinstall $forceReinstallBool -Results $DEPLOYMENT_RESULTS

# Determine exit code
$successCount = ($DEPLOYMENT_RESULTS.Values | Where-Object { $_.Status -eq "SUCCESS" }).Count
$totalCount = $DEPLOYMENT_RESULTS.Count
$failedCount = ($DEPLOYMENT_RESULTS.Values | Where-Object { $_.Status -eq "FAILED" }).Count

if ($failedCount -eq 0 -and $successCount -gt 0) {
    Write-Info "All deployments completed successfully."
    exit 0
} elseif ($successCount -gt 0 -and $failedCount -gt 0) {
    Write-Warning "Partial success: $successCount/$totalCount deployments succeeded."
    exit 7
} elseif ($successCount -eq 0 -and $failedCount -gt 0) {
    Write-Error-Message "All deployments failed."
    exit 5
} else {
    Write-Info "No deployments were needed."
    exit 7
}
