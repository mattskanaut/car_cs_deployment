#!/usr/bin/env bats

# Load helper functions for mocking
load "test_helper.bash"

# Setup and Teardown for Mocks
setup() {
  # Backup PATH and set up mock commands
  export ORIGINAL_PATH=$PATH
  export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"

  # Create mocks directory
  mkdir -p mocks
}

teardown() {
  # Restore original PATH and clean up mocks
  export PATH=$ORIGINAL_PATH
  rm -rf mocks
}

# Test Missing Mandatory Variables
@test "Exits with 1 if LOCATION, ACTIVATIONID, or CUSTOMERID is missing" {
  run bash qualys_installer.sh
  [ "$status" -eq 1 ]
  [[ "$output" =~ "LOCATION, ACTIVATIONID, and CUSTOMERID must be set" ]]
}

# Test Docker Not Installed
@test "Exits with 2 if Docker is not installed" {
  mock "which" "exit 1" # Mock which to fail for docker
  run bash qualys_installer.sh
  [ "$status" -eq 2 ]
  [[ "$output" =~ "Docker is not installed" ]]
}

# Test Docker Not Running
@test "Exits with 3 if Docker is not running" {
  mock "which" "echo /usr/bin/docker" # Docker exists
  mock "docker info" "exit 1" # Docker info fails
  run bash qualys_installer.sh
  [ "$status" -eq 3 ]
  [[ "$output" =~ "Docker is not running" ]]
}

# Test Existing Sensor with FORCE_REINSTALL=true
@test "Removes existing sensor if FORCE_REINSTALL=true" {
  export FORCE_REINSTALL=true
  mock "docker ps" 'echo "container-id"' # Mock container exists
  mock "docker rm" "exit 0" # Mock removal successful
  run bash qualys_installer.sh
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Existing instance found" ]]
}

# Test Existing Sensor with FORCE_REINSTALL=false
@test "Exits with 4 if existing sensor found and FORCE_REINSTALL=false" {
  export FORCE_REINSTALL=false
  mock "docker ps" 'echo "container-id"' # Mock container exists
  run bash qualys_installer.sh
  [ "$status" -eq 4 ]
  [[ "$output" =~ "Existing instance found. FORCE_REINSTALL is set to false" ]]
}

# Test URL Validation Failure (403 Forbidden)
@test "Exits with 11 if URL returns 403" {
  mock "curl" "exit 22" # Mock 403 response
  run bash qualys_installer.sh
  [ "$status" -eq 11 ]
  [[ "$output" =~ "URL is expired or invalid" ]]
}

# Test URL Validation Failure (404 Not Found)
@test "Exits with 12 if URL returns 404" {
  mock "curl" "exit 22" # Mock 404 response
  run bash qualys_installer.sh
  [ "$status" -eq 12 ]
  [[ "$output" =~ "Resource not found" ]]
}

# Test Unexpected HTTP Status
@test "Exits with 13 on unexpected HTTP status" {
  mock "curl" 'echo "Unexpected HTTP status"; exit 0' # Mock non-200 status
  run bash qualys_installer.sh
  [ "$status" -eq 13 ]
  [[ "$output" =~ "Unexpected error" ]]
}

# Test Tar Extraction Failure
@test "Exits with 15 if tar extraction fails" {
  mock "curl" "exit 0" # Mock download successful
  mock "tar" "exit 1" # Mock tar extraction failure
  run bash qualys_installer.sh
  [ "$status" -eq 15 ]
  [[ "$output" =~ "Failed to extract the tar.xz file" ]]
}

# Test Successful Installation
@test "Succeeds when everything works" {
  mock "curl" "exit 0" # Mock successful download
  mock "tar" "exit 0" # Mock successful tar extraction
  mock "sudo ./installsensor.sh" "exit 0" # Mock successful installation
  run bash qualys_installer.sh
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Installation completed successfully" ]]
}
