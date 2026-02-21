#!/bin/bash
# Matchmaking multi-server E2E: 2 GameServers, verify connectUrl points to a registered server.
# Enqueues 1 solo player, asserts connectUrl contains 8080 or 8081, runs scenario.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${E2E_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
CLI_DIR="$PROJECT_ROOT/Tools/CLI"

CONTROL_PLANE_PORT="${MATCHMAKING_CONTROL_PLANE_PORT:-3000}"
GAME_A_PORT="${GAME_A_PORT:-8080}"
GAME_B_PORT="${GAME_B_PORT:-8081}"
export MATCHMAKING_CONTROL_PLANE_URL="${MATCHMAKING_CONTROL_PLANE_URL:-http://127.0.0.1:$CONTROL_PLANE_PORT}"

CP_PID=""
GAME_A_PID=""
GAME_B_PID=""
TMP=""

kill_port() {
    local port=$1
    local pids
    pids=$(lsof -ti :$port 2>/dev/null) || true
    if [ -n "$pids" ]; then
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
}

cleanup() {
    echo "Cleaning up..."
    [ -n "$TMP" ] && [ -f "$TMP" ] && rm -f "$TMP"
    [ -n "$CP_PID" ] && kill -9 $CP_PID 2>/dev/null || true
    [ -n "$GAME_A_PID" ] && kill -9 $GAME_A_PID 2>/dev/null || true
    [ -n "$GAME_B_PID" ] && kill -9 $GAME_B_PID 2>/dev/null || true
    sleep 2
    kill_port $CONTROL_PLANE_PORT
    kill_port $GAME_A_PORT
    kill_port $GAME_B_PORT
    echo "Cleanup done."
}
trap cleanup EXIT INT TERM

# Ensure control-plane and GameServer are built
if [ ! -f "$PROJECT_ROOT/Packages/control-plane/dist/src/main.js" ]; then
    (cd "$PROJECT_ROOT/Packages/control-plane" && npm run build)
fi
GAME_BIN="$PROJECT_ROOT/Examples/GameDemo/.build/debug/GameServer"
if [ ! -x "$GAME_BIN" ]; then
    (cd "$PROJECT_ROOT" && swift build --package-path Examples/GameDemo)
fi

cd "$CLI_DIR"
if [ ! -d "node_modules" ]; then
    npm ci
fi

echo "=========================================="
echo "  Matchmaking Multi-Server E2E"
echo "=========================================="
echo "Control plane: $CONTROL_PLANE_PORT"
echo "GameServer A:  $GAME_A_PORT"
echo "GameServer B:  $GAME_B_PORT"
echo ""

kill_port $CONTROL_PLANE_PORT
kill_port $GAME_A_PORT
kill_port $GAME_B_PORT
kill_port 8082
sleep 1

# 1. Start control plane (REDIS_DB=2 to isolate from Jest e2e; MATCHMAKING_MIN_WAIT_MS=0 for fast e2e)
(cd "$PROJECT_ROOT/Packages/control-plane" && REDIS_DB=2 MATCHMAKING_MIN_WAIT_MS=0 PORT=$CONTROL_PLANE_PORT node dist/src/main.js) &
CP_PID=$!
npx wait-on "http-get://127.0.0.1:$CONTROL_PLANE_PORT/health" -t 15000 || exit 1
sleep 2

# 2. Start two GameServers (distinct serverIds so both register)
HOST=127.0.0.1 PORT=$GAME_A_PORT PROVISIONING_SERVER_ID=game-a TRANSPORT_ENCODING=jsonOpcode PROVISIONING_BASE_URL=$MATCHMAKING_CONTROL_PLANE_URL $GAME_BIN &
GAME_A_PID=$!
HOST=127.0.0.1 PORT=$GAME_B_PORT PROVISIONING_SERVER_ID=game-b TRANSPORT_ENCODING=jsonOpcode PROVISIONING_BASE_URL=$MATCHMAKING_CONTROL_PLANE_URL $GAME_BIN &
GAME_B_PID=$!

npx wait-on "http-get://127.0.0.1:$GAME_A_PORT/schema" -t 15000 || exit 1
npx wait-on "http-get://127.0.0.1:$GAME_B_PORT/schema" -t 15000 || exit 1
sleep 3


# 3. Enqueue player 1, verify connectUrl points to 8080 or 8081, run scenario
# Note: Single-player per run; two-player sequential enqueue has known control-plane timing issue.
echo "Enqueueing player 1..."
TMP=$(mktemp)
UNIQUE_ID="multi-$(date +%s)-$$"

ENQ1=$(curl -s -X POST "$MATCHMAKING_CONTROL_PLANE_URL/v1/matchmaking/enqueue" \
    -H "Content-Type: application/json" \
    -d "{\"groupId\":\"${UNIQUE_ID}-p1\",\"queueKey\":\"hero-defense:asia\",\"members\":[\"p1\"],\"groupSize\":1}")
echo "$ENQ1" > "$TMP"
TICKET1=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.ticketId) throw new Error('Missing ticketId'); console.log(d.ticketId)" "$TMP")

echo "Polling for assignment (ticketId=$TICKET1)..."
for i in $(seq 1 30); do
    STATUS=$(curl -s "$MATCHMAKING_CONTROL_PLANE_URL/v1/matchmaking/status/$TICKET1")
    echo "$STATUS" > "$TMP"
    S=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); console.log(d.status||'')" "$TMP")
    if [ "$S" = "assigned" ]; then break; fi
    [ $i -eq 30 ] && { echo "Timeout waiting for assignment"; exit 1; }
    sleep 1
done

CONNECT1=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.assignment?.connectUrl) throw new Error('Missing connectUrl'); console.log(d.assignment.connectUrl)" "$TMP")
TOKEN1=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.assignment?.matchToken) throw new Error('Missing matchToken'); console.log(d.assignment.matchToken)" "$TMP")
LAND1=$(node -e "const d=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8')); if(!d.assignment?.landId) throw new Error('Missing landId'); console.log(d.assignment.landId)" "$TMP")

if [[ "$CONNECT1" != *":$GAME_A_PORT"* ]] && [[ "$CONNECT1" != *":$GAME_B_PORT"* ]]; then
    echo "Error: connectUrl must contain port $GAME_A_PORT or $GAME_B_PORT, got: $CONNECT1"
    exit 1
fi
echo "Player 1 assigned to $CONNECT1"

WS1="${CONNECT1}"
[[ "$WS1" != *"?"* ]] && WS1="${WS1}?token=${TOKEN1}" || WS1="${WS1}&token=${TOKEN1}"
npx tsx src/cli.ts script -u "$WS1" -l "$LAND1" -s scenarios/game/test-multi-server-assignment.json --state-update-encoding opcodeJsonArray
echo "Player 1 scenario: PASS"
echo ""

echo "=========================================="
echo "  Matchmaking Multi-Server E2E: PASS"
echo "=========================================="
