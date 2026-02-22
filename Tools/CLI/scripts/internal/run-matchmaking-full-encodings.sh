#!/bin/bash
# Matchmaking MVP E2E across all encodings: jsonObject, opcodeJsonArray, messagepack.
# Starts CP once, then for each encoding: start GameServer with TRANSPORT_ENCODING,
# run MVP with matching --state-update-encoding, stop GameServer.
#
# Run from project root or Tools/CLI. Requires Redis.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${E2E_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
CLI_DIR="$PROJECT_ROOT/Tools/CLI"

CONTROL_PLANE_PORT="${MATCHMAKING_CONTROL_PLANE_PORT:-3000}"
GAME_PORT="${SERVER_PORT:-8080}"
export MATCHMAKING_CONTROL_PLANE_URL="${MATCHMAKING_CONTROL_PLANE_URL:-http://127.0.0.1:$CONTROL_PLANE_PORT}"

# Ensure control-plane is built
if [ ! -f "$PROJECT_ROOT/Packages/control-plane/dist/src/main.js" ]; then
    echo "Building control-plane..."
    (cd "$PROJECT_ROOT/Packages/control-plane" && npm run build)
fi

# Pre-build GameServer
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
echo "  Matchmaking MVP All Encodings E2E"
echo "=========================================="
echo "Control plane: $CONTROL_PLANE_PORT"
echo "GameServer:    $GAME_PORT"
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
    echo "Cleaning up..."
    [ -n "$GAME_PID" ] && kill -9 $GAME_PID 2>/dev/null || true
    [ -n "$CP_PID" ] && kill -9 $CP_PID 2>/dev/null || true
    sleep 2
    if command -v lsof &>/dev/null; then
        kill_port $CONTROL_PLANE_PORT
        kill_port $GAME_PORT
    fi
    echo "Cleanup done."
}
trap cleanup EXIT INT TERM

kill_port $CONTROL_PLANE_PORT
kill_port $GAME_PORT
sleep 1

# Start control plane once
(cd "$PROJECT_ROOT/Packages/control-plane" && PORT=$CONTROL_PLANE_PORT REDIS_DB=2 MATCHMAKING_MIN_WAIT_MS=0 node dist/src/main.js) &
CP_PID=$!
npx wait-on "http-get://127.0.0.1:$CONTROL_PLANE_PORT/health" -t 15000 || exit 1
sleep 2

# Encoding mapping: TRANSPORT_ENCODING -> CLI --state-update-encoding
run_mvp_for_encoding() {
    local transport_encoding=$1
    local state_update_encoding=$2
    echo ""
    echo "=========================================="
    echo "  Encoding: $state_update_encoding"
    echo "=========================================="

    kill_port $GAME_PORT
    sleep 1

    HOST=127.0.0.1 PORT=$GAME_PORT TRANSPORT_ENCODING=$transport_encoding PROVISIONING_BASE_URL=$MATCHMAKING_CONTROL_PLANE_URL $GAME_BIN &
    GAME_PID=$!
    npx wait-on "http-get://127.0.0.1:$GAME_PORT/schema" -t 15000 || exit 1
    sleep 2

    MATCHMAKING_CONTROL_PLANE_URL=$MATCHMAKING_CONTROL_PLANE_URL MATCHMAKING_STATE_UPDATE_ENCODING=$state_update_encoding bash "$SCRIPT_DIR/run-matchmaking-mvp.sh"

    kill -9 $GAME_PID 2>/dev/null || true
    GAME_PID=""
    sleep 2
}

run_mvp_for_encoding "json" "jsonObject"
run_mvp_for_encoding "jsonOpcode" "opcodeJsonArray"
run_mvp_for_encoding "messagepack" "messagepack"

echo ""
echo "=========================================="
echo "  Matchmaking All Encodings E2E: PASS"
echo "=========================================="
