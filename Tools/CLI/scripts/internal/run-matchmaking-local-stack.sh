#!/bin/bash
# Start local matchmaking stack: control plane (with built-in provisioning), GameServerProvisioning
# Provisioning is built into control plane. GameServer registers via REST.
# Order: Control plane first, then GameServer (so it can register).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${E2E_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
cd "$PROJECT_ROOT"
TMP_DIR="${E2E_TMP_DIR:-$PROJECT_ROOT/tmp/e2e}"
CONTROL_PLANE_PORT="${MATCHMAKING_CONTROL_PLANE_PORT:-3000}"
GAME_PORT="${SERVER_PORT:-8080}"

mkdir -p "$TMP_DIR"

control_plane_pid=""
game_pid=""

echo "=========================================="
echo "  Matchmaking Local Stack"
echo "=========================================="
echo "Control plane (includes provisioning): $CONTROL_PLANE_PORT"
echo "GameServer:    $GAME_PORT"
echo ""

# Ensure control plane is built
if [ ! -f "$PROJECT_ROOT/Packages/matchmaking-control-plane/dist/src/main.js" ]; then
    echo "Building matchmaking-control-plane..."
    (cd "$PROJECT_ROOT/Packages/matchmaking-control-plane" && npm run build)
fi

# 1. Start control plane first (so GameServer can register)
echo "Starting control plane on port $CONTROL_PLANE_PORT..."
cd "$PROJECT_ROOT/Packages/matchmaking-control-plane"
PORT=$CONTROL_PLANE_PORT node dist/src/main.js >> "$TMP_DIR/control-plane.log" 2>&1 &
control_plane_pid=$!
echo $control_plane_pid > "$TMP_DIR/control-plane.pid"

# Wait for control plane health
for i in $(seq 1 15); do
    if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$CONTROL_PLANE_PORT/health" 2>/dev/null | grep -q 200; then
        break
    fi
    sleep 1
done

# 2. Start GameServer (registers to control plane when PROVISIONING_BASE_URL is set)
echo "Starting GameServer on port $GAME_PORT..."
cd "$PROJECT_ROOT"
HOST=127.0.0.1 PORT=$GAME_PORT PROVISIONING_BASE_URL="http://127.0.0.1:$CONTROL_PLANE_PORT" swift run --package-path Examples/GameDemo GameServer >> "$TMP_DIR/gameserver.log" 2>&1 &
game_pid=$!
echo $game_pid > "$TMP_DIR/gameserver.pid"

# 3. Wait for all services
echo "Waiting for services..."
for i in $(seq 1 30); do
    cp_ok=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$CONTROL_PLANE_PORT/health" 2>/dev/null || echo "000")
    game_ok=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$GAME_PORT/schema" 2>/dev/null || echo "000")
    if [ "$cp_ok" = "200" ] && [ "$game_ok" = "200" ]; then
        echo "All services ready!"
        echo "Control: http://127.0.0.1:$CONTROL_PLANE_PORT/health"
        echo "Game:    http://127.0.0.1:$GAME_PORT/schema"
        exit 0
    fi
    sleep 1
done

echo "Timeout waiting for services"
exit 1
