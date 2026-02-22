#!/bin/bash
# Dev script: Start Control Plane + GameServer + nginx LB concurrently.
# Tests LB routing: client connects via nginx (9090), /match/* -> CP, /game/* -> GameServer.
# Verifies PROVISIONING_CONNECT_HOST/PORT (external route) and internal registration.
#
# Prereqs: Docker (for nginx), Redis. Run from Tools/CLI: npm run dev:matchmaking:nginx
# Ports: CP 3000, GameServer 8080, nginx 9090 (client entry).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CLI_DIR="$SCRIPT_DIR/../.."
DEPLOY_DIR="$PROJECT_ROOT/docs/deploy"

cd "$CLI_DIR"

CONTROL_PLANE_PORT="${MATCHMAKING_CONTROL_PLANE_PORT:-3000}"
GAME_PORT="${SERVER_PORT:-8080}"
NGINX_PORT="${NGINX_PORT:-9090}"

# Internal: GameServer registers directly to CP
export PROVISIONING_BASE_URL="${PROVISIONING_BASE_URL:-http://127.0.0.1:$CONTROL_PLANE_PORT}"
# External: connectUrl in assignment points to nginx (client-facing)
export PROVISIONING_CONNECT_HOST="${PROVISIONING_CONNECT_HOST:-localhost}"
export PROVISIONING_CONNECT_PORT="${PROVISIONING_CONNECT_PORT:-$NGINX_PORT}"
export PROVISIONING_CONNECT_SCHEME="${PROVISIONING_CONNECT_SCHEME:-ws}"

# Ensure control-plane is built
if [ ! -f "$PROJECT_ROOT/Packages/control-plane/dist/src/main.js" ]; then
    echo "Building control-plane..."
    (cd "$PROJECT_ROOT/Packages/control-plane" && npm run build)
fi

GAME_BIN="$PROJECT_ROOT/Examples/GameDemo/.build/debug/GameServer"
if [ ! -x "$GAME_BIN" ]; then
    echo "Building GameServer..."
    (cd "$PROJECT_ROOT" && swift build --package-path Examples/GameDemo)
fi

if ! docker info &>/dev/null; then
    echo "Docker not running. Start Docker and retry."
    exit 1
fi

# Generate nginx config
sed -e "s/__GAME_PORT__/$GAME_PORT/g" \
    -e "s/__CONTROL_PLANE_PORT__/$CONTROL_PLANE_PORT/g" \
    "$DEPLOY_DIR/nginx-matchmaking-e2e.docker.conf" \
    > "$DEPLOY_DIR/nginx-matchmaking-e2e.generated.conf"

# Start or reload nginx
if (cd "$DEPLOY_DIR" && docker compose -f docker-compose.matchmaking-nginx.yml -p matchmaking-nginx ps -q 2>/dev/null) | grep -q .; then
    echo "Reloading nginx config..."
    (cd "$DEPLOY_DIR" && docker compose -f docker-compose.matchmaking-nginx.yml -p matchmaking-nginx exec -T nginx nginx -s reload 2>/dev/null) || true
else
    echo "Starting nginx..."
    (cd "$DEPLOY_DIR" && docker compose -f docker-compose.matchmaking-nginx.yml -p matchmaking-nginx up -d)
fi
sleep 2

echo "=========================================="
echo "  Matchmaking Dev Stack (nginx LB)"
echo "=========================================="
echo "Client entry (LB):  http://127.0.0.1:$NGINX_PORT"
echo "  /match/* -> Control Plane (internal :$CONTROL_PLANE_PORT)"
echo "  /game/*  -> GameServer (internal :$GAME_PORT)"
echo ""
echo "Control Plane: :$CONTROL_PLANE_PORT (internal)"
echo "GameServer:    :$GAME_PORT (internal)"
echo "connectUrl:    ws://$PROVISIONING_CONNECT_HOST:$PROVISIONING_CONNECT_PORT/game/... (external)"
echo ""
echo "Press Ctrl+C to stop CP and GameServer (nginx stays up)."
echo ""

npx concurrently -n cp,game \
  -c blue,green \
  "cd $PROJECT_ROOT/Packages/control-plane && PORT=$CONTROL_PLANE_PORT REDIS_DB=0 MATCHMAKING_MIN_WAIT_MS=0 node dist/src/main.js" \
  "cd $PROJECT_ROOT/Examples/GameDemo && HOST=0.0.0.0 PORT=$GAME_PORT TRANSPORT_ENCODING=jsonOpcode PROVISIONING_BASE_URL=$PROVISIONING_BASE_URL PROVISIONING_CONNECT_HOST=$PROVISIONING_CONNECT_HOST PROVISIONING_CONNECT_PORT=$PROVISIONING_CONNECT_PORT PROVISIONING_CONNECT_SCHEME=$PROVISIONING_CONNECT_SCHEME swift run GameServer"
