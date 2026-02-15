#!/bin/bash
# Matchmaking MVP E2E test: get assignment from control plane, connect to game server, run scenario
set -e

CONTROL_PLANE_URL="${MATCHMAKING_CONTROL_PLANE_URL:-http://127.0.0.1:3000}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CLI_DIR="$PROJECT_ROOT/Tools/CLI"

cd "$CLI_DIR"

# Ensure dependencies
if [ ! -d "node_modules" ]; then
    npm ci
fi

echo "=========================================="
echo "  Matchmaking MVP E2E Test"
echo "=========================================="
echo "Control plane: $CONTROL_PLANE_URL"
echo ""

# 1. Enqueue and poll until assigned
echo "Calling control plane enqueue..."
ENQUEUE_RESPONSE=$(curl -s -X POST "$CONTROL_PLANE_URL/v1/matchmaking/enqueue" \
    -H "Content-Type: application/json" \
    -d '{"groupId":"mvp-test-1","queueKey":"hero-defense:asia","members":["p1"],"groupSize":1}')

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
if [ -n "$MATCHMAKING_EXPECT_NGINX_PORT" ] && [[ "$CONNECT_URL" != *":$MATCHMAKING_EXPECT_NGINX_PORT"* ]]; then
    echo "Error: connectUrl must go through nginx (port $MATCHMAKING_EXPECT_NGINX_PORT) but got: $CONNECT_URL"
    exit 1
fi
MATCH_TOKEN=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.assignment?.matchToken) throw new Error('Missing matchToken'); console.log(d.assignment.matchToken)" "$TMP")
LAND_ID=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.assignment?.landId) throw new Error('Missing landId'); console.log(d.assignment.landId)" "$TMP")

WS_URL="${CONNECT_URL}"
if [[ "$WS_URL" == *"?"* ]]; then
    WS_URL="${WS_URL}&token=${MATCH_TOKEN}"
else
    WS_URL="${WS_URL}?token=${MATCH_TOKEN}"
fi

echo "Assignment received: connectUrl with token, landId=$LAND_ID"
echo ""

# 2. Run scenario with assignment
echo "Running game scenario with assignment..."
npx tsx src/cli.ts script \
    -u "$WS_URL" \
    -l "$LAND_ID" \
    -s scenarios/game/test-matchmaking-assignment-flow.json \
    --state-update-encoding opcodeJsonArray

echo ""
echo "=========================================="
echo "  Matchmaking MVP E2E: PASS"
echo "=========================================="
