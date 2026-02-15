#!/bin/bash
# Matchmaking + nginx E2E: control plane, GameServer behind nginx, client connects via LB.
# Verifies connectUrl goes through nginx (PROVISIONING_CONNECT_HOST/PORT).
#
# Prereqs: Docker (for nginx). Run from project root or Tools/CLI.
# Ports: control plane 3000, game 8080, nginx 9090.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${E2E_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
CLI_DIR="$PROJECT_ROOT/Tools/CLI"
DEPLOY_DIR="$PROJECT_ROOT/docs/deploy"

CONTROL_PLANE_PORT="${MATCHMAKING_CONTROL_PLANE_PORT:-3000}"
GAME_PORT="${SERVER_PORT:-8080}"
NGINX_PORT="${NGINX_PORT:-9090}"

export MATCHMAKING_CONTROL_PLANE_URL="${MATCHMAKING_CONTROL_PLANE_URL:-http://127.0.0.1:$CONTROL_PLANE_PORT}"

CP_PID=""
GAME_PID=""

# Ensure matchmaking-control-plane is built
if [ ! -f "$PROJECT_ROOT/Packages/matchmaking-control-plane/dist/src/main.js" ]; then
    echo "Building matchmaking-control-plane..."
    (cd "$PROJECT_ROOT/Packages/matchmaking-control-plane" && npm run build)
fi

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
echo "  Matchmaking + nginx E2E"
echo "=========================================="
echo "Control plane: $CONTROL_PLANE_PORT"
echo "GameServer:    $GAME_PORT (behind nginx)"
echo "nginx:         $NGINX_PORT (client connects here)"
echo ""

# Pre-cleanup: free control plane and game ports only (keep nginx running)
kill_port() {
    local port=$1
    local pids
    pids=$(lsof -ti :$port 2>/dev/null) || true
    if [ -n "$pids" ]; then
        echo "Killing process(es) on port $port: $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
}
echo "Pre-cleanup: freeing control plane and game ports (nginx stays up)..."
if command -v lsof &>/dev/null; then
    kill_port $CONTROL_PLANE_PORT
    kill_port $GAME_PORT
fi
sleep 1

# Cleanup: stop only control plane and GameServer (nginx Docker stays running)
cleanup() {
    echo "Cleaning up (stopping control plane and GameServer, nginx stays up)..."
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

# 1. Start control plane
echo "Starting control plane..."
(cd "$PROJECT_ROOT/Packages/matchmaking-control-plane" && PORT=$CONTROL_PLANE_PORT node dist/src/main.js) &
CP_PID=$!
npx wait-on "http-get://127.0.0.1:$CONTROL_PLANE_PORT/health" -t 15000 || exit 1
sleep 2

# 2. Start nginx (Docker) - generate config with correct game port
if ! docker info &>/dev/null; then
    echo "Docker not running. Start Docker and retry."
    exit 1
fi
sed "s/host.docker.internal:8080/host.docker.internal:$GAME_PORT/g" \
    "$DEPLOY_DIR/nginx-matchmaking-e2e.docker.conf" \
    > "$DEPLOY_DIR/nginx-matchmaking-e2e.generated.conf"

# Start nginx if not running; if already up, reload config
if (cd "$DEPLOY_DIR" && docker compose -f docker-compose.matchmaking-nginx.yml -p matchmaking-nginx ps -q 2>/dev/null) | grep -q .; then
    echo "Reloading nginx config (proxying to game port $GAME_PORT)..."
    (cd "$DEPLOY_DIR" && docker compose -f docker-compose.matchmaking-nginx.yml -p matchmaking-nginx exec -T nginx nginx -s reload 2>/dev/null) || true
else
    echo "Starting nginx (proxying to game port $GAME_PORT)..."
    (cd "$DEPLOY_DIR" && docker compose -f docker-compose.matchmaking-nginx.yml -p matchmaking-nginx up -d)
fi
sleep 2

# 3. Start GameServer with connectHost/connectPort so connectUrl points to nginx
echo "Starting GameServer (registering with connectHost=localhost, connectPort=$NGINX_PORT)..."
export HOST=0.0.0.0
export PORT=$GAME_PORT
export PROVISIONING_BASE_URL=$MATCHMAKING_CONTROL_PLANE_URL
export PROVISIONING_CONNECT_HOST=localhost
export PROVISIONING_CONNECT_PORT=$NGINX_PORT
export PROVISIONING_CONNECT_SCHEME=ws
$GAME_BIN &
GAME_PID=$!
npx wait-on "http-get://127.0.0.1:$GAME_PORT/schema" -t 15000 || exit 1
sleep 3

# 4. Verify nginx LB routes to game server (schema via nginx)
echo "Verifying nginx LB routes to game server..."
if ! curl -s --connect-timeout 3 "http://127.0.0.1:$NGINX_PORT/schema" | head -1 | grep -q '{'; then
    echo "Error: nginx ($NGINX_PORT) did not proxy /schema to game server"
    exit 1
fi
echo "nginx LB OK: /schema proxied to game server"

# 5. Run MVP test (client must connect via nginx)
echo "Running matchmaking MVP test (client connects via nginx)..."
MATCHMAKING_CONTROL_PLANE_URL=$MATCHMAKING_CONTROL_PLANE_URL MATCHMAKING_EXPECT_NGINX_PORT=$NGINX_PORT npm run test:e2e:game:matchmaking:mvp

# 6. Two-player test: both connect to same game
echo ""
echo "Running two-player test (both in same game)..."
MATCHMAKING_CONTROL_PLANE_URL=$MATCHMAKING_CONTROL_PLANE_URL bash "$SCRIPT_DIR/run-matchmaking-two-players.sh"

echo ""
echo "=========================================="
echo "  Matchmaking + nginx E2E: PASS"
echo "=========================================="
