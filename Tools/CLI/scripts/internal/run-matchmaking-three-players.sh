#!/bin/bash
# Matchmaking three-player E2E: three users enqueue as a group, all connect to same game.
# Enqueues group [p1, p2, p3] with groupSize 3 -> one assignment -> all connect to same landId.
# Uses queueKey hero-defense:3 so minGroupSize=maxGroupSize=3.
#
# Run after control plane + GameServer are up (e.g. from run-matchmaking-full-with-test.sh).
# Set MATCHMAKING_CONTROL_PLANE_URL.
set -e

CONTROL_PLANE_URL="${MATCHMAKING_CONTROL_PLANE_URL:-http://127.0.0.1:3000}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CLI_DIR="$PROJECT_ROOT/Tools/CLI"

cd "$CLI_DIR"

if [ ! -d "node_modules" ]; then
    npm ci
fi

echo "=========================================="
echo "  Matchmaking Three-Player E2E"
echo "=========================================="
echo "Control plane: $CONTROL_PLANE_URL"
echo ""

# 1. Enqueue group of 3
echo "Enqueueing group [p1, p2, p3]..."
ENQUEUE_RESPONSE=$(curl -s -X POST "$CONTROL_PLANE_URL/v1/matchmaking/enqueue" \
    -H "Content-Type: application/json" \
    -d '{"groupId":"three-player-1","queueKey":"hero-defense:3","members":["p1","p2","p3"],"groupSize":3}')

TMP=$(mktemp)
trap "rm -f $TMP" EXIT
echo "$ENQUEUE_RESPONSE" > "$TMP"
TICKET_ID=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.ticketId) throw new Error('Missing ticketId'); console.log(d.ticketId)" "$TMP")

echo "Polling for assignment (ticketId=$TICKET_ID)..."
MAX_ATTEMPTS=30
for i in $(seq 1 $MAX_ATTEMPTS); do
    STATUS_RESPONSE=$(curl -s "$CONTROL_PLANE_URL/v1/matchmaking/status/$TICKET_ID")
    echo "$STATUS_RESPONSE" > "$TMP"
    STATUS=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); console.log(d.status||'')" "$TMP")
    if [ "$STATUS" = "assigned" ]; then
        break
    fi
    if [ "$i" -eq "$MAX_ATTEMPTS" ]; then
        echo "Error: Timed out waiting for assignment"
        exit 1
    fi
    sleep 1
done

CONNECT_URL=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.assignment?.connectUrl) throw new Error('Missing connectUrl'); console.log(d.assignment.connectUrl)" "$TMP")
MATCH_TOKEN=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.assignment?.matchToken) throw new Error('Missing matchToken'); console.log(d.assignment.matchToken)" "$TMP")
LAND_ID=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.assignment?.landId) throw new Error('Missing landId'); console.log(d.assignment.landId)" "$TMP")

WS_URL="${CONNECT_URL}"
if [[ "$WS_URL" == *"?"* ]]; then
    WS_URL="${WS_URL}&token=${MATCH_TOKEN}"
else
    WS_URL="${WS_URL}?token=${MATCH_TOKEN}"
fi

echo "Assignment: landId=$LAND_ID, all three players will connect"
echo ""

# 2. Run three clients in parallel to same game (guest mode allows all)
echo "Starting player 1..."
npx tsx src/cli.ts script \
    -u "$WS_URL" \
    -l "$LAND_ID" \
    -s scenarios/game/test-matchmaking-three-players.json \
    --state-update-encoding opcodeJsonArray &
P1_PID=$!

echo "Starting player 2 (same room, guest mode)..."
BASE_WS="${CONNECT_URL}"
npx tsx src/cli.ts script \
    -u "$BASE_WS" \
    -l "$LAND_ID" \
    -s scenarios/game/test-matchmaking-three-players.json \
    --state-update-encoding opcodeJsonArray &
P2_PID=$!

echo "Starting player 3 (same room, guest mode)..."
npx tsx src/cli.ts script \
    -u "$BASE_WS" \
    -l "$LAND_ID" \
    -s scenarios/game/test-matchmaking-three-players.json \
    --state-update-encoding opcodeJsonArray &
P3_PID=$!

wait $P1_PID
P1_EXIT=$?
wait $P2_PID
P2_EXIT=$?
wait $P3_PID
P3_EXIT=$?

if [ $P1_EXIT -ne 0 ] || [ $P2_EXIT -ne 0 ] || [ $P3_EXIT -ne 0 ]; then
    echo "One or more players failed (p1=$P1_EXIT, p2=$P2_EXIT, p3=$P3_EXIT)"
    exit 1
fi

echo ""
echo "=========================================="
echo "  Matchmaking Three-Player E2E: PASS"
echo "=========================================="
