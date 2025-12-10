#!/bin/bash
# Quick connection test script

cd "$(dirname "$0")"

echo "Testing connection to ws://localhost:8080/game..."
echo ""

# Run CLI with timeout (using node's built-in timeout or just run and kill)
npm run dev -- connect --url ws://localhost:8080/game --land demo-game &
CLI_PID=$!

# Wait 5 seconds then kill
sleep 5
kill $CLI_PID 2>/dev/null || true
wait $CLI_PID 2>/dev/null || true

echo ""
echo "Connection test completed"

