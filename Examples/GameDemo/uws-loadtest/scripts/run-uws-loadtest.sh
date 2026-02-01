#!/usr/bin/env bash
set -euo pipefail

SCENARIO="scenarios/hero-defense/default.json"
WORKERS=""
OUTPUT_DIR="results"
STARTUP_TIMEOUT=60

while [[ $# -gt 0 ]]; do
  case $1 in
    --scenario)
      SCENARIO="$2"
      shift 2
      ;;
    --workers)
      WORKERS="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --startup-timeout)
      STARTUP_TIMEOUT="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--scenario <path>] [--workers <N>] [--output-dir <dir>] [--startup-timeout <seconds>]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GAMEDEMO_DIR="$(cd "$ROOT_DIR/.." && pwd)"

SCENARIO_PATH="$ROOT_DIR/$SCENARIO"
SYSTEM_METRICS_PATH="$ROOT_DIR/monitoring/system-metrics.json"

if [ ! -f "$SCENARIO_PATH" ]; then
  echo "Scenario not found: $SCENARIO_PATH"
  exit 1
fi

TOTAL_DURATION=$(node -e "const fs=require('fs'); const s=JSON.parse(fs.readFileSync('$SCENARIO_PATH','utf-8')); const p=s.phases||{}; const sum=(p.preflight?.durationSeconds||0)+(p.steady?.durationSeconds||0)+(p.postflight?.durationSeconds||0); console.log(sum||60);")
TIMEOUT=$((TOTAL_DURATION + 30))

echo "Starting GameServer..."
cd "$GAMEDEMO_DIR"
swift run GameServer >/tmp/uws-loadtest-gameserver.log 2>&1 &
SERVER_PID=$!

echo "Waiting for server to listen on 8080..."
READY=false
for _ in $(seq 1 "$STARTUP_TIMEOUT"); do
  if nc -z localhost 8080 >/dev/null 2>&1; then
    READY=true
    break
  fi
  sleep 1
done

if [ "$READY" = false ]; then
  echo "Server did not start in time. Killing..."
  echo "---- GameServer log (tail) ----"
  tail -n 50 /tmp/uws-loadtest-gameserver.log || true
  kill -9 "$SERVER_PID" || true
  exit 1
fi

echo "Starting system monitoring..."
cd "$ROOT_DIR"
rm -f "$SYSTEM_METRICS_PATH"
bash "$ROOT_DIR/monitoring/collect-system-metrics.sh" "$SERVER_PID" "$SYSTEM_METRICS_PATH" 1 &
MONITOR_PID=$!

cd "$ROOT_DIR"
npm run build

CMD=(node dist/cli.js --scenario "$SCENARIO" --system-metrics "$SYSTEM_METRICS_PATH" --output-dir "$OUTPUT_DIR")
if [ -n "$WORKERS" ]; then
  CMD+=(--workers "$WORKERS")
fi

echo "Running load test..."
"${CMD[@]}" &
CLI_PID=$!

SECONDS=0
while kill -0 "$CLI_PID" >/dev/null 2>&1; do
  if [ "$SECONDS" -gt "$TIMEOUT" ]; then
    echo "Load test timed out after ${TIMEOUT}s. Killing..."
    kill -9 "$CLI_PID" || true
    break
  fi
  sleep 1
done

wait "$CLI_PID" || true

echo "Stopping monitoring..."
kill "$MONITOR_PID" >/dev/null 2>&1 || true
wait "$MONITOR_PID" >/dev/null 2>&1 || true

echo "Stopping GameServer..."
kill "$SERVER_PID" >/dev/null 2>&1 || true
wait "$SERVER_PID" >/dev/null 2>&1 || true

echo "Done. Reports in $ROOT_DIR/$OUTPUT_DIR"
