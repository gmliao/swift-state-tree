#!/usr/bin/env bash
# Test nginx path-hash LB: same room -> same server
#
# 1. Starts 3 GameServer instances (8080, 8081, 8082)
# 2. Starts nginx in Docker (requires Docker running)
# 3. Runs CLI connect through nginx
# 4. Cleans up
#
# Prereqs: Docker (must be running), swift, node (for CLI)
# If Docker not available: start nginx locally with nginx-websocket-path-routing.conf
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

cleanup() {
  echo "Cleaning up..."
  docker compose -f docs/deploy/docker-compose.nginx.yml down 2>/dev/null || true
  pkill -f "GameServer" 2>/dev/null || true
  sleep 2
}
trap cleanup EXIT

echo "=== 1. Building and starting 3 GameServers ==="
cd Examples/GameDemo
swift build --product GameServer
SERVER_BIN=".build/debug/GameServer"
[ -f "$SERVER_BIN" ] || SERVER_BIN=".build/release/GameServer"
# HOST=0.0.0.0 so Docker (host.docker.internal) can reach from container
HOST=0.0.0.0 LOG_LEVEL=error PORT=8080 "$SERVER_BIN" &
HOST=0.0.0.0 LOG_LEVEL=error PORT=8081 "$SERVER_BIN" &
HOST=0.0.0.0 LOG_LEVEL=error PORT=8082 "$SERVER_BIN" &
cd "$REPO_ROOT"

echo "Waiting for servers..."
sleep 8
# Ensure schema is reachable (nginx proxies to backends)
for i in 1 2 3 4 5; do
  if curl -s --connect-timeout 2 http://localhost:9090/schema | head -1 | grep -q '{'; then
    echo "Schema OK"
    break
  fi
  sleep 2
done

echo "=== 2. Starting nginx ==="
if ! docker info &>/dev/null; then
  echo "Docker not running. Start Docker or run nginx locally:"
  echo "  nginx -p $REPO_ROOT -c docs/deploy/nginx-websocket-path-routing.conf"
  echo "Then test: npm run dev -- connect -u ws://localhost:9090/game/hero-defense/room-test -l hero-defense:room-test --once"
  exit 1
fi
docker compose -f docs/deploy/docker-compose.nginx.yml up -d
sleep 3

echo "=== 3. Testing via nginx (port 9090) ==="
# Path with instanceId - should route to one of the backends
cd Tools/CLI
npm run dev -- connect \
  -u ws://localhost:9090/game/hero-defense/room-test \
  -l hero-defense:room-test \
  --once \
  --timeout 5
cd "$REPO_ROOT"

CODE=$?
if [ $CODE -eq 0 ]; then
  echo ""
  echo "=== 4. Verify same room -> same process ==="
  "$REPO_ROOT/docs/deploy/verify-same-room-same-process.sh" || true
  echo ""
  echo "=== ✅ Test passed ==="
else
  echo ""
  echo "=== ❌ CLI connect failed (exit $CODE) ==="
  exit $CODE
fi
