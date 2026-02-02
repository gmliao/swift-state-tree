#!/usr/bin/env bash
set -euo pipefail

SCENARIO="scenarios/hero-defense/default.json"
WORKERS=""
OUTPUT_DIR="results"
STARTUP_TIMEOUT=60
ENABLE_PROFILING=false

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
    --profile)
      ENABLE_PROFILING=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--scenario <path>] [--workers <N>] [--output-dir <dir>] [--startup-timeout <seconds>] [--profile]"
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

# Safety: ensure we connect to the server we start.
# If 8080 is already in use, the test may accidentally run against an existing GameServer
# (and could generate reevaluation records, noisy logs, etc.).
if nc -z localhost 8080 >/dev/null 2>&1; then
  echo "Port 8080 is already in use. Please stop the existing server before running this script."
  echo "Tip: check with: lsof -nP -iTCP:8080 -sTCP:LISTEN"
  exit 1
fi

# Server: only errors; no reevaluation writing. Export so child process (GameServer) sees them.
export ENABLE_REEVALUATION=false
export LOG_LEVEL=error
export NO_COLOR=1

# Isolate reevaluation outputs during load tests so we can verify "no writes" deterministically
# and avoid polluting the repo working tree.
export REEVALUATION_RECORDS_DIR="/tmp/ws-loadtest-reevaluation-records"
rm -rf "$REEVALUATION_RECORDS_DIR" >/dev/null 2>&1 || true
mkdir -p "$REEVALUATION_RECORDS_DIR" >/dev/null 2>&1 || true

# Transport profiling: when --profile is used, server writes JSONL (per-run when output-dir is used)
if [ "$ENABLE_PROFILING" = true ]; then
  export TRANSPORT_PROFILE_JSONL_PATH="$ROOT_DIR/$OUTPUT_DIR/transport-profile.jsonl"
  mkdir -p "$(dirname "$TRANSPORT_PROFILE_JSONL_PATH")" 2>/dev/null || true
  rm -f "$TRANSPORT_PROFILE_JSONL_PATH" 2>/dev/null || true
  echo "Transport profiling enabled: $TRANSPORT_PROFILE_JSONL_PATH"
fi

echo "Starting GameServer (release, LOG_LEVEL=error, ENABLE_REEVALUATION=false; log file: /tmp/ws-loadtest-gameserver.log)..."
cd "$GAMEDEMO_DIR"
# NOTE: Use the built product directly instead of `swift run` so the environment
# variables above are guaranteed to reach the GameServer process.
swift build -c release --product GameServer >/tmp/ws-loadtest-gameserver.build.log 2>&1 || true
BIN_DIR=$(swift build -c release --show-bin-path 2>/dev/null || true)
SERVER_BIN="$BIN_DIR/GameServer"
if [ -z "$BIN_DIR" ] || [ ! -x "$SERVER_BIN" ]; then
  echo "Failed to locate GameServer binary (binDir='$BIN_DIR')."
  echo "---- swift build log (tail) ----"
  tail -n 120 /tmp/ws-loadtest-gameserver.build.log 2>/dev/null || true
  exit 1
fi
"$SERVER_BIN" >/tmp/ws-loadtest-gameserver.log 2>&1 &
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
  tail -n 50 /tmp/ws-loadtest-gameserver.log || true
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
# If server already exited (e.g. Abort trap: 6 = SIGABRT during load), kill is no-op; wait reports status.
# Abort trap: 6 means GameServer crashed during the test, not from this kill.
kill "$SERVER_PID" >/dev/null 2>&1 || true
if ! wait "$SERVER_PID" 2>/dev/null; then
    echo "---- GameServer log (tail, may show crash) ----"
    tail -n 80 /tmp/ws-loadtest-gameserver.log 2>/dev/null || true
fi

REEVAL_COUNT=$(ls -1 "$REEVALUATION_RECORDS_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REEVAL_COUNT" != "0" ]; then
  echo "WARNING: Unexpected reevaluation records were generated in $REEVALUATION_RECORDS_DIR ($REEVAL_COUNT files)."
else
  echo "Reevaluation: no records generated (as expected)."
fi

echo "Done. Reports in $ROOT_DIR/$OUTPUT_DIR"
