#!/bin/bash

# Test script for 20 login/logout cycles
# This script tests the duplicate login prevention and Kick Old strategy

URL="ws://localhost:8080/game"
LAND="demo-game"
PLAYER_ID="test-player-20"

echo "========================================="
echo "Testing 20 login/logout cycles"
echo "URL: $URL"
echo "Land: $LAND"
echo "PlayerID: $PLAYER_ID"
echo "========================================="
echo ""

# Check if server is running
if ! nc -z localhost 8080 2>/dev/null; then
    echo "⚠️  Warning: Server does not appear to be running on port 8080"
    echo "   Please start the server first with: swift run HummingbirdDemo"
    echo ""
    echo "   Attempting test anyway..."
    echo ""
fi

SUCCESS_COUNT=0
FAIL_COUNT=0

for i in {1..20}; do
    echo "[$i/20] Attempting login..."
    
    # Run CLI with --once flag (connects, joins, then disconnects)
    if npm run dev -- connect -u "$URL" -l "$LAND" -p "$PLAYER_ID" --once --timeout 1 > /tmp/cli-test-$i.log 2>&1; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo "  ✅ Login $i succeeded"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  ❌ Login $i failed"
        echo "  Last 5 lines of log:"
        tail -5 /tmp/cli-test-$i.log | sed 's/^/    /'
    fi
    
    # Small delay between attempts
    sleep 0.1
done

echo ""
echo "========================================="
echo "Test Results:"
echo "  Total attempts: 20"
echo "  Successful: $SUCCESS_COUNT"
echo "  Failed: $FAIL_COUNT"
echo "========================================="

# Cleanup
rm -f /tmp/cli-test-*.log

if [ $FAIL_COUNT -eq 0 ]; then
    echo "✅ All tests passed!"
    exit 0
else
    echo "❌ Some tests failed"
    exit 1
fi

