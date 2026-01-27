#!/bin/bash
# Profiling test runner - Tests with performance profiling tools
# Usage: bash run-profiling-test.sh [options]

set +e

# Defaults
ROOMS=1000
PLAYERS_PER_ROOM=5
DURATION_SECONDS=30
LOG_LEVEL=warning
PROFILE_TOOL="perf"  # perf, time, or both

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
        --log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        --profile-tool)
            PROFILE_TOOL="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --rooms <N>                    (default: $ROOMS)"
            echo "  --players-per-room <N>         (default: $PLAYERS_PER_ROOM)"
            echo "  --duration-seconds <N>         (default: $DURATION_SECONDS)"
            echo "  --log-level <level>            (default: $LOG_LEVEL)"
            echo "  --profile-tool <tool>          perf|time|both (default: $PROFILE_TOOL)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."
GAMEDEMO_ROOT="$(pwd)"

# Build executable
echo "Building ServerLoadTest..."
swift build -c release
EXECUTABLE=".build/x86_64-unknown-linux-gnu/release/ServerLoadTest"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Executable not found at $EXECUTABLE"
    exit 1
fi

# Create results directory
RESULTS_DIR="$GAMEDEMO_ROOT/results/server-loadtest/profiling"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%S")
PREFIX="profile-rooms${ROOMS}-${TIMESTAMP}"

echo ""
echo "=========================================="
echo "Profiling Test: $ROOMS rooms"
echo "=========================================="
echo "Profile tool: $PROFILE_TOOL"
echo "Results will be saved to: $RESULTS_DIR"
echo ""

# Run with timeout (5 minutes max)
TIMEOUT_SECONDS=300
TEST_DURATION=$((DURATION_SECONDS + 20))  # Add buffer for ramp up/down

if [ "$PROFILE_TOOL" = "perf" ] || [ "$PROFILE_TOOL" = "both" ]; then
    if command -v perf >/dev/null 2>&1; then
        echo "Running with perf profiler..."
        echo "  (This will record CPU usage and call stacks)"
        
        timeout $TIMEOUT_SECONDS perf record -g --call-graph dwarf \
            -o "$RESULTS_DIR/${PREFIX}.perf.data" \
            "$EXECUTABLE" \
            --rooms "$ROOMS" \
            --players-per-room "$PLAYERS_PER_ROOM" \
            --duration-seconds "$DURATION_SECONDS" \
            --ramp-up-seconds 5 \
            --ramp-down-seconds 5 \
            --actions-per-player-per-second 1 \
            --log-level "$LOG_LEVEL" \
            2>&1 | tee "$RESULTS_DIR/${PREFIX}.log"
        
        EXIT_CODE=$?
        
        if [ $EXIT_CODE -eq 124 ]; then
            echo ""
            echo "⚠️  Test timed out after $TIMEOUT_SECONDS seconds"
        elif [ $EXIT_CODE -ne 0 ]; then
            echo ""
            echo "❌ Test failed with exit code: $EXIT_CODE"
        else
            echo ""
            echo "✅ Test completed"
        fi
        
        # Generate perf report
        if [ -f "$RESULTS_DIR/${PREFIX}.perf.data" ]; then
            echo ""
            echo "Generating perf report..."
            perf report --stdio -i "$RESULTS_DIR/${PREFIX}.perf.data" > "$RESULTS_DIR/${PREFIX}.perf.report.txt" 2>&1
            
            echo ""
            echo "Top 20 functions by CPU usage:"
            perf report --stdio -i "$RESULTS_DIR/${PREFIX}.perf.data" 2>/dev/null | head -n 50 | grep -E "^[[:space:]]*[0-9]" | head -n 20
            
            echo ""
            echo "📊 Perf data saved to: $RESULTS_DIR/${PREFIX}.perf.data"
            echo "📄 Perf report saved to: $RESULTS_DIR/${PREFIX}.perf.report.txt"
            echo ""
            echo "To view interactive report:"
            echo "  perf report -i $RESULTS_DIR/${PREFIX}.perf.data"
        fi
    else
        echo "⚠️  perf not found, skipping perf profiling"
    fi
fi

if [ "$PROFILE_TOOL" = "time" ] || [ "$PROFILE_TOOL" = "both" ]; then
    echo ""
    echo "Running with time profiler..."
    /usr/bin/time -v -o "$RESULTS_DIR/${PREFIX}.time.txt" \
        timeout $TIMEOUT_SECONDS "$EXECUTABLE" \
        --rooms "$ROOMS" \
        --players-per-room "$PLAYERS_PER_ROOM" \
        --duration-seconds "$DURATION_SECONDS" \
        --ramp-up-seconds 5 \
        --ramp-down-seconds 5 \
        --actions-per-player-per-second 1 \
        --log-level "$LOG_LEVEL" \
        2>&1 | tee -a "$RESULTS_DIR/${PREFIX}.log"
    
    if [ -f "$RESULTS_DIR/${PREFIX}.time.txt" ]; then
        echo ""
        echo "📊 Time statistics:"
        cat "$RESULTS_DIR/${PREFIX}.time.txt"
    fi
fi

echo ""
echo "=========================================="
echo "Profiling complete"
echo "=========================================="
echo "Results directory: $RESULTS_DIR"
echo ""
