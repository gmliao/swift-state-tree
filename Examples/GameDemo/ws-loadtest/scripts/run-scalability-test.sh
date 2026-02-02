#!/usr/bin/env bash
# Scalability test runner - Runs the ws-loadtest multiple times and aggregates results.
# Similar to Examples/GameDemo/scripts/server-loadtest/run-scalability-test.sh
# Usage: bash run-scalability-test.sh [options]

set +e

# Defaults
SCENARIO="scenarios/hero-defense/default.json"
RUNS=3
ROOM_COUNTS=""
# Default to scaling by rooms (100 → 300 → 500 → 700 unless overridden)
SCALE_BY_ROOMS=true
START_ROOMS=100
MAX_ROOMS=700
ROOM_INCREMENT=200
WORKERS=""
OUTPUT_BASE_DIR="results"
STARTUP_TIMEOUT=60
DELAY_BETWEEN_RUNS=5

while [[ $# -gt 0 ]]; do
  case $1 in
    --scenario)
      SCENARIO="$2"
      shift 2
      ;;
    --runs)
      RUNS="$2"
      shift 2
      ;;
    --room-counts)
      ROOM_COUNTS="$2"
      shift 2
      ;;
    --scale-by-rooms)
      SCALE_BY_ROOMS=true
      shift
      ;;
    --no-scale-by-rooms)
      SCALE_BY_ROOMS=false
      shift
      ;;
    --start-rooms)
      START_ROOMS="$2"
      shift 2
      ;;
    --max-rooms)
      MAX_ROOMS="$2"
      shift 2
      ;;
    --room-increment)
      ROOM_INCREMENT="$2"
      shift 2
      ;;
    --workers)
      WORKERS="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_BASE_DIR="$2"
      shift 2
      ;;
    --startup-timeout)
      STARTUP_TIMEOUT="$2"
      shift 2
      ;;
    --delay)
      DELAY_BETWEEN_RUNS="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo ""
      echo "Runs ws-loadtest multiple times and aggregates pass/fail and metrics."
      echo "Two modes:"
      echo "  1) By room count: use --start-rooms / --max-rooms / --room-increment, or --room-counts \"N1 N2 N3\""
      echo "  2) Same scenario N times: use --no-scale-by-rooms --runs N"
      echo ""
      echo "Options:"
      echo "  --scenario <path>         Base scenario JSON (default: $SCENARIO)"
      echo "  --runs <N>                Number of runs when not scaling by rooms (default: $RUNS)"
      echo "  --room-counts \"N1 N2 N3\"   Explicit room list (e.g. \"1 5 10 20\"); overrides start/max/increment"
      echo "  --scale-by-rooms          Scale by room count using --start-rooms / --max-rooms / --room-increment (default)"
      echo "  --no-scale-by-rooms       Disable scale-by-rooms; run same scenario N times"
      echo "  --start-rooms <N>         First room count when using --scale-by-rooms (default: $START_ROOMS)"
      echo "  --max-rooms <N>           Last room count when using --scale-by-rooms (default: $MAX_ROOMS)"
      echo "  --room-increment <N>      Step between room counts when using --scale-by-rooms (default: $ROOM_INCREMENT)"
      echo "  --workers <N>             Worker process count for ws-loadtest (default: CPU cores)"
      echo "  --output-dir <dir>        Base output dir; creates scalability-<timestamp>/run-1, ... (default: $OUTPUT_BASE_DIR)"
      echo "  --startup-timeout <s>     Server startup timeout per run (default: $STARTUP_TIMEOUT)"
      echo "  --delay <s>               Seconds between runs (default: $DELAY_BETWEEN_RUNS)"
      echo ""
      echo "Examples:"
      echo "  # Same scenario 5 times"
      echo "  $0 --no-scale-by-rooms --runs 5"
      echo ""
      echo "  # Scale by rooms: 100, 300, 500, 700 (default start=100 max=700 increment=200)"
      echo "  $0 --scale-by-rooms"
      echo ""
      echo "  # Custom room list: 1, 10, 50, 100"
      echo "  $0 --room-counts \"1 10 50 100\""
      echo ""
      echo "  # Use 16 workers"
      echo "  $0 --workers 16"
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
cd "$ROOT_DIR"

SCENARIO_PATH="$ROOT_DIR/$SCENARIO"
if [ ! -f "$SCENARIO_PATH" ]; then
  echo "Scenario not found: $SCENARIO_PATH"
  exit 1
fi

TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%S")
SUITE_DIR="$OUTPUT_BASE_DIR/scalability-$TIMESTAMP"
mkdir -p "$SUITE_DIR"

SUMMARY_JSON="$ROOT_DIR/$SUITE_DIR/summary.json"

# Build run list: explicit room-counts, or --scale-by-rooms (start/max/increment), or just N runs
if [ -n "$ROOM_COUNTS" ]; then
  RUN_LIST=($ROOM_COUNTS)
  TOTAL_RUNS=${#RUN_LIST[@]}
  MODE="room-counts"
elif [ "$SCALE_BY_ROOMS" = true ]; then
  RUN_LIST=()
  n=$START_ROOMS
  while [ "$n" -le "$MAX_ROOMS" ]; do
    RUN_LIST+=("$n")
    n=$((n + ROOM_INCREMENT))
  done
  TOTAL_RUNS=${#RUN_LIST[@]}
  MODE="room-counts"
  if [ "$TOTAL_RUNS" -eq 0 ]; then
    echo "No room counts in range (start=$START_ROOMS max=$MAX_ROOMS increment=$ROOM_INCREMENT). Adjust --start-rooms/--max-rooms/--room-increment."
    exit 1
  fi
else
  TOTAL_RUNS=$RUNS
  MODE="runs"
fi

# Initialize summary (include roomCounts in config when used)
ROOM_COUNTS_JSON="null"
if [ -n "$ROOM_COUNTS" ]; then
  ROOM_COUNTS_JSON="[$(echo $ROOM_COUNTS | tr ' ' ',')]"
elif [ "$MODE" = "room-counts" ] && [ ${#RUN_LIST[@]} -gt 0 ]; then
  ROOM_COUNTS_JSON="[$(IFS=,; echo "${RUN_LIST[*]}")]"
fi
echo "{
  \"timestamp\": \"$TIMESTAMP\",
  \"config\": {
    \"scenario\": \"$SCENARIO\",
    \"runs\": $TOTAL_RUNS,
    \"roomCounts\": $ROOM_COUNTS_JSON,
    \"startupTimeout\": $STARTUP_TIMEOUT,
    \"delayBetweenRuns\": $DELAY_BETWEEN_RUNS
  },
  \"runs\": [],
  \"summary\": {}
}" > "$SUMMARY_JSON"

echo "=========================================="
echo "WS Load Test – Scalability"
echo "=========================================="
echo "Scenario: $SCENARIO"
if [ "$MODE" = "room-counts" ]; then
  echo "Room counts: ${RUN_LIST[*]} (${TOTAL_RUNS} runs)"
else
  echo "Runs: $TOTAL_RUNS (same scenario)"
fi
echo "Output: $SUITE_DIR"
echo "=========================================="
echo ""

PASSED=0
FAILED=0

for ((i=0; i<TOTAL_RUNS; i++)); do
  RUN_INDEX=$((i + 1))
  if [ "$MODE" = "room-counts" ]; then
    ROOMS_NOW=${RUN_LIST[$i]}
    echo ""
    echo "=========================================="
    echo "Run $RUN_INDEX / $TOTAL_RUNS (rooms: $ROOMS_NOW)"
    echo "=========================================="
    TEMP_SCENARIO="$SUITE_DIR/scenario-${ROOMS_NOW}rooms.json"
    node "$SCRIPT_DIR/scenario-with-rooms.js" "$SCENARIO_PATH" "$ROOT_DIR/$TEMP_SCENARIO" "$ROOMS_NOW" 2>/dev/null || true
    SCENARIO_TO_USE="$TEMP_SCENARIO"
  else
    echo ""
    echo "=========================================="
    echo "Run $RUN_INDEX / $TOTAL_RUNS"
    echo "=========================================="
    ROOMS_NOW=""
    SCENARIO_TO_USE="$SCENARIO"
  fi

  RUN_OUTPUT_DIR="$SUITE_DIR/run-$RUN_INDEX"
  mkdir -p "$RUN_OUTPUT_DIR"

  START_TIME=$(date +%s)
  WORKERS_ARGS=()
  if [ -n "$WORKERS" ]; then
    WORKERS_ARGS+=(--workers "$WORKERS")
  fi
  bash "$SCRIPT_DIR/run-ws-loadtest.sh" \
    --scenario "$SCENARIO_TO_USE" \
    --output-dir "$RUN_OUTPUT_DIR" \
    --startup-timeout "$STARTUP_TIMEOUT" \
    "${WORKERS_ARGS[@]}" \
    2>&1 | tee "$SUITE_DIR/run-${RUN_INDEX}.log"
  EXIT_CODE=${PIPESTATUS[0]}
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))

  # Clean up temp scenario
  if [ "$MODE" = "room-counts" ] && [ -f "$ROOT_DIR/$TEMP_SCENARIO" ]; then
    rm -f "$ROOT_DIR/$TEMP_SCENARIO"
  fi

  # Find report JSON for this run
  REPORT_JSON=""
  if [ -d "$RUN_OUTPUT_DIR" ]; then
    REPORT_JSON=$(find "$RUN_OUTPUT_DIR" -maxdepth 1 -name "ws-loadtest-*.json" -type f 2>/dev/null | head -n 1)
  fi
  if [ -n "$REPORT_JSON" ] && [ "${REPORT_JSON#/}" = "$REPORT_JSON" ]; then
    REPORT_JSON="$ROOT_DIR/$REPORT_JSON"
  fi

  SUCCESS="false"
  if [ $EXIT_CODE -eq 0 ] && [ -n "$REPORT_JSON" ] && [ -f "$REPORT_JSON" ]; then
    ALL_PHASES_PASSED=$(node -e "
    const fs = require('fs');
    const data = JSON.parse(fs.readFileSync('$REPORT_JSON', 'utf8'));
    const phases = data.phases || [];
    const allPassed = phases.length > 0 && phases.every(p => p.passed !== false);
    console.log(allPassed ? 'true' : 'false');
    " 2>/dev/null || echo "false")
    if [ "$ALL_PHASES_PASSED" = "true" ]; then
      SUCCESS="true"
      PASSED=$((PASSED + 1))
      echo ""
      echo "Run $RUN_INDEX: PASSED (${DURATION}s)"
    else
      FAILED=$((FAILED + 1))
      echo ""
      echo "Run $RUN_INDEX: FAILED (phases did not all pass)"
    fi
  else
    FAILED=$((FAILED + 1))
    echo ""
    echo "Run $RUN_INDEX: FAILED (exit code: $EXIT_CODE)"
  fi

  # Append run entry to summary (pass rooms when scaling by room count)
  ROOMS_ARG=""
  if [ -n "$ROOMS_NOW" ]; then
    ROOMS_ARG="$ROOMS_NOW"
  fi
  node "$SCRIPT_DIR/append-run-to-summary.js" \
    "$SUMMARY_JSON" \
    "$REPORT_JSON" \
    "$ROOT_DIR" \
    "$RUN_INDEX" \
    "$EXIT_CODE" \
    "$SUCCESS" \
    "$DURATION" \
    $ROOMS_ARG \
    2>/dev/null || true

  if [ "$RUN_INDEX" -lt "$TOTAL_RUNS" ]; then
    echo ""
    echo "Waiting ${DELAY_BETWEEN_RUNS}s before next run..."
    sleep "$DELAY_BETWEEN_RUNS"
  fi
done

# Update summary section
node -e "
const fs = require('fs');
const summaryPath = '$SUMMARY_JSON';
const data = JSON.parse(fs.readFileSync(summaryPath, 'utf8'));
const runs = data.runs || [];
const passed = runs.filter(r => r.success).length;
const failed = runs.length - passed;
data.summary = {
  totalRuns: runs.length,
  passed,
  failed,
  passRate: runs.length > 0 ? (passed / runs.length) : 0
};
fs.writeFileSync(summaryPath, JSON.stringify(data, null, 2));
" 2>/dev/null

# Print summary
echo ""
echo "=========================================="
echo "Scalability test summary"
echo "=========================================="
echo ""
echo "Total runs: $TOTAL_RUNS"
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Pass rate: $(node -e "console.log(($TOTAL_RUNS > 0 ? ($PASSED / $TOTAL_RUNS * 100) : 0).toFixed(1));")%"
echo ""
if [ -f "$SUMMARY_JSON" ]; then
  echo "Per-run data:"
  node "$SCRIPT_DIR/print-summary-table.js" "$SUMMARY_JSON" 2>/dev/null || true
  echo ""
  echo "Summary JSON: $SUMMARY_JSON"
  SUMMARY_HTML="$ROOT_DIR/$SUITE_DIR/summary.html"
  node "$SCRIPT_DIR/render-summary-html.js" "$SUMMARY_JSON" "$ROOT_DIR" "$SUMMARY_HTML" 2>/dev/null && echo "Summary HTML: $SUMMARY_HTML" || true
fi
echo ""
