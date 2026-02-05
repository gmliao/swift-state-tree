#!/bin/bash
# Run ServerLoadTest with Swift Profile Recorder, collect samples during steady state,
# and save .perf + optional CLI summary for analysis.
#
# Usage:
#   bash run-collect-profile.sh [options]
#   bash run-collect-profile.sh --rooms 500 --samples 1000
#   bash run-collect-profile.sh --collect-only --pid 12345   # collect from already-running process
#
# Options:
#   --rooms N                  (default: 500)
#   --samples N                number of samples to collect (default: 800)
#   --sample-interval "10ms"   interval between samples (default: "10ms")
#   --ramp-wait N              seconds to wait after start before first collect (default: 35, > ramp-up)
#   --output-dir DIR           where to write .perf and .summary.txt (default: results/server-loadtest/profiling)
#   --collect-only             only collect from running process (requires --pid)
#   --pid PID                  process ID (for --collect-only, or auto when running test)
#   --analyze                  after collect, run CLI summary (default: true when not --collect-only)
#
# Output:
#   <output-dir>/profile-<rooms>rooms-<timestamp>.perf
#   <output-dir>/profile-<rooms>rooms-<timestamp>.summary.txt  (if --analyze)

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
GAMEDEMO_ROOT="$(pwd)"

# Defaults
ROOMS=500
SAMPLES=800
SAMPLE_INTERVAL="10ms"
RAMP_WAIT=35
OUTPUT_DIR="$GAMEDEMO_ROOT/results/server-loadtest/profiling"
COLLECT_ONLY=false
PID=""
DO_ANALYZE=true
DURATION_SECONDS=60
RAMP_UP_SECONDS=30
RAMP_DOWN_SECONDS=10

while [[ $# -gt 0 ]]; do
    case $1 in
        --rooms) ROOMS="$2"; shift 2 ;;
        --samples) SAMPLES="$2"; shift 2 ;;
        --sample-interval) SAMPLE_INTERVAL="$2"; shift 2 ;;
        --ramp-wait) RAMP_WAIT="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --collect-only) COLLECT_ONLY=true; shift ;;
        --pid) PID="$2"; shift 2 ;;
        --analyze) DO_ANALYZE=true; shift ;;
        --no-analyze) DO_ANALYZE=false; shift ;;
        --duration-seconds) DURATION_SECONDS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "  --rooms N              default: $ROOMS"
            echo "  --samples N            default: $SAMPLES"
            echo "  --sample-interval STR  default: $SAMPLE_INTERVAL"
            echo "  --ramp-wait N          seconds before first collect (default: $RAMP_WAIT)"
            echo "  --output-dir DIR       default: $OUTPUT_DIR"
            echo "  --collect-only --pid PID   collect from existing process only"
            echo "  --analyze / --no-analyze   print top-N summary (default: --analyze)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
PERF_FILE="$OUTPUT_DIR/profile-${ROOMS}rooms-${TIMESTAMP}.perf"
SUMMARY_FILE="$OUTPUT_DIR/profile-${ROOMS}rooms-${TIMESTAMP}.summary.txt"
SOCKET_PATTERN="unix:///tmp/serverloadtest-samples-{PID}.sock"

# --- Collect samples via curl and write .perf ---
collect_samples() {
    local pid=$1
    local sock="/tmp/serverloadtest-samples-${pid}.sock"
    if [[ ! -S "$sock" ]]; then
        echo "Socket not found: $sock (is Profile Recorder enabled and process $pid running?)"
        return 1
    fi
    echo "Collecting $SAMPLES samples (interval $SAMPLE_INTERVAL) from $sock ..."
    if curl -sd "{\"numberOfSamples\":$SAMPLES,\"timeInterval\":\"$SAMPLE_INTERVAL\"}" \
        --unix-socket "$sock" \
        --max-time $(( (SAMPLES * 2) / 100 + 60 )) \
        http://localhost/sample 2>/dev/null | swift demangle --compact > "$PERF_FILE" 2>/dev/null; then
        echo "Saved: $PERF_FILE"
        return 0
    else
        echo "Failed to collect samples (curl or demangle failed)."
        return 1
    fi
}

# --- CLI summary: top symbols by sample count (heuristic for perf script format) ---
analyze_perf() {
    local perf=$1
    local summary=$2
    if [[ ! -f "$perf" ]] || [[ ! -s "$perf" ]]; then
        echo "No .perf file or empty; skip analyze."
        return
    fi
    echo "Analyzing $perf ..."
    local total
    total=$(wc -l < "$perf" | tr -d ' ')
    {
        echo "=== Profile summary ==="
        echo "File: $perf"
        echo "Total lines (stack frames): $total"
        echo ""
        echo "=== Top 40 symbols (by occurrence in stack frames) ==="
        # Perf script often has symbol as last field; strip leading spaces and take last column
        awk '{ for(i=1;i<=NF;i++) if ($i != "" && $i !~ /^[0-9]+$/ && $i !~ /^[0-9a-f]+$/) last=$i } last != "" { print last; last="" }' "$perf" \
            | sort | uniq -c | sort -rn | head -40
        echo ""
        echo "=== Quick view: open in Speedscope or Firefox Profiler ==="
        echo "  Drag this file: $perf"
        echo "  Or: open https://speedscope.app"
    } | tee "$summary"
    echo "Summary: $summary"
}

# ---------- Collect-only mode ----------
if [[ "$COLLECT_ONLY" == true ]]; then
    if [[ -z "$PID" ]]; then
        echo "Error: --collect-only requires --pid <PID>"
        exit 1
    fi
    PERF_FILE="$OUTPUT_DIR/profile-pid${PID}-${TIMESTAMP}.perf"
    SUMMARY_FILE="$OUTPUT_DIR/profile-pid${PID}-${TIMESTAMP}.summary.txt"
    collect_samples "$PID" || exit 1
    if [[ "$DO_ANALYZE" == true ]]; then
        analyze_perf "$PERF_FILE" "$SUMMARY_FILE"
    fi
    echo "Done. Perf: $PERF_FILE"
    exit 0
fi

# ---------- Run test + collect ----------
export PROFILE_RECORDER_SERVER_URL_PATTERN="$SOCKET_PATTERN"
echo "Starting ServerLoadTest with Profile Recorder (rooms=$ROOMS, duration=${DURATION_SECONDS}s)."
echo "Will wait ${RAMP_WAIT}s then collect $SAMPLES samples. Output: $OUTPUT_DIR"
echo ""

# Start load test in background (no monitoring to reduce noise)
bash "$SCRIPT_DIR/run-server-loadtest.sh" \
    --rooms "$ROOMS" \
    --players-per-room 5 \
    --duration-seconds "$DURATION_SECONDS" \
    --ramp-up-seconds "$RAMP_UP_SECONDS" \
    --ramp-down-seconds "$RAMP_DOWN_SECONDS" \
    --no-monitoring \
    --release \
    > "$OUTPUT_DIR/run-collect-profile-${TIMESTAMP}.log" 2>&1 &
LOADTEST_PID=$!

# Wait for socket to appear (Profile Recorder creates it with the *Swift process* PID, not the shell)
SOCK=""
SERVER_PID=""
for i in {1..90}; do
    sleep 1
    for f in /tmp/serverloadtest-samples-*.sock; do
        if [[ -S "$f" ]]; then
            SOCK=$f
            # Extract PID from filename: .../serverloadtest-samples-12345.sock
            SERVER_PID=$(basename "$f" .sock | sed 's/.*-//')
            break 2
        fi
    done
done
if [[ -z "$SOCK" ]] || [[ -z "$SERVER_PID" ]]; then
    echo "Timeout waiting for profile recorder socket. Check log: $OUTPUT_DIR/run-collect-profile-${TIMESTAMP}.log"
    kill $LOADTEST_PID 2>/dev/null || true
    exit 1
fi
echo "Profile recorder socket ready (pid $SERVER_PID). Waiting ${RAMP_WAIT}s for steady state..."
sleep "$RAMP_WAIT"

# Collect samples (process still running)
collect_samples "$SERVER_PID" || true

# Wait for load test to finish
echo "Waiting for ServerLoadTest to finish..."
wait $LOADTEST_PID 2>/dev/null || true

if [[ "$DO_ANALYZE" == true ]] && [[ -f "$PERF_FILE" ]] && [[ -s "$PERF_FILE" ]]; then
    analyze_perf "$PERF_FILE" "$SUMMARY_FILE"
fi

echo ""
echo "Done. Perf: $PERF_FILE"
echo "Summary: $SUMMARY_FILE"
echo "View: drag $PERF_FILE into https://speedscope.app or https://profiler.firefox.com"
