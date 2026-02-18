#!/usr/bin/env bash
# E2E test for api + queue-worker split (two separate processes).
# Requires: Redis running (docker compose up -d).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
API_PORT="${E2E_API_PORT:-3010}"
WORKER_PORT="${E2E_WORKER_PORT:-3011}"

cd "$PROJECT_ROOT"

# Kill any existing processes on ports to avoid conflicts
kill_port() {
  local port=$1
  local pids
  pids=$(lsof -ti:"$port" 2>/dev/null) || true
  if [ -n "$pids" ]; then
    echo "[e2e-split] Killing existing process on port $port (PIDs: $pids)..."
    echo "$pids" | xargs kill -9 2>/dev/null || true
    sleep 1
  fi
}
echo "[e2e-split] Clearing ports $API_PORT and $WORKER_PORT..."
kill_port "$API_PORT"
kill_port "$WORKER_PORT"

# Build
echo "[e2e-split] Building..."
npm run build --silent

# Start queue-worker first (must be ready to consume before API adds jobs)
echo "[e2e-split] Starting queue-worker on port $WORKER_PORT..."
REDIS_HOST=127.0.0.1 REDIS_PORT=6379 MATCHMAKING_ROLE=queue-worker MATCHMAKING_MIN_WAIT_MS=0 PORT="$WORKER_PORT" node dist/src/main.js &
WORKER_PID=$!
sleep 2

# Start API (background)
echo "[e2e-split] Starting API on port $API_PORT..."
REDIS_HOST=127.0.0.1 REDIS_PORT=6379 MATCHMAKING_ROLE=api MATCHMAKING_MIN_WAIT_MS=0 PORT="$API_PORT" node dist/src/main.js &
API_PID=$!

cleanup() {
  echo "[e2e-split] Shutting down..."
  kill $WORKER_PID 2>/dev/null || true
  kill $API_PID 2>/dev/null || true
  wait $WORKER_PID 2>/dev/null || true
  wait $API_PID 2>/dev/null || true
}
trap cleanup EXIT

# Wait for health
echo "[e2e-split] Waiting for servers..."
for i in {1..30}; do
  if curl -sf "http://127.0.0.1:$WORKER_PORT/health" >/dev/null 2>&1 && \
     curl -sf "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1; then
    echo "[e2e-split] Servers ready"
    break
  fi
  if [ $i -eq 30 ]; then
    echo "[e2e-split] Timeout waiting for servers"
    exit 1
  fi
  sleep 0.5
done

# Extra wait for BullMQ worker to start consuming
sleep 5

# Run external e2e test (hits running servers, no app spawn)
echo "[e2e-split] Running e2e tests..."
E2E_API_PORT="$API_PORT" E2E_WORKER_PORT="$WORKER_PORT" npm run test:e2e -- --testPathPattern=matchmaking-split-roles-external --forceExit

echo "[e2e-split] Done"
