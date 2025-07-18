# test_helper.bash
# Helper functions for Bats tests

# Mock a command by creating an executable file in the mocks directory
mock() {
  local command=$1
  local behavior=$2

  # Create the mock command script
  echo -e "#!/bin/bash\n$behavior" > "mocks/$command"
  chmod +x "mocks/$command"
}

# Clear all existing mocks from the mocks directory
clear_mocks() {
  rm -rf mocks/*
}

# Capture logs from info or error outputs in the script
capture_logs() {
  grep -E "^\[INFO\]|\[ERROR\]" <<< "$output"
}

# Assert that a specific message exists in the logs
assert_log_contains() {
  local expected_message=$1
  capture_logs | grep -q "$expected_message"
  if [ $? -ne 0 ]; then
    echo "Expected log message not found: $expected_message"
    return 1
  fi
}
