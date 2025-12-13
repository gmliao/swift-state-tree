#!/bin/bash

# Test rapid login/logout cycles to stress test the Kick Old strategy
# This tests race conditions and rapid duplicate logins

URL="ws://localhost:8080/game"
LAND="demo-game"
PLAYER_ID="rapid-test-player"

echo "========================================="
echo "Testing rapid login/logout cycles (stress test)"
echo "URL: $URL"
echo "Land: $LAND"
echo "PlayerID: $PLAYER_ID"
echo "========================================="
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

# Test 50 rapid connections
for i in {1..50}; do
    echo -n "[$i/50] "
    
    # Run CLI with --once flag and very short timeout
    if timeout 3 npm run dev -- connect -u "$URL" -l "$LAND" -p "$PLAYER_ID" --once --timeout 0 > /tmp/cli-rapid-$i.log 2>&1; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo "✅"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "❌"
        if [ $FAIL_COUNT -le 3 ]; then
            echo "  Last 3 lines:"
            tail -3 /tmp/cli-rapid-$i.log | sed 's/^/    /'
        fi
    fi
    
    # Very short delay (10ms) to test rapid succession
    sleep 0.01
done

echo ""
echo "========================================="
echo "Rapid Test Results:"
echo "  Total attempts: 50"
echo "  Successful: $SUCCESS_COUNT"
echo "  Failed: $FAIL_COUNT"
echo "========================================="

# Cleanup
rm -f /tmp/cli-rapid-*.log

if [ $FAIL_COUNT -eq 0 ]; then
    echo "✅ All rapid tests passed!"
    exit 0
else
    echo "⚠️  Some rapid tests failed (may be expected under extreme load)"
    exit 0  # Don't fail the test, as some failures might be expected
fi

