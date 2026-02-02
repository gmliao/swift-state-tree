#!/bin/bash
# ServerLoadTest runner with optional external system monitoring.
# When monitoring is enabled, uses pidstat/vmstat (Linux) or ps sampling (macOS)
# so that metrics are collected outside the test process.
#
# Script structure:
#   1. Parse options (--rooms, --no-monitoring, etc.)
#   2. Start system monitoring in background (if not --no-monitoring)
#   3. Run swift run ServerLoadTest (foreground, tee to temp log)
#   4. Stop monitoring, parse logs to JSON/HTML, merge into test result
#
# Requires bash (not sh): [[ ]], ${BASH_SOURCE[0]}, arrays. Run:
#   bash run-server-loadtest.sh [options]
#   ./run-server-loadtest.sh [options]   # after chmod +x

set -e

# Defaults
ROOMS=500
PLAYERS_PER_ROOM=5
DURATION_SECONDS=60
RAMP_UP_SECONDS=30  # Increased from 5 to 30 for more realistic ramp-up
RAMP_DOWN_SECONDS=10  # Increased from 5 to 10 for smoother ramp-down
ACTIONS_PER_PLAYER_PER_SECOND=1
TUI=false
LOG_LEVEL=error
ENABLE_MONITORING=true  # Set to false to disable monitoring for precise benchmarks
ENABLE_PROFILING=false  # Enable transport profiling (TRANSPORT_PROFILE_JSONL_PATH)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --rooms)
            ROOMS="$2"
            shift 2
            ;;
        --players-per-room)
            PLAYERS_PER_ROOM="$2"
            shift 2
            ;;
        --duration-seconds)
            DURATION_SECONDS="$2"
            shift 2
            ;;
        --ramp-up-seconds)
            RAMP_UP_SECONDS="$2"
            shift 2
            ;;
        --ramp-down-seconds)
            RAMP_DOWN_SECONDS="$2"
            shift 2
            ;;
        --actions-per-player-per-second)
            ACTIONS_PER_PLAYER_PER_SECOND="$2"
            shift 2
            ;;
        --tui)
            TUI="$2"
            shift 2
            ;;
        --log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        --no-monitoring)
            ENABLE_MONITORING=false
            shift
            ;;
        --profile)
            ENABLE_PROFILING=true
            shift
            ;;
        --build-mode)
            BUILD_MODE="$2"
            shift 2
            ;;
        --release)
            BUILD_MODE="release"
            shift
            ;;
        --debug)
            BUILD_MODE="debug"
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --rooms <N>                         (default: $ROOMS)"
            echo "  --players-per-room <N>              (default: $PLAYERS_PER_ROOM)"
            echo "  --duration-seconds <N>              (default: $DURATION_SECONDS)"
            echo "  --ramp-up-seconds <N>               (default: $RAMP_UP_SECONDS)"
            echo "  --no-monitoring                     Disable system monitoring (for precise benchmarks)"
            echo "  --profile                           Enable transport profiling (decode/handle/encode/send JSONL)"
            echo "  --ramp-down-seconds <N>             (default: $RAMP_DOWN_SECONDS)"
            echo "  --actions-per-player-per-second <N>  (default: $ACTIONS_PER_PLAYER_PER_SECOND)"
            echo "  --tui <true|false>                  (default: $TUI)"
            echo "  --log-level <level>                 (default: $LOG_LEVEL)"
            echo "  --build-mode <debug|release>        (default: auto-detect)"
            echo "  --release                           (shortcut for --build-mode release)"
            echo "  --debug                             (shortcut for --build-mode debug)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Calculate total runtime
TOTAL_SECONDS=$((RAMP_UP_SECONDS + DURATION_SECONDS + RAMP_DOWN_SECONDS + 10))  # +10 for cleanup

# Get script directory (scripts/server-loadtest/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Navigate to GameDemo directory (where Package.swift is)
cd "$SCRIPT_DIR/../.."
GAMEDEMO_ROOT="$(pwd)"

# Auto-detect build mode if not specified
# Default to release for realistic performance numbers.
# (If you hit local-only issues, use --debug to fall back.)
if [ -z "$BUILD_MODE" ]; then
    BUILD_MODE="release"
    echo "Using build mode: release"
else
    echo "Using build mode: $BUILD_MODE (user-specified)"
fi

# Create temp directory for monitoring data
TEMP_DIR=$(mktemp -d)
MONITOR_LOG="$TEMP_DIR/monitor.log"
PIDSTAT_LOG="$TEMP_DIR/pidstat.csv"

# Cleanup function
cleanup() {
    if [ -n "$VMSTAT_PID" ]; then
        kill "$VMSTAT_PID" 2>/dev/null || true
        wait "$VMSTAT_PID" 2>/dev/null || true
    fi
    if [ -n "$PIDSTAT_PID" ]; then
        kill "$PIDSTAT_PID" 2>/dev/null || true
        wait "$PIDSTAT_PID" 2>/dev/null || true
    fi
    if [ -n "$PS_SAMPLER_PID" ]; then
        kill "$PS_SAMPLER_PID" 2>/dev/null || true
        wait "$PS_SAMPLER_PID" 2>/dev/null || true
    fi
    # Note: Monitoring files are already copied to results directory
    # TEMP_DIR will be cleaned up automatically by system
}
trap cleanup EXIT

# Start system monitoring (vmstat for system-wide, will add pidstat after test starts)
VMSTAT_PID=""
PIDSTAT_PID=""
PS_SAMPLER_PID=""

# Detect OS
OS_TYPE=$(uname -s)
if [ "$OS_TYPE" = "Darwin" ]; then
    PIDSTAT_LOG="$TEMP_DIR/ps_cpu.csv"
fi

start_macos_ps_sampler() {
    local log_path="$1"
    local pattern="[S]erverLoadTest"
    local interval_seconds=1

    echo "timestamp_epoch_s,cpu_pct,pid" > "$log_path"

    local pid=""
    for _ in $(seq 1 50); do
        pid=$(pgrep -n -f "$pattern" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            break
        fi
        sleep 0.2
    done

    if [ -z "$pid" ]; then
        echo "Warning: Failed to find ServerLoadTest process for CPU monitoring"
        return 0
    fi

    while true; do
        if ! ps -p "$pid" >/dev/null 2>&1; then
            break
        fi
        local ts
        ts=$(date +%s)
        local cpu
        cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | awk '{print $1}')
        if [ -n "$cpu" ]; then
            echo "$ts,$cpu,$pid" >> "$log_path"
        fi
        sleep "$interval_seconds"
    done
}

if [ "$ENABLE_MONITORING" = "true" ]; then
    echo "Starting system monitoring..."
else
    echo "⚠️  Monitoring disabled (--no-monitoring). Use this for precise benchmarks."
fi

# Start system-wide monitoring
if [ "$ENABLE_MONITORING" = "true" ]; then
    if [ "$OS_TYPE" = "Linux" ]; then
        # Linux: use vmstat
        if command -v vmstat >/dev/null 2>&1; then
            vmstat 1 > "$TEMP_DIR/vmstat.log" 2>&1 &
            VMSTAT_PID=$!
            echo "Started vmstat (system-wide monitoring)"
        fi
    elif [ "$OS_TYPE" = "Darwin" ]; then
        # macOS: System-wide monitoring disabled (vmstat/pidstat are Linux-only tools)
        # macOS alternatives (top/iostat) have higher overhead and less accurate data
        # For accurate system-wide monitoring, run tests on Linux
        # macOS: System-wide monitoring limited
        # Note: macOS doesn't have Linux's vmstat/pidstat (sysstat package)
        # Using ps sampling for process CPU monitoring
        :
    fi
fi

# Detect CPU cores for normalization
CPU_CORES=""
if [ "$OS_TYPE" = "Darwin" ]; then
    CPU_CORES=$(sysctl -n hw.ncpu 2>/dev/null || echo "1")
elif [ "$OS_TYPE" = "Linux" ]; then
    CPU_CORES=$(nproc 2>/dev/null || echo "1")
fi

# Transport profiling: when --profile is used, ServerLoadTest (LandServer) writes JSONL
if [ "$ENABLE_PROFILING" = "true" ]; then
    PROFILE_TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
    export TRANSPORT_PROFILE_JSONL_PATH="$GAMEDEMO_ROOT/results/server-loadtest/transport-profile-${PROFILE_TIMESTAMP}.jsonl"
    mkdir -p "$(dirname "$TRANSPORT_PROFILE_JSONL_PATH")"
    rm -f "$TRANSPORT_PROFILE_JSONL_PATH"
    echo "Transport profiling enabled: $TRANSPORT_PROFILE_JSONL_PATH"
fi

# Start the load test
echo "Starting ServerLoadTest (Client Simulator)..."
echo "  Rooms: $ROOMS"
echo "  Players per room: $PLAYERS_PER_ROOM"
echo "  Duration: $DURATION_SECONDS seconds"
echo "  Total runtime: ~$TOTAL_SECONDS seconds"
echo ""

# Run the test and try to find the actual process PID for process monitoring
if [ "$ENABLE_MONITORING" = "true" ]; then
    if [ "$OS_TYPE" = "Linux" ]; then
        # Linux: use pidstat
        if command -v pidstat >/dev/null 2>&1; then
            # Start pidstat monitoring all processes (we'll filter later)
            pidstat 1 > "$PIDSTAT_LOG" 2>&1 &
            PIDSTAT_PID=$!
            echo "Started pidstat (will filter for ServerLoadTest process)"
        fi
    elif [ "$OS_TYPE" = "Darwin" ]; then
        # macOS: Use low-overhead ps sampling for process CPU usage
        if command -v pgrep >/dev/null 2>&1; then
            start_macos_ps_sampler "$PIDSTAT_LOG" &
            PS_SAMPLER_PID=$!
            echo "Started ps sampler (process CPU monitoring)"
        else
            echo "⚠️  pgrep not found; process monitoring disabled on macOS"
        fi
    fi
fi

# Run the test (foreground, so we can see output)
swift run -c "$BUILD_MODE" ServerLoadTest \
    --rooms "$ROOMS" \
    --players-per-room "$PLAYERS_PER_ROOM" \
    --duration-seconds "$DURATION_SECONDS" \
    --ramp-up-seconds "$RAMP_UP_SECONDS" \
    --ramp-down-seconds "$RAMP_DOWN_SECONDS" \
    --actions-per-player-per-second "$ACTIONS_PER_PLAYER_PER_SECOND" \
    --tui "$TUI" \
    --log-level "$LOG_LEVEL" 2>&1 | tee "$TEMP_DIR/test_output.log"

TEST_EXIT_CODE=$?

# Extract test result JSON path from output
TEST_RESULT_JSON=$(grep "Results saved to:" "$TEMP_DIR/test_output.log" | sed 's/.*Results saved to: //' || echo "")

# Determine results directory (same as test result JSON)
if [ -n "$TEST_RESULT_JSON" ] && [ -f "$TEST_RESULT_JSON" ]; then
    RESULTS_DIR=$(dirname "$TEST_RESULT_JSON")
    # Generate monitoring file names based on test result filename
    TEST_BASENAME=$(basename "$TEST_RESULT_JSON" .json)
    MONITORING_JSON_FINAL="$RESULTS_DIR/${TEST_BASENAME}-monitoring.json"
    MONITORING_HTML_FINAL="$RESULTS_DIR/${TEST_BASENAME}-monitoring.html"
else
    # Fallback: use results directory at GameDemo/results/server-loadtest
    RESULTS_DIR="$GAMEDEMO_ROOT/results/server-loadtest"
    mkdir -p "$RESULTS_DIR"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
    MONITORING_JSON_FINAL="$RESULTS_DIR/monitoring-${TIMESTAMP}.json"
    MONITORING_HTML_FINAL="$RESULTS_DIR/monitoring-${TIMESTAMP}.html"
fi

if [ $TEST_EXIT_CODE -ne 0 ]; then
    echo "Warning: ServerLoadTest exited with code $TEST_EXIT_CODE"
fi

# Stop monitoring (no-op if monitoring was disabled)
if [ "$ENABLE_MONITORING" = "true" ]; then
    echo ""
    echo "Stopping system monitoring..."
    if [ -n "$PIDSTAT_PID" ]; then
        kill "$PIDSTAT_PID" 2>/dev/null || true
        wait "$PIDSTAT_PID" 2>/dev/null || true
    fi
    if [ -n "$VMSTAT_PID" ]; then
        kill "$VMSTAT_PID" 2>/dev/null || true
        wait "$VMSTAT_PID" 2>/dev/null || true
    fi
    if [ -n "$PS_SAMPLER_PID" ]; then
        kill "$PS_SAMPLER_PID" 2>/dev/null || true
        wait "$PS_SAMPLER_PID" 2>/dev/null || true
    fi
fi

# Parse monitoring data to JSON (only when monitoring was enabled)
MONITORING_JSON_TEMP="$TEMP_DIR/monitoring.json"
PARSE_SCRIPT="$GAMEDEMO_ROOT/scripts/server-loadtest/parse_monitoring.py"

if [ "$ENABLE_MONITORING" = "true" ]; then
echo ""
echo "Converting monitoring data to JSON..."
if [ -f "$PARSE_SCRIPT" ]; then
    parse_args=(python3 "$PARSE_SCRIPT" --vmstat "$TEMP_DIR/vmstat.log" --pidstat "$PIDSTAT_LOG" --output "$MONITORING_JSON_TEMP" --html "$MONITORING_HTML_FINAL" --process-name "ServerLoadTest")
    [ -n "$CPU_CORES" ] && parse_args+=(--cpu-cores "$CPU_CORES")
    if [ -n "$TEST_RESULT_JSON" ] && [ -f "$TEST_RESULT_JSON" ]; then
        parse_args+=(--test-result-json "$TEST_RESULT_JSON")
    fi
    "${parse_args[@]}" 2>/dev/null || {
        echo "Warning: Failed to parse monitoring data (python3 error)"
    }
    
    if [ -f "$MONITORING_JSON_TEMP" ]; then
        # Copy monitoring JSON to results directory
        cp "$MONITORING_JSON_TEMP" "$MONITORING_JSON_FINAL" 2>/dev/null && {
            echo "Monitoring JSON saved to: $MONITORING_JSON_FINAL"
        } || {
            echo "Warning: Failed to copy monitoring JSON to results directory"
        }
        
        # Optionally merge monitoring data into test result JSON
        if [ -n "$TEST_RESULT_JSON" ] && [ -f "$TEST_RESULT_JSON" ]; then
            echo "Merging monitoring data into test result JSON..."
            python3 -c "
import json
import sys
from pathlib import Path

try:
    test_json_path = Path('$TEST_RESULT_JSON')
    monitor_json_path = Path('$MONITORING_JSON_TEMP')
    
    with open(test_json_path, 'r') as f:
        test_data = json.load(f)
    
    with open(monitor_json_path, 'r') as f:
        monitor_data = json.load(f)
    
    # Add monitoring data to metadata
    if 'metadata' not in test_data:
        test_data['metadata'] = {}
    test_data['metadata']['systemMonitoring'] = monitor_data
    
    # Write back
    with open(test_json_path, 'w') as f:
        json.dump(test_data, f, indent=2)
    
    print(f\"Merged monitoring data into: $TEST_RESULT_JSON\")
except Exception as e:
    print(f'Warning: Failed to merge monitoring data: {e}', file=sys.stderr)
" 2>/dev/null || echo "Warning: Failed to merge monitoring data into test result JSON"
        fi
        
        echo ""
        echo "=== Monitoring Summary (from JSON) ==="
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import json
import sys
try:
    with open('$MONITORING_JSON_TEMP', 'r') as f:
        data = json.load(f)
    if 'vmstat_summary' in data:
        s = data['vmstat_summary']
        print(f\"vmstat: {s.get('sample_count', 0)} samples, avg CPU us={s.get('avg_cpu_us_pct', 0):.1f}%, sy={s.get('avg_cpu_sy_pct', 0):.1f}%, id={s.get('avg_cpu_id_pct', 0):.1f}%\")
    if 'pidstat_summary' in data:
        s = data['pidstat_summary']
        print(f\"pidstat: {s.get('sample_count', 0)} samples, avg CPU={s.get('avg_cpu_total_pct', 0):.1f}%, peak={s.get('peak_cpu_total_pct', 0):.1f}%\")
except Exception as e:
    print(f'Error reading JSON: {e}', file=sys.stderr)
" 2>/dev/null || true
        fi
    fi
else
    echo "Warning: parse_monitoring.py not found, skipping JSON conversion"
fi

# Display raw monitoring summary
echo ""
echo "=== Raw Monitoring Data ==="
if [ -f "$PIDSTAT_LOG" ]; then
    echo "pidstat data: $PIDSTAT_LOG"
    echo "Last 5 lines:"
    tail -n 5 "$PIDSTAT_LOG" 2>/dev/null || true
fi
if [ -f "$TEMP_DIR/vmstat.log" ]; then
    echo ""
    echo "vmstat data: $TEMP_DIR/vmstat.log"
    echo "Last 5 lines:"
    tail -n 5 "$TEMP_DIR/vmstat.log" 2>/dev/null || true
fi
echo ""
echo "Monitoring data files:"
if [ -f "$MONITORING_JSON_FINAL" ]; then
    echo "  Monitoring JSON: $MONITORING_JSON_FINAL"
fi
if [ -f "$MONITORING_HTML_FINAL" ]; then
    echo "  Monitoring HTML: $MONITORING_HTML_FINAL"
    echo "    (Open in browser to view interactive charts)"
fi
echo ""
echo "Raw monitoring logs (temporary): $TEMP_DIR"
else
    echo ""
    echo "Monitoring was disabled (--no-monitoring). Test results (if any) are above."
fi
