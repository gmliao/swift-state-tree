#!/usr/bin/env bash
# Run ws-loadtest (GameServer + WebSocket clients) with Swift Profile Recorder.
# Starts GameServer with PROFILE_RECORDER_SERVER_URL_PATTERN, runs load test,
# collects samples during steady state, and saves .perf for Speedscope/Firefox Profiler.
#
# Usage:
#   bash run-ws-loadtest-with-profiler.sh [--scenario <path>] [--samples N] [--ramp-wait N]
#
# Example (300 rooms):
#   bash run-ws-loadtest-with-profiler.sh --scenario scenarios/hero-defense/profile-300rooms.json
#
# Output:
#   results/ws-loadtest-profiling/profile-300rooms-<timestamp>.perf

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GAMEDEMO_DIR="$(cd "$ROOT_DIR/.." && pwd)"

SCENARIO="scenarios/hero-defense/profile-300rooms.json"
SAMPLES=800
SAMPLE_INTERVAL="10ms"
RAMP_WAIT=25
OUTPUT_DIR="$ROOT_DIR/results/ws-loadtest-profiling"

while [[ $# -gt 0 ]]; do
  case $1 in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --ramp-wait) RAMP_WAIT="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--scenario <path>] [--samples N] [--ramp-wait N] [--output-dir DIR]"
      echo "  --scenario   default: scenarios/hero-defense/profile-300rooms.json"
      echo "  --samples    default: 800"
      echo "  --ramp-wait  seconds before collect (default: 25, should be > preflight)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
ROOMS=$(node -e "const s=require('$ROOT_DIR/$SCENARIO'); console.log(s.phases?.steady?.rooms || s.phases?.preflight?.rooms || 300);")
PERF_FILE="$OUTPUT_DIR/profile-${ROOMS}rooms-${TIMESTAMP}.perf"
SOCKET_PATTERN="unix:///tmp/ws-loadtest-gameserver-samples-{PID}.sock"

export PROFILE_RECORDER_SERVER_URL_PATTERN="$SOCKET_PATTERN"
echo "Swift Profile Recorder: $SOCKET_PATTERN"
echo "Scenario: $SCENARIO ($ROOMS rooms)"
echo "Ramp wait: ${RAMP_WAIT}s, samples: $SAMPLES"
echo "Output: $PERF_FILE"
echo ""

# Run ws-loadtest in background (it starts GameServer, runs load test, then stops)
bash "$SCRIPT_DIR/run-ws-loadtest.sh" \
  --scenario "$SCENARIO" \
  --output-dir "results/ws-loadtest-${ROOMS}rooms-${TIMESTAMP}" \
  --startup-timeout 90 \
  > "$OUTPUT_DIR/run-ws-loadtest-${TIMESTAMP}.log" 2>&1 &
LOADTEST_PID=$!

# Wait for GameServer's Profile Recorder socket to appear (build can take 60–90s on cold start)
# Use the socket whose PID matches a live GameServer on port 8080 (avoid stale sockets from previous runs)
SOCK=""
SERVER_PID=""
for i in $(seq 1 120); do
  sleep 1
  GAME_PID=$(lsof -t -iTCP:8080 2>/dev/null | head -1)
  if [[ -n "$GAME_PID" ]]; then
    CANDIDATE="/tmp/ws-loadtest-gameserver-samples-${GAME_PID}.sock"
    if [[ -S "$CANDIDATE" ]]; then
      SOCK="$CANDIDATE"
      SERVER_PID="$GAME_PID"
      break
    fi
  fi
done

if [[ -z "$SOCK" ]] || [[ -z "$SERVER_PID" ]]; then
  echo "Timeout waiting for profile recorder socket. Check: $OUTPUT_DIR/run-ws-loadtest-${TIMESTAMP}.log"
  kill "$LOADTEST_PID" 2>/dev/null || true
  exit 1
fi

echo "Profile recorder socket ready (pid $SERVER_PID). Waiting ${RAMP_WAIT}s for steady state..."
sleep "$RAMP_WAIT"

# Collect samples (load test still running)
echo "Collecting $SAMPLES samples..."
if curl -sd "{\"numberOfSamples\":$SAMPLES,\"timeInterval\":\"$SAMPLE_INTERVAL\"}" \
    --unix-socket "$SOCK" \
    --max-time $(( (SAMPLES * 2) / 100 + 120 )) \
    http://localhost/sample 2>/dev/null | swift demangle --compact > "$PERF_FILE" 2>/dev/null; then
  echo "Saved: $PERF_FILE"
else
  echo "Sample collection failed (curl or demangle)."
fi

# Wait for load test to finish
echo "Waiting for ws-loadtest to finish..."
wait "$LOADTEST_PID" 2>/dev/null || true

echo ""
echo "Done. Perf: $PERF_FILE"
echo "View: drag $PERF_FILE into https://speedscope.app or https://profiler.firefox.com"
