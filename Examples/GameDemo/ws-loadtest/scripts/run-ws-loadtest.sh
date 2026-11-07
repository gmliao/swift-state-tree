#!/usr/bin/env bash
set -euo pipefail

# Auto-adjust system parameters for optimal WebSocket performance (Linux only).
# macOS uses BSD TCP stack and does not have /proc or these sysctl names; adjustments are skipped.
check_and_adjust_system_params() {
  case "$(uname -s)" in
    Linux)
      _check_and_adjust_linux
      ;;
    Darwin)
      echo "macOS detected: Linux TCP tuning (tcp_max_syn_backlog, somaxconn, etc.) not applicable; using defaults."
      ;;
    *)
      echo "OS $(uname -s): Linux TCP tuning not applicable; using defaults."
      ;;
  esac
}

_check_and_adjust_linux() {
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
LAYOUT=""
CONNECT_MODE=""
CONNECT_RATE=""
BOUNDARY=""
ALLOW_PARTIAL_RAMP=false
ALLOW_JOIN_FAILURES=false
RUN_ID=""
SEND_MODE=""
WINDOW_MS=""
WARMUP_SECONDS=""
INPUT_LATENCY=""
MOVE_TO_RATE=""
EVENT_SEED=""
ROOM_SLOTS=""
START_AT=""
STALE_AFTER=""
SLOW_READ=""
SAMPLES_DIR=""
RECONNECT=""
RECONSTRUCT=""
SYSTEM_METRICS_OUT=""
CONTROL_SOCKET=""
RECONNECT_UNTIL=""
EXTERNAL_SERVER_PID=""
EXTERNAL_PROFILE=""

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
    --layout)
      LAYOUT="$2"
      shift 2
      ;;
    --connect)
      CONNECT_MODE="$2"
      shift 2
      ;;
    --connect-rate)
      CONNECT_RATE="$2"
      shift 2
      ;;
    --boundary)
      BOUNDARY="$2"
      shift 2
      ;;
    --allow-partial-ramp)
      ALLOW_PARTIAL_RAMP=true
      shift
      ;;
    --allow-join-failures)
      ALLOW_JOIN_FAILURES=true
      shift
      ;;
    --run-id)
      RUN_ID="$2"
      shift 2
      ;;
    --send)
      SEND_MODE="$2"
      shift 2
      ;;
    --window-ms)
      WINDOW_MS="$2"
      shift 2
      ;;
    --warmup-seconds)
      WARMUP_SECONDS="$2"
      shift 2
      ;;
    # Client options passed to the CLI as given (see `node dist/cli.js --help`).
    --input-latency)
      INPUT_LATENCY="$2"
      shift 2
      ;;
    --move-to-rate)
      MOVE_TO_RATE="$2"
      shift 2
      ;;
    --event-seed)
      EVENT_SEED="$2"
      shift 2
      ;;
    --room-slots)
      ROOM_SLOTS="$2"
      shift 2
      ;;
    --start-at)
      START_AT="$2"
      [[ "$START_AT" =~ ^[0-9]+$ ]] || { echo "--start-at must be epoch milliseconds (got '$START_AT')"; exit 1; }
      shift 2
      ;;
    --stale-after)
      STALE_AFTER="$2"
      shift 2
      ;;
    --slow-read)
      SLOW_READ="$2"
      shift 2
      ;;
    --samples-dir)
      SAMPLES_DIR="$2"
      shift 2
      ;;
    --system-metrics-out)
      SYSTEM_METRICS_OUT="$2"
      shift 2
      ;;
    --reconstruct)
      RECONSTRUCT=1
      shift
      ;;
    --control-socket)
      CONTROL_SOCKET="$2"
      shift 2
      ;;
    --reconnect)
      RECONNECT="$2"
      shift 2
      ;;
    --reconnect-until)
      RECONNECT_UNTIL="$2"
      shift 2
      ;;
    --external-server)
      EXTERNAL_SERVER_PID="$2"
      shift 2
      ;;
    --external-profile)
      EXTERNAL_PROFILE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--scenario <path>] [--workers <N>] [--output-dir <dir>] [--startup-timeout <seconds>] [--profile]"
      echo "          [--layout rooms|per-connection] [--connect ramp|burst] [--connect-rate <per second>]"
      echo "          [--boundary clean|abrupt] [--allow-partial-ramp] [--allow-join-failures] [--run-id <id>]"
      echo "          [--send spread|lockstep] [--window-ms <ms>] [--warmup-seconds <s>]"
      echo "          [--room-slots <spec>] [--start-at <epoch ms>]   (two instances sharing rooms; see README)"
      echo "          [--stale-after <s>] [--slow-read <start>:<duration>] [--samples-dir <dir>]"
      echo "          [--reconnect on-server-close] [--reconnect-until <s>] [--reconstruct] [--control-socket <path>]"
      echo "          [--system-metrics-out <file>]   (default monitoring/system-metrics.json)"
      echo "          [--external-server <pid> [--external-profile <transport-profile.jsonl>]]"
      echo "  --external-server: use a GameServer the caller started (its PID): no build, no start or"
      echo "    stop, no port 8080 check; the scenario's serverUrl must accept connections, and the"
      echo "    system metrics sample that PID. --external-profile: the profile JSONL that server writes."
      echo "  --layout per-connection --connect burst: same topology and connect burst as the old tool;"
      echo "    phase boundaries still close cleanly, unlike the old tool's resets. Add --boundary abrupt"
      echo "    to drop sockets at boundaries without a close frame, as the old tool did"
      echo "    (the server sees FIN or RST, depending on unread data), and --send lockstep"
      echo "    --warmup-seconds 0 for the old send timer and RTT origin with no warm-up exclusion."
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
# The reports directory, resolved once: --output-dir is relative to ws-loadtest/ unless absolute.
case "$OUTPUT_DIR" in
  /*) OUTPUT_PATH="$OUTPUT_DIR" ;;
  *) OUTPUT_PATH="$ROOT_DIR/$OUTPUT_DIR" ;;
esac

SCENARIO_PATH="$ROOT_DIR/$SCENARIO"
# Two instances sampling one server (populations M and SR) need their own files: --system-metrics-out.
case "${SYSTEM_METRICS_OUT:-}" in
  "") SYSTEM_METRICS_PATH="$ROOT_DIR/monitoring/system-metrics.json" ;;
  /*) SYSTEM_METRICS_PATH="$SYSTEM_METRICS_OUT" ;;
  *) SYSTEM_METRICS_PATH="$ROOT_DIR/$SYSTEM_METRICS_OUT" ;;
esac

if [ ! -f "$SCENARIO_PATH" ]; then
  echo "Scenario not found: $SCENARIO_PATH"
  exit 1
fi

# sdk/ts (a file: dependency) and this package's dependencies, then the client build, before
# the server starts, so neither install nor build runs while the server is being sampled.
bash "$SCRIPT_DIR/ensure-deps.sh"
(cd "$ROOT_DIR" && npm run build)

TOTAL_DURATION=$(node -e "const fs=require('fs'); const s=JSON.parse(fs.readFileSync('$SCENARIO_PATH','utf-8')); const p=s.phases||{}; const sum=(p.preflight?.durationSeconds||0)+(p.steady?.durationSeconds||0)+(p.postflight?.durationSeconds||0); console.log(sum||60);")
PHASE_COUNT=$(node -e "const fs=require('fs'); const s=JSON.parse(fs.readFileSync('$SCENARIO_PATH','utf-8')); const p=s.phases||{}; console.log(['preflight','steady','postflight'].filter((k)=>p[k]).length||1);")
# shellcheck source=load-test-timeout.sh
. "$SCRIPT_DIR/load-test-timeout.sh"
TIMEOUT="$(load_test_timeout "$TOTAL_DURATION" "$PHASE_COUNT")"

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

if [ -n "$EXTERNAL_SERVER_PID" ]; then
  # The caller started the server (e.g. in another network namespace) and owns its lifecycle.
  if [ "$ENABLE_PROFILING" = true ]; then
    echo "--profile starts the server with profiling; with --external-server use --external-profile <file>."
    exit 1
  fi
  if ! [[ "$EXTERNAL_SERVER_PID" =~ ^[0-9]+$ ]] || ! kill -0 "$EXTERNAL_SERVER_PID" 2>/dev/null; then
    echo "--external-server: no running process with PID '$EXTERNAL_SERVER_PID'."
    exit 1
  fi
  SERVER_PID="$EXTERNAL_SERVER_PID"
  SERVER_URL=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$SCENARIO_PATH','utf-8')).serverUrl)")
  echo "External server: PID $SERVER_PID; checking $SERVER_URL accepts connections..."
  if ! node -e "
    const u = new URL(process.argv[1]);
    const port = Number(u.port || (u.protocol === 'wss:' ? 443 : 80));
    const s = require('net').connect({ host: u.hostname, port, timeout: 3000 });
    s.on('connect', () => { s.end(); process.exit(0); });
    s.on('timeout', () => process.exit(1));
    s.on('error', () => process.exit(1));
  " "$SERVER_URL"; then
    echo "External server: $SERVER_URL does not accept connections."
    exit 1
  fi
  mkdir -p "$OUTPUT_PATH" 2>/dev/null || true
  {
    echo "external server PID $SERVER_PID"
    if [ -r "/proc/$SERVER_PID/exe" ]; then
      echo "external server binary $(readlink "/proc/$SERVER_PID/exe" 2>/dev/null || echo '<unreadable>')"
    fi
    echo "GAMESERVER_SOURCE_SHA=${GAMESERVER_SOURCE_SHA:-<unset>}"
    swift --version 2>&1 || echo "swift: not on this client's PATH"
    echo "node $(node --version 2>&1)"
  } > "$OUTPUT_PATH/toolchain.txt" || true
  if [ -n "$EXTERNAL_PROFILE" ]; then
    case "$EXTERNAL_PROFILE" in
      /*) TRANSPORT_PROFILE_JSONL_PATH="$EXTERNAL_PROFILE" ;;
      *) TRANSPORT_PROFILE_JSONL_PATH="$ROOT_DIR/$EXTERNAL_PROFILE" ;;
    esac
    ENABLE_PROFILING=true
  fi
else
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

# Pass through USE_NIO if set (for NIO WebSocket transport testing)
if [ -n "${USE_NIO:-}" ]; then
  export USE_NIO
  echo "USE_NIO=$USE_NIO (using pure NIO WebSocket transport)"
fi

# Isolate reevaluation outputs during load tests so we can verify "no writes" deterministically
# and avoid polluting the repo working tree.
export REEVALUATION_RECORDS_DIR="/tmp/ws-loadtest-reevaluation-records"
rm -rf "$REEVALUATION_RECORDS_DIR" >/dev/null 2>&1 || true
mkdir -p "$REEVALUATION_RECORDS_DIR" >/dev/null 2>&1 || true

# Transport profiling: when --profile is used, server writes JSONL (per-run when output-dir is used)
if [ "$ENABLE_PROFILING" = true ]; then
  export TRANSPORT_PROFILE_JSONL_PATH="$OUTPUT_PATH/transport-profile.jsonl"
  mkdir -p "$(dirname "$TRANSPORT_PROFILE_JSONL_PATH")" 2>/dev/null || true
  rm -f "$TRANSPORT_PROFILE_JSONL_PATH" 2>/dev/null || true
  echo "Transport profiling enabled: $TRANSPORT_PROFILE_JSONL_PATH"
fi

echo "Starting GameServer (release, LOG_LEVEL=error, ENABLE_REEVALUATION=false; log file: /tmp/ws-loadtest-gameserver.log)..."
# Rooms larger than 10 players need HERO_DEFENSE_MAX_PLAYERS; an exported value reaches the server.
echo "HERO_DEFENSE_MAX_PLAYERS=${HERO_DEFENSE_MAX_PLAYERS:-<unset, server default 10>}"
cd "$GAMEDEMO_DIR"
# NOTE: Use the built product directly instead of `swift run` so the environment
# variables above are guaranteed to reach the GameServer process.
# GAMESERVER_BIN: run that prebuilt GameServer instead of building this checkout's, e.g. a
# server built from another commit against this client. GAMESERVER_SOURCE_SHA names its commit
# in toolchain.txt. Unset, the script builds and runs this checkout's GameServer.
if [ -n "${GAMESERVER_BIN:-}" ]; then
  echo "Using GAMESERVER_BIN=$GAMESERVER_BIN (source: ${GAMESERVER_SOURCE_SHA:-<unset>}); not building this checkout's GameServer."
  : > /tmp/ws-loadtest-gameserver.build.log
  BIN_DIR="$(dirname "$GAMESERVER_BIN")"
  SERVER_BIN="$GAMESERVER_BIN"
else
  swift build -c release --product GameServer >/tmp/ws-loadtest-gameserver.build.log 2>&1 || true
  BIN_DIR=$(swift build -c release --show-bin-path 2>/dev/null || true)
  SERVER_BIN="$BIN_DIR/GameServer"
fi
# Record the toolchains next to the reports (the server's Swift and the load client's Node):
# runs are comparable only on the same toolchains.
mkdir -p "$OUTPUT_PATH" 2>/dev/null || true
{
  swift --version 2>&1
  echo "node $(node --version 2>&1)"
  if [ -n "${GAMESERVER_BIN:-}" ]; then
    echo "GAMESERVER_BIN=$GAMESERVER_BIN"
    echo "GAMESERVER_SOURCE_SHA=${GAMESERVER_SOURCE_SHA:-<unset>}"
  fi
} > "$OUTPUT_PATH/toolchain.txt" || true
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

fi

echo "Starting system monitoring..."
cd "$ROOT_DIR"
rm -f "$SYSTEM_METRICS_PATH"
bash "$ROOT_DIR/monitoring/collect-system-metrics.sh" "$SERVER_PID" "$SYSTEM_METRICS_PATH" 1 &
MONITOR_PID=$!

cd "$ROOT_DIR"

CMD=(node dist/cli.js --scenario "$SCENARIO" --system-metrics "$SYSTEM_METRICS_PATH" --output-dir "$OUTPUT_PATH")
if [ -n "$WORKERS" ]; then
  CMD+=(--workers "$WORKERS")
fi
if [ "$ENABLE_PROFILING" = true ]; then
  CMD+=(--transport-profile "$TRANSPORT_PROFILE_JSONL_PATH")
fi
if [ -n "$LAYOUT" ]; then
  CMD+=(--layout "$LAYOUT")
fi
if [ -n "$CONNECT_MODE" ]; then
  CMD+=(--connect "$CONNECT_MODE")
fi
if [ -n "$CONNECT_RATE" ]; then
  CMD+=(--connect-rate "$CONNECT_RATE")
fi
if [ -n "$BOUNDARY" ]; then
  CMD+=(--boundary "$BOUNDARY")
fi
if [ "$ALLOW_PARTIAL_RAMP" = true ]; then
  CMD+=(--allow-partial-ramp)
fi
if [ "$ALLOW_JOIN_FAILURES" = true ]; then
  CMD+=(--allow-join-failures)
fi
if [ -n "$RUN_ID" ]; then
  CMD+=(--run-id "$RUN_ID")
fi
if [ -n "$SEND_MODE" ]; then
  CMD+=(--send "$SEND_MODE")
fi
if [ -n "$WINDOW_MS" ]; then
  CMD+=(--window-ms "$WINDOW_MS")
fi
if [ -n "$WARMUP_SECONDS" ]; then
  CMD+=(--warmup-seconds "$WARMUP_SECONDS")
fi
if [ -n "$INPUT_LATENCY" ]; then
  CMD+=(--input-latency "$INPUT_LATENCY")
fi
if [ -n "$MOVE_TO_RATE" ]; then
  CMD+=(--move-to-rate "$MOVE_TO_RATE")
fi
if [ -n "$EVENT_SEED" ]; then
  CMD+=(--event-seed "$EVENT_SEED")
fi
if [ -n "$ROOM_SLOTS" ]; then
  CMD+=(--room-slots "$ROOM_SLOTS")
fi
if [ -n "$START_AT" ]; then
  CMD+=(--start-at "$START_AT")
fi
if [ -n "$STALE_AFTER" ]; then
  CMD+=(--stale-after "$STALE_AFTER")
fi
if [ -n "$SLOW_READ" ]; then
  CMD+=(--slow-read "$SLOW_READ")
fi
if [ -n "$RECONNECT" ]; then
  CMD+=(--reconnect "$RECONNECT")
fi
if [ -n "$RECONSTRUCT" ]; then
  CMD+=(--reconstruct)
fi
if [ -n "$CONTROL_SOCKET" ]; then
  CMD+=(--control-socket "$CONTROL_SOCKET")
fi
if [ -n "$RECONNECT_UNTIL" ]; then
  CMD+=(--reconnect-until "$RECONNECT_UNTIL")
fi
if [ -n "$SAMPLES_DIR" ]; then
  # Relative to ws-loadtest/, like --output-dir.
  case "$SAMPLES_DIR" in
    /*) CMD+=(--samples-dir "$SAMPLES_DIR") ;;
    *) CMD+=(--samples-dir "$ROOT_DIR/$SAMPLES_DIR") ;;
  esac
fi

# The wait for --start-at counts toward the timeout too, measured as the client starts.
TIMEOUT="$(load_test_timeout "$TOTAL_DURATION" "$PHASE_COUNT" "$START_AT" "$(node -e 'console.log(Date.now())')")"
echo "Running load test (timeout ${TIMEOUT}s)..."
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

if [ -n "$EXTERNAL_SERVER_PID" ]; then
  echo "External server: left running (PID $SERVER_PID)."
else
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

fi

echo "Done. Reports in $OUTPUT_PATH"
