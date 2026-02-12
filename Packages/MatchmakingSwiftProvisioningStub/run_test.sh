#!/bin/bash
set -e
cd "$(dirname "$0")"

# Build
swift build

# Path to executable
BIN=$(swift build --show-bin-path)/MatchmakingSwiftProvisioningStub

# Start server
echo "Starting server..."
$BIN &
PID=$!
echo "Server started with PID $PID"

# Cleanup on exit
trap "kill $PID" EXIT

# Wait for server to start
sleep 2

# Run verification
./verify_stub.sh
