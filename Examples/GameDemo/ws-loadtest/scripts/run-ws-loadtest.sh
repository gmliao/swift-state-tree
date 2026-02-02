#!/usr/bin/env bash
set -euo pipefail

# Auto-adjust system parameters for optimal WebSocket performance
check_and_adjust_system_params() {
  local adjusted=false
  
  # Check TCP SYN backlog (recommended: 4096 for high connection count)
  local current_syn_backlog=$(cat /proc/sys/net/ipv4/tcp_max_syn_backlog 2>/dev/null || echo "0")
  if [ "$current_syn_backlog" -lt 4096 ]; then
    echo "Adjusting tcp_max_syn_backlog: $current_syn_backlog -> 4096"
    sysctl -w net.ipv4.tcp_max_syn_backlog=4096 >/dev/null 2>&1 || echo "  (failed, need sudo)"
    adjusted=true
  fi
  
  # Check somaxconn (listen backlog)
  local current_somaxconn=$(cat /proc/sys/net/core/somaxconn 2>/dev/null || echo "0")
  if [ "$current_somaxconn" -lt 4096 ]; then
    echo "Adjusting somaxconn: $current_somaxconn -> 4096"
    sysctl -w net.core.somaxconn=4096 >/dev/null 2>&1 || echo "  (failed, need sudo)"
    adjusted=true
  fi
  
  # Enable TCP TIME_WAIT reuse (faster cleanup between tests)
  local current_tw_reuse=$(cat /proc/sys/net/ipv4/tcp_tw_reuse 2>/dev/null || echo "0")
  if [ "$current_tw_reuse" != "1" ]; then
    echo "Enabling tcp_tw_reuse for faster connection cleanup"
    sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || echo "  (failed, need sudo)"
    adjusted=true
  fi
  
  # Reduce FIN timeout (faster cleanup, default 60s -> 30s)
  local current_fin_timeout=$(cat /proc/sys/net/ipv4/tcp_fin_timeout 2>/dev/null || echo "60")
  if [ "$current_fin_timeout" -gt 30 ]; then
    echo "Adjusting tcp_fin_timeout: ${current_fin_timeout}s -> 30s"
    sysctl -w net.ipv4.tcp_fin_timeout=30 >/dev/null 2>&1 || echo "  (failed, need sudo)"
    adjusted=true
  fi
  
  if [ "$adjusted" = false ]; then
    echo "System parameters already optimal"
  fi
}

echo "Checking system parameters..."
check_and_adjust_system_params
echo ""

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

# Check if server is listening on 8080. Use nc, curl, or bash /dev/tcp (nc may be unavailable in minimal envs).
check_port_8080() {
  if command -v nc >/dev/null 2>&1 && nc -z localhost 8080 >/dev/null 2>&1; then
    return 0
  fi
  if command -v curl >/dev/null 2>&1 && curl -s -o /dev/null -w "%{http_code}" --connect-timeout 1 http://localhost:8080/health 2>/dev/null | grep -q 200; then
    return 0
  fi
  if (echo >/dev/tcp/localhost/8080) 2>/dev/null; then
    return 0
  fi
  return 1
}

# Safety: ensure we connect to the server we start.
# If 8080 is already in use, the test may accidentally run against an existing GameServer
# (and could generate reevaluation records, noisy logs, etc.).
if check_port_8080; then
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
# Use stdbuf (Linux) to force line-buffered output so logs appear immediately when
# server crashes or is killed. On macOS stdbuf may not work; fallback to direct run.
if command -v stdbuf >/dev/null 2>&1; then
  stdbuf -oL -eL "$SERVER_BIN" >/tmp/ws-loadtest-gameserver.log 2>&1 &
else
  "$SERVER_BIN" >/tmp/ws-loadtest-gameserver.log 2>&1 &
fi
SERVER_PID=$!

echo "Waiting for server to listen on 8080..."
READY=false
for _ in $(seq 1 "$STARTUP_TIMEOUT"); do
  if check_port_8080; then
    READY=true
    break
  fi
  sleep 1
done

if [ "$READY" = false ]; then
  echo "Server did not start in time. Killing..."
  echo "---- GameServer log (tail) ----"
  tail -n 50 /tmp/ws-loadtest-gameserver.log 2>/dev/null || true
  # If log is empty (e.g. server crashed before flushing, or LOG_LEVEL=error hides startup msgs),
  # show build log as fallback to help debug.
  if [ ! -s /tmp/ws-loadtest-gameserver.log ]; then
    echo "(GameServer log empty - showing build log as fallback)"
    tail -n 80 /tmp/ws-loadtest-gameserver.build.log 2>/dev/null || true
    echo ""
    echo "Tip: Run manually with LOG_LEVEL=info to see startup logs:"
    echo "  cd $GAMEDEMO_DIR && LOG_LEVEL=info $SERVER_BIN"
  fi
  kill -9 "$SERVER_PID" 2>/dev/null || true
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
    kill -9 "$CLI_PID" 2>/dev/null || true
    # Kill any child processes spawned by CLI
    pkill -9 -P "$CLI_PID" 2>/dev/null || true
    break
  fi
  sleep 1
done

# Ensure CLI process is truly dead
if kill -0 "$CLI_PID" 2>/dev/null; then
  kill -9 "$CLI_PID" 2>/dev/null || true
  pkill -9 -P "$CLI_PID" 2>/dev/null || true
fi
wait "$CLI_PID" 2>/dev/null || true

echo "Stopping monitoring..."
kill "$MONITOR_PID" >/dev/null 2>&1 || true
# Give monitoring process time to exit gracefully
for _ in $(seq 1 3); do
  if ! kill -0 "$MONITOR_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done
# Force kill if still running
if kill -0 "$MONITOR_PID" 2>/dev/null; then
  kill -9 "$MONITOR_PID" 2>/dev/null || true
fi

echo "Stopping GameServer..."
# If server already exited (e.g. Abort trap: 6 = SIGABRT during load), kill is no-op; wait reports status.
# Abort trap: 6 means GameServer crashed during the test, not from this kill.
kill "$SERVER_PID" >/dev/null 2>&1 || true

# Wait with timeout (max 10 seconds) to avoid blocking forever on unresponsive servers.
# Under extreme load (e.g., 700 rooms), the server may become unresponsive and never exit.
WAIT_TIMEOUT=10
WAITED=0
while kill -0 "$SERVER_PID" 2>/dev/null && [ "$WAITED" -lt "$WAIT_TIMEOUT" ]; do
  sleep 1
  WAITED=$((WAITED + 1))
done

# Check if server exited abnormally (non-zero exit code or still running after timeout)
if kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "GameServer did not terminate after ${WAIT_TIMEOUT}s. Forcing shutdown with SIGKILL..."
  kill -9 "$SERVER_PID" 2>/dev/null || true
  sleep 1
elif ! wait "$SERVER_PID" 2>/dev/null; then
  echo "---- GameServer log (tail, may show crash) ----"
  tail -n 80 /tmp/ws-loadtest-gameserver.log 2>/dev/null || true
  if [ ! -s /tmp/ws-loadtest-gameserver.log ]; then
    echo "(GameServer log empty - showing build log as fallback)"
    tail -n 80 /tmp/ws-loadtest-gameserver.build.log 2>/dev/null || true
  fi
fi

# Final check: ensure process is truly dead
if kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "WARNING: GameServer still running after SIGKILL. This should not happen."
  kill -9 "$SERVER_PID" 2>/dev/null || true
  sleep 2
fi

# Verify port 8080 is released (fallback: kill any process still holding it)
if check_port_8080; then
  echo "WARNING: Port 8080 still in use after stopping GameServer. Attempting cleanup..."
  STALE_PID=$(lsof -t -i:8080 2>/dev/null | head -1)
  if [ -n "$STALE_PID" ]; then
    echo "Killing stale process on port 8080 (PID: $STALE_PID)"
    kill -9 "$STALE_PID" 2>/dev/null || true
    sleep 1
  fi
fi

REEVAL_COUNT=$(ls -1 "$REEVALUATION_RECORDS_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REEVAL_COUNT" != "0" ]; then
  echo "WARNING: Unexpected reevaluation records were generated in $REEVALUATION_RECORDS_DIR ($REEVAL_COUNT files)."
else
  echo "Reevaluation: no records generated (as expected)."
fi

echo "Done. Reports in $ROOT_DIR/$OUTPUT_DIR"
