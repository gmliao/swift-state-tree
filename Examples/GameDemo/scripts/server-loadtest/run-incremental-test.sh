#!/bin/bash
# Incremental test - Test with smaller increments to find the breaking point
# Usage: bash run-incremental-test.sh [options]

set +e

# Defaults
START_ROOMS=500
MAX_ROOMS=1000
INCREMENT=100
PLAYERS_PER_ROOM=5
DURATION_SECONDS=30
LOG_LEVEL=warning
TIMEOUT_SECONDS=180  # 3 minutes per test

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --start-rooms)
            START_ROOMS="$2"
            shift 2
            ;;
        --max-rooms)
            MAX_ROOMS="$2"
            shift 2
            ;;
        --increment)
            INCREMENT="$2"
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
        --timeout-seconds)
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        --log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --start-rooms <N>              (default: $START_ROOMS)"
            echo "  --max-rooms <N>                (default: $MAX_ROOMS)"
            echo "  --increment <N>                (default: $INCREMENT)"
            echo "  --players-per-room <N>         (default: $PLAYERS_PER_ROOM)"
            echo "  --duration-seconds <N>         (default: $DURATION_SECONDS)"
            echo "  --timeout-seconds <N>          (default: $TIMEOUT_SECONDS)"
            echo "  --log-level <level>            (default: $LOG_LEVEL)"
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

echo "=========================================="
echo "Incremental Scalability Test"
echo "=========================================="
echo "Testing from $START_ROOMS to $MAX_ROOMS rooms"
echo "Increment: $INCREMENT rooms"
echo "Timeout per test: $TIMEOUT_SECONDS seconds"
echo ""

# Build room list
ROOM_LIST=()
for ((rooms=$START_ROOMS; rooms<=$MAX_ROOMS; rooms+=$INCREMENT)); do
    ROOM_LIST+=($rooms)
done

echo "Room counts to test: ${ROOM_LIST[@]}"
echo ""

# Results
RESULTS_DIR="$GAMEDEMO_ROOT/results/server-loadtest/incremental"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%S")
RESULTS_FILE="$RESULTS_DIR/incremental-test-${TIMESTAMP}.json"

# Initialize results
echo "{\"timestamp\": \"$TIMESTAMP\", \"results\": []}" > "$RESULTS_FILE"

for ROOMS in "${ROOM_LIST[@]}"; do
    echo ""
    echo "=========================================="
    echo "Testing: $ROOMS rooms (timeout: ${TIMEOUT_SECONDS}s)"
    echo "=========================================="
    
    START_TIME=$(date +%s)
    
    # Run test with timeout
    timeout $TIMEOUT_SECONDS bash "$SCRIPT_DIR/run-server-loadtest.sh" \
        --rooms "$ROOMS" \
        --players-per-room "$PLAYERS_PER_ROOM" \
        --duration-seconds "$DURATION_SECONDS" \
        --ramp-up-seconds 5 \
        --ramp-down-seconds 5 \
        --actions-per-player-per-second 1 \
        --log-level "$LOG_LEVEL" \
        2>&1 | tee "$RESULTS_DIR/test-${ROOMS}rooms.log"
    
    EXIT_CODE=$?
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    # Check result
    if [ $EXIT_CODE -eq 124 ]; then
        echo ""
        echo "⏱️  TIMEOUT: Test exceeded ${TIMEOUT_SECONDS}s timeout"
        echo "    This suggests the system cannot handle $ROOMS rooms efficiently"
        
        # Update results
        python3 -c "
import json
with open('$RESULTS_FILE', 'r') as f:
    data = json.load(f)
data['results'].append({
    'rooms': $ROOMS,
    'success': False,
    'timeout': True,
    'duration': $DURATION,
    'exitCode': $EXIT_CODE
})
with open('$RESULTS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
        
        echo ""
        echo "⚠️  Stopping incremental test - found breaking point at $ROOMS rooms"
        break
    elif [ $EXIT_CODE -ne 0 ]; then
        echo ""
        echo "❌ Test failed with exit code: $EXIT_CODE"
        
        python3 -c "
import json
with open('$RESULTS_FILE', 'r') as f:
    data = json.load(f)
data['results'].append({
    'rooms': $ROOMS,
    'success': False,
    'timeout': False,
    'duration': $DURATION,
    'exitCode': $EXIT_CODE
})
with open('$RESULTS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
    else
        echo ""
        echo "✅ Test completed in ${DURATION}s"
        
        # Try to extract metrics
        TEST_RESULT_JSON=$(find "$GAMEDEMO_ROOT/results/server-loadtest" -name "*rooms${ROOMS}*" -name "*.json" ! -name "*monitoring*" ! -name "*incremental*" -type f 2>/dev/null | head -n 1)
        
        if [ -n "$TEST_RESULT_JSON" ] && [ -f "$TEST_RESULT_JSON" ]; then
            METRICS=$(python3 -c "
import json
try:
    with open('$TEST_RESULT_JSON', 'r') as f:
        data = json.load(f)
    monitoring = data.get('metadata', {}).get('systemMonitoring', {})
    vmstat = monitoring.get('vmstat_summary', {})
    result = {
        'rooms': $ROOMS,
        'success': True,
        'duration': $DURATION,
        'avgCpuTotal': vmstat.get('avg_cpu_us_pct', 0) + vmstat.get('avg_cpu_sy_pct', 0),
        'avgCpuUser': vmstat.get('avg_cpu_us_pct', 0),
        'avgCpuSystem': vmstat.get('avg_cpu_sy_pct', 0)
    }
    print(json.dumps(result))
except:
    print(json.dumps({'rooms': $ROOMS, 'success': True, 'duration': $DURATION}))
" 2>/dev/null)
            
            if [ -n "$METRICS" ]; then
                python3 -c "
import json
with open('$RESULTS_FILE', 'r') as f:
    data = json.load(f)
result = json.loads('''$METRICS''')
data['results'].append(result)
with open('$RESULTS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null
                
                CPU=$(echo "$METRICS" | python3 -c "import json, sys; print(json.load(sys.stdin).get('avgCpuTotal', 0))" 2>/dev/null || echo "0")
                echo "   CPU usage: ${CPU}%"
            fi
        fi
    fi
    
    # Small delay between tests
    if [ "$ROOMS" != "${ROOM_LIST[-1]}" ]; then
        echo ""
        echo "Waiting 5 seconds before next test..."
        sleep 5
    fi
done

# Summary
echo ""
echo "=========================================="
echo "Incremental Test Summary"
echo "=========================================="
python3 -c "
import json
with open('$RESULTS_FILE', 'r') as f:
    data = json.load(f)
    
successful = [r for r in data['results'] if r.get('success')]
failed = [r for r in data['results'] if not r.get('success')]
timeouts = [r for r in failed if r.get('timeout')]

print(f\"Total tests: {len(data['results'])}\")
print(f\"✅ Successful: {len(successful)}\")
print(f\"❌ Failed: {len(failed)}\")
if timeouts:
    print(f\"⏱️  Timeouts: {len(timeouts)}\")
    print(f\"   Breaking point: {max(r['rooms'] for r in timeouts)} rooms\")

if successful:
    print(\"\nPerformance:\")
    for r in successful:
        rooms = r['rooms']
        cpu = r.get('avgCpuTotal', 0)
        duration = r.get('duration', 0)
        print(f\"  {rooms} rooms: CPU {cpu:.1f}%, Duration {duration}s\")
" 2>/dev/null

echo ""
echo "📁 Results saved to: $RESULTS_FILE"
echo ""
