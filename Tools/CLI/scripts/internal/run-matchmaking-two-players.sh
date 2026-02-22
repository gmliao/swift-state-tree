#!/bin/bash
# Matchmaking two-player E2E: two users enqueue as a group, both connect to same game.
# Enqueues group [p1, p2] with groupSize 2 -> one assignment -> both connect to same landId.
#
# Run after control plane + GameServer are up (e.g. from run-matchmaking-full-with-test.sh
# or run-matchmaking-nginx-e2e.sh). Set MATCHMAKING_CONTROL_PLANE_URL.
set -e

CONTROL_PLANE_URL="${MATCHMAKING_CONTROL_PLANE_URL:-http://127.0.0.1:3000}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CLI_DIR="$PROJECT_ROOT/Tools/CLI"

cd "$CLI_DIR"

if [ ! -d "node_modules" ]; then
    npm ci
fi

echo "=========================================="
echo "  Matchmaking Two-Player E2E"
echo "=========================================="
echo "Control plane: $CONTROL_PLANE_URL"
echo ""

# 1. Enqueue group of 2
echo "Enqueueing group [p1, p2]..."
ENQUEUE_RESPONSE=$(curl -s -X POST "$CONTROL_PLANE_URL/v1/matchmaking/enqueue" \
    -H "Content-Type: application/json" \
    -d '{"groupId":"two-player-1","queueKey":"hero-defense:2","members":["p1","p2"],"groupSize":2}')

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

echo "Assignment: landId=$LAND_ID, both players will connect"
echo ""

# 2. Run two clients in parallel to same game (guest mode allows both)
echo "Starting player 1..."
npx tsx src/cli.ts script \
    -u "$WS_URL" \
    -l "$LAND_ID" \
    -s scenarios/game/test-matchmaking-two-players.json \
    --state-update-encoding opcodeJsonArray &
P1_PID=$!

echo "Starting player 2 (same room, guest mode)..."
# Player 2: connect without token (GameServer guest mode allows)
BASE_WS="${CONNECT_URL}"
npx tsx src/cli.ts script \
    -u "$BASE_WS" \
    -l "$LAND_ID" \
    -s scenarios/game/test-matchmaking-two-players.json \
    --state-update-encoding opcodeJsonArray &
P2_PID=$!

wait $P1_PID
P1_EXIT=$?
wait $P2_PID
P2_EXIT=$?

if [ $P1_EXIT -ne 0 ] || [ $P2_EXIT -ne 0 ]; then
    echo "One or both players failed (p1=$P1_EXIT, p2=$P2_EXIT)"
    exit 1
fi

echo ""
echo "=========================================="
echo "  Matchmaking Two-Player E2E: PASS"
echo "=========================================="
