#!/bin/bash
# Start matchmaking control plane + GameServer, run E2E test.
# Provisioning is built into control plane (NestJS). GameServer registers via REST.
# Run from project root or Tools/CLI.
#
# If ports in use: set MATCHMAKING_CONTROL_PLANE_PORT, SERVER_PORT.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${E2E_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
CLI_DIR="$PROJECT_ROOT/Tools/CLI"

CONTROL_PLANE_PORT="${MATCHMAKING_CONTROL_PLANE_PORT:-3000}"
GAME_PORT="${SERVER_PORT:-8080}"
export MATCHMAKING_CONTROL_PLANE_URL="${MATCHMAKING_CONTROL_PLANE_URL:-http://127.0.0.1:$CONTROL_PLANE_PORT}"

# Ensure matchmaking-control-plane is built
if [ ! -f "$PROJECT_ROOT/Packages/matchmaking-control-plane/dist/src/main.js" ]; then
    echo "Building matchmaking-control-plane..."
    (cd "$PROJECT_ROOT/Packages/matchmaking-control-plane" && npm run build)
fi

# Pre-build GameServer (with PROVISIONING_BASE_URL it registers to control plane)
GAME_BIN="$PROJECT_ROOT/Examples/GameDemo/.build/debug/GameServer"
if [ ! -x "$GAME_BIN" ]; then
    echo "Building GameServer..."
    (cd "$PROJECT_ROOT" && swift build --package-path Examples/GameDemo)
fi

cd "$CLI_DIR"
if [ ! -d "node_modules" ]; then
    npm ci
fi

echo "=========================================="
echo "  Matchmaking Full Stack + E2E Test"
echo "=========================================="
echo "GameServer:    $GAME_PORT"
echo "Control plane: $CONTROL_PLANE_PORT (includes provisioning)"
echo ""

CP_PID=""
GAME_PID=""

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
    echo "Cleaning up (stopping servers)..."
    [ -n "$CP_PID" ] && kill -9 $CP_PID 2>/dev/null || true
    [ -n "$GAME_PID" ] && kill -9 $GAME_PID 2>/dev/null || true
    sleep 2
    if command -v lsof &>/dev/null; then
        kill_port $CONTROL_PLANE_PORT
        kill_port $GAME_PORT
    fi
    echo "Cleanup done."
}
trap cleanup EXIT INT TERM

# Start control plane first, wait for health, then start game (so it can register)
(cd "$PROJECT_ROOT/Packages/matchmaking-control-plane" && PORT=$CONTROL_PLANE_PORT node dist/src/main.js) &
CP_PID=$!
npx wait-on "http-get://127.0.0.1:$CONTROL_PLANE_PORT/health" -t 15000 || exit 1
sleep 2

# Start game
HOST=127.0.0.1 PORT=$GAME_PORT PROVISIONING_BASE_URL=$MATCHMAKING_CONTROL_PLANE_URL $GAME_BIN &
GAME_PID=$!
npx wait-on "http-get://127.0.0.1:$GAME_PORT/schema" -t 15000 || exit 1
sleep 3

# Run MVP test
MATCHMAKING_CONTROL_PLANE_URL=$MATCHMAKING_CONTROL_PLANE_URL npm run test:e2e:game:matchmaking:mvp
