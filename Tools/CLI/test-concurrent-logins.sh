#!/bin/bash

# Test concurrent login attempts with the same playerID
# This tests the Kick Old strategy under concurrent load

URL="ws://localhost:8080/game"
LAND="demo-game"
PLAYER_ID="concurrent-test-player"

echo "========================================="
echo "Testing concurrent login attempts"
echo "URL: $URL"
echo "Land: $LAND"
echo "PlayerID: $PLAYER_ID"
echo "========================================="
echo ""

# Launch 10 concurrent connections
echo "Launching 10 concurrent connections..."
for i in {1..10}; do
    (
        npm run dev -- connect -u "$URL" -l "$LAND" -p "$PLAYER_ID" --once --timeout 1 > /tmp/cli-concurrent-$i.log 2>&1
        echo "[Connection $i] Finished" >> /tmp/cli-concurrent-results.log
    ) &
done

# Wait for all background jobs
wait

echo ""
echo "Checking results..."

SUCCESS_COUNT=0
FAIL_COUNT=0

for i in {1..10}; do
    if grep -q "Successfully joined" /tmp/cli-concurrent-$i.log 2>/dev/null; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo "  Connection $i: ✅ Joined successfully"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "  Connection $i: ❌ Failed or was kicked"
        if [ -f /tmp/cli-concurrent-$i.log ]; then
            echo "    Last line: $(tail -1 /tmp/cli-concurrent-$i.log)"
        fi
    fi
done

echo ""
echo "========================================="
echo "Concurrent Test Results:"
echo "  Total connections: 10"
echo "  Successful joins: $SUCCESS_COUNT"
echo "  Failed/kicked: $FAIL_COUNT"
echo ""
echo "Note: With Kick Old strategy, only the last connection"
echo "      should succeed. Others should be kicked."
echo "========================================="

# Cleanup
rm -f /tmp/cli-concurrent-*.log

echo "✅ Concurrent test completed!"

