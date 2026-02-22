#!/bin/bash
# Dev script: Start Control Plane + GameServer concurrently for matchmaking development.
# Requires: Redis running (localhost:6379), control-plane and GameServer built.
#
# Usage: from Tools/CLI: npm run dev:matchmaking
#        or: bash scripts/dev-matchmaking-stack.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLI_DIR="$SCRIPT_DIR/../.."

cd "$CLI_DIR"

# Ensure control-plane is built
if [ ! -f "$PROJECT_ROOT/Packages/control-plane/dist/src/main.js" ]; then
    echo "Building control-plane..."
    (cd "$PROJECT_ROOT/Packages/control-plane" && npm run build)
fi

# Ensure GameServer is built
GAME_BIN="$PROJECT_ROOT/Examples/GameDemo/.build/debug/GameServer"
if [ ! -x "$GAME_BIN" ]; then
    echo "Building GameServer..."
    (cd "$PROJECT_ROOT" && swift build --package-path Examples/GameDemo)
fi

CONTROL_PLANE_PORT="${MATCHMAKING_CONTROL_PLANE_PORT:-3000}"
GAME_PORT="${SERVER_PORT:-8080}"
export MATCHMAKING_CONTROL_PLANE_URL="${MATCHMAKING_CONTROL_PLANE_URL:-http://127.0.0.1:$CONTROL_PLANE_PORT}"

echo "=========================================="
echo "  Matchmaking Dev Stack"
echo "=========================================="
echo "Control Plane: http://127.0.0.1:$CONTROL_PLANE_PORT"
echo "GameServer:    ws://127.0.0.1:$GAME_PORT/game/hero-defense"
echo ""
echo "Press Ctrl+C to stop all."
echo ""

npx concurrently -n cp,game \
  -c blue,green \
  "cd $PROJECT_ROOT/Packages/control-plane && PORT=$CONTROL_PLANE_PORT REDIS_DB=0 MATCHMAKING_MIN_WAIT_MS=0 node dist/src/main.js" \
  "cd $PROJECT_ROOT/Examples/GameDemo && HOST=127.0.0.1 PORT=$GAME_PORT TRANSPORT_ENCODING=jsonOpcode PROVISIONING_BASE_URL=$MATCHMAKING_CONTROL_PLANE_URL swift run GameServer"
