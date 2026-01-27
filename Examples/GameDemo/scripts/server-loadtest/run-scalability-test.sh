#!/bin/bash
# Scalability test runner - Tests multiple room counts to find performance limits
# Usage: bash run-scalability-test.sh [options]

# Don't exit on error - we want to continue testing even if one test fails
set +e

# Defaults
PLAYERS_PER_ROOM=5
DURATION_SECONDS=60
RAMP_UP_SECONDS=30  # Increased for more realistic ramp-up (avoids peak spikes)
RAMP_DOWN_SECONDS=10  # Increased for smoother ramp-down
ACTIONS_PER_PLAYER_PER_SECOND=1
LOG_LEVEL=warning
START_ROOMS=100
MAX_ROOMS=2000
ROOM_INCREMENT=400  # Test 100, 500, 1000, 1500, 2000 by default
CPU_THRESHOLD=80.0  # Stop if average CPU usage exceeds this percentage
FAILURE_THRESHOLD=3  # Stop after N consecutive failures

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
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
        --log-level)
            LOG_LEVEL="$2"
            shift 2
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
        --cpu-threshold)
            CPU_THRESHOLD="$2"
            shift 2
            ;;
        --test-rooms)
            # Custom room list: --test-rooms "100 500 1000"
            TEST_ROOMS="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Scalability Test Options:"
            echo "  --start-rooms <N>                    Starting room count (default: $START_ROOMS)"
            echo "  --max-rooms <N>                      Maximum room count to test (default: $MAX_ROOMS)"
            echo "  --room-increment <N>                 Increment between tests (default: $ROOM_INCREMENT)"
            echo "  --test-rooms \"N1 N2 N3\"              Custom room list (overrides start/max/increment)"
            echo "  --cpu-threshold <N>                  Stop if avg CPU > N% (default: $CPU_THRESHOLD)"
            echo ""
            echo "Test Configuration (passed to run-server-loadtest.sh):"
            echo "  --players-per-room <N>               (default: $PLAYERS_PER_ROOM)"
            echo "  --duration-seconds <N>               (default: $DURATION_SECONDS)"
            echo "  --ramp-up-seconds <N>                (default: $RAMP_UP_SECONDS)"
            echo "  --ramp-down-seconds <N>               (default: $RAMP_DOWN_SECONDS)"
            echo "  --actions-per-player-per-second <N>   (default: $ACTIONS_PER_PLAYER_PER_SECOND)"
            echo "  --log-level <level>                  (default: $LOG_LEVEL)"
            echo ""
            echo "Examples:"
            echo "  # Test 100, 500, 1000 rooms"
            echo "  $0 --test-rooms \"100 500 1000\""
            echo ""
            echo "  # Test from 100 to 2000 with 400 increment"
            echo "  $0 --start-rooms 100 --max-rooms 2000 --room-increment 400"
            echo ""
            echo "  # Test with custom CPU threshold"
            echo "  $0 --test-rooms \"100 500 1000\" --cpu-threshold 70.0"
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

# Build room list
if [ -n "$TEST_ROOMS" ]; then
    # Use custom room list
    ROOM_LIST=($TEST_ROOMS)
else
    # Generate room list from start/max/increment
    ROOM_LIST=()
    for ((rooms=$START_ROOMS; rooms<=$MAX_ROOMS; rooms+=$ROOM_INCREMENT)); do
        ROOM_LIST+=($rooms)
    done
fi

echo "=========================================="
echo "Scalability Test Suite"
echo "=========================================="
echo "Room counts to test: ${ROOM_LIST[@]}"
echo "Players per room: $PLAYERS_PER_ROOM"
echo "Test duration: ${DURATION_SECONDS}s (steady state)"
echo "CPU threshold: ${CPU_THRESHOLD}%"
echo "=========================================="
echo ""

# Create results summary file
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%S")
SUMMARY_FILE="$GAMEDEMO_ROOT/results/server-loadtest/scalability-test-${TIMESTAMP}.json"
SUMMARY_DIR=$(dirname "$SUMMARY_FILE")
mkdir -p "$SUMMARY_DIR"

# Initialize summary JSON
SUMMARY_DATA="{
  \"timestamp\": \"$TIMESTAMP\",
  \"config\": {
    \"playersPerRoom\": $PLAYERS_PER_ROOM,
    \"durationSeconds\": $DURATION_SECONDS,
    \"rampUpSeconds\": $RAMP_UP_SECONDS,
    \"rampDownSeconds\": $RAMP_DOWN_SECONDS,
    \"actionsPerPlayerPerSecond\": $ACTIONS_PER_PLAYER_PER_SECOND,
    \"logLevel\": \"$LOG_LEVEL\",
    \"cpuThreshold\": $CPU_THRESHOLD
  },
  \"roomList\": [$(IFS=,; echo "${ROOM_LIST[*]}")],
  \"results\": []
}"

echo "$SUMMARY_DATA" > "$SUMMARY_FILE"

# Track failures
CONSECUTIVE_FAILURES=0
LAST_TEST_PASSED=true

# Run tests
for ROOMS in "${ROOM_LIST[@]}"; do
    echo ""
    echo "=========================================="
    echo "Testing: $ROOMS rooms"
    echo "=========================================="
    echo ""
    
    # Run the test
    TEST_START_TIME=$(date +%s)
    TEST_LOG_FILE="$SUMMARY_DIR/test-${ROOMS}rooms.log"
    
    # Run test and capture exit code (don't fail script on test failure)
    bash "$SCRIPT_DIR/run-server-loadtest.sh" \
        --rooms "$ROOMS" \
        --players-per-room "$PLAYERS_PER_ROOM" \
        --duration-seconds "$DURATION_SECONDS" \
        --ramp-up-seconds "$RAMP_UP_SECONDS" \
        --ramp-down-seconds "$RAMP_DOWN_SECONDS" \
        --actions-per-player-per-second "$ACTIONS_PER_PLAYER_PER_SECOND" \
        --log-level "$LOG_LEVEL" \
        2>&1 | tee "$TEST_LOG_FILE"
    
    TEST_EXIT_CODE=${PIPESTATUS[0]}
    
    TEST_END_TIME=$(date +%s)
    TEST_DURATION=$((TEST_END_TIME - TEST_START_TIME))
    
    # Extract test result JSON path from log (look for "Results saved to:" line)
    TEST_RESULT_JSON=$(grep "Results saved to:" "$TEST_LOG_FILE" 2>/dev/null | sed 's/.*Results saved to: //' | head -n 1)
    
    # Fallback: find most recent JSON file matching pattern
    if [ -z "$TEST_RESULT_JSON" ] || [ ! -f "$TEST_RESULT_JSON" ]; then
        TEST_RESULT_JSON=$(find "$GAMEDEMO_ROOT/results/server-loadtest" -name "*rooms${ROOMS}*" -name "*.json" ! -name "*monitoring*" ! -name "*scalability*" -type f 2>/dev/null | while read f; do
            echo "$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0) $f"
        done | sort -rn | head -n 1 | awk '{print $2}')
    fi
    
    RESULT_ENTRY=""
    
    if [ -n "$TEST_RESULT_JSON" ] && [ -f "$TEST_RESULT_JSON" ]; then
        # Extract key metrics from test result JSON
        METRICS=$(python3 -c "
import json
import sys

try:
    with open('$TEST_RESULT_JSON', 'r') as f:
        data = json.load(f)
    
    # Get test config
    config = data.get('metadata', {}).get('loadTestConfig', {})
    
    # Get samples
    samples = data.get('samples', [])
    steady_samples = [s for s in samples if s.get('phase') == 'steady']
    
    # Calculate averages
    if steady_samples:
        avg_sent_bps = sum(s.get('sentBytesPerSecond', 0) for s in steady_samples) / len(steady_samples)
        avg_recv_bps = sum(s.get('recvBytesPerSecond', 0) for s in steady_samples) / len(steady_samples)
        avg_sent_mps = sum(s.get('sentMessagesPerSecond', 0) for s in steady_samples) / len(steady_samples)
        avg_recv_mps = sum(s.get('recvMessagesPerSecond', 0) for s in steady_samples) / len(steady_samples)
    else:
        avg_sent_bps = avg_recv_bps = avg_sent_mps = avg_recv_mps = 0
    
    # Get monitoring data if available
    monitoring = data.get('metadata', {}).get('systemMonitoring', {})
    vmstat_summary = monitoring.get('vmstat_summary', {})
    avg_cpu_user = vmstat_summary.get('avg_cpu_us_pct', 0)
    avg_cpu_system = vmstat_summary.get('avg_cpu_sy_pct', 0)
    avg_cpu_total = avg_cpu_user + avg_cpu_system
    
    result = {
        'rooms': $ROOMS,
        'testDuration': $TEST_DURATION,
        'testExitCode': $TEST_EXIT_CODE,
        'success': $TEST_EXIT_CODE == 0,
        'avgCpuUser': round(avg_cpu_user, 2),
        'avgCpuSystem': round(avg_cpu_system, 2),
        'avgCpuTotal': round(avg_cpu_total, 2),
        'avgSentBytesPerSecond': round(avg_sent_bps, 0),
        'avgRecvBytesPerSecond': round(avg_recv_bps, 0),
        'avgSentMessagesPerSecond': round(avg_sent_mps, 2),
        'avgRecvMessagesPerSecond': round(avg_recv_mps, 2),
        'steadySamples': len(steady_samples),
        'testResultJson': '$TEST_RESULT_JSON'
    }
    
    print(json.dumps(result))
except Exception as e:
    print(json.dumps({
        'rooms': $ROOMS,
        'testDuration': $TEST_DURATION,
        'testExitCode': $TEST_EXIT_CODE,
        'success': False,
        'error': str(e)
    }), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)
        
        if [ -n "$METRICS" ]; then
            RESULT_ENTRY="$METRICS"
            
            # Extract CPU usage
            AVG_CPU=$(echo "$METRICS" | python3 -c "import json, sys; d=json.load(sys.stdin); print(d.get('avgCpuTotal', 0))" 2>/dev/null || echo "0")
            SUCCESS=$(echo "$METRICS" | python3 -c "import json, sys; d=json.load(sys.stdin); print(str(d.get('success', False)).lower())" 2>/dev/null || echo "false")
            
            # Check if test passed
            if [ "$SUCCESS" = "true" ]; then
                CONSECUTIVE_FAILURES=0
                LAST_TEST_PASSED=true
                
                echo ""
                echo "✅ Test PASSED: $ROOMS rooms"
                echo "   Avg CPU: ${AVG_CPU}%"
                
                # Check CPU threshold
                CPU_EXCEEDS=$(python3 -c "print('1' if float('$AVG_CPU') > float('$CPU_THRESHOLD') else '0')" 2>/dev/null || echo "0")
                if [ "$CPU_EXCEEDS" = "1" ]; then
                    echo "⚠️  WARNING: CPU usage (${AVG_CPU}%) exceeds threshold (${CPU_THRESHOLD}%)"
                    echo "   Consider stopping here or reducing room count"
                fi
            else
                CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
                LAST_TEST_PASSED=false
                echo ""
                echo "❌ Test FAILED: $ROOMS rooms (exit code: $TEST_EXIT_CODE)"
            fi
        else
            RESULT_ENTRY="{\"rooms\": $ROOMS, \"testDuration\": $TEST_DURATION, \"testExitCode\": $TEST_EXIT_CODE, \"success\": false, \"error\": \"Failed to parse test results\"}"
            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            LAST_TEST_PASSED=false
        fi
    else
        RESULT_ENTRY="{\"rooms\": $ROOMS, \"testDuration\": $TEST_DURATION, \"testExitCode\": $TEST_EXIT_CODE, \"success\": false, \"error\": \"Test result JSON not found\"}"
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        LAST_TEST_PASSED=false
        echo ""
        echo "❌ Test FAILED: $ROOMS rooms - Result JSON not found"
    fi
    
    # Update summary JSON
    python3 -c "
import json
import sys

with open('$SUMMARY_FILE', 'r') as f:
    summary = json.load(f)

result = json.loads('''$RESULT_ENTRY''')
summary['results'].append(result)

with open('$SUMMARY_FILE', 'w') as f:
    json.dump(summary, f, indent=2)
" 2>/dev/null || true
    
    # Check if we should stop
    if [ $CONSECUTIVE_FAILURES -ge $FAILURE_THRESHOLD ]; then
        echo ""
        echo "⚠️  Stopping: $CONSECUTIVE_FAILURES consecutive failures (threshold: $FAILURE_THRESHOLD)"
        break
    fi
    
    # Small delay between tests
    if [ "$ROOMS" != "${ROOM_LIST[-1]}" ]; then
        echo ""
        echo "Waiting 5 seconds before next test..."
        sleep 5
    fi
done

# Generate summary report
echo ""
echo "=========================================="
echo "Scalability Test Summary"
echo "=========================================="
echo ""

python3 -c "
import json
import sys

with open('$SUMMARY_FILE', 'r') as f:
    summary = json.load(f)

print(f\"Total tests: {len(summary['results'])}\")
print(f\"Room counts tested: {', '.join(str(r['rooms']) for r in summary['results'])}\")
print()

passed = [r for r in summary['results'] if r.get('success', False)]
failed = [r for r in summary['results'] if not r.get('success', False)]

print(f\"✅ Passed: {len(passed)}\")
print(f\"❌ Failed: {len(failed)}\")
print()

if passed:
    print(\"Performance Summary:\")
    print(\"-\" * 60)
    print(f\"{'Rooms':<10} {'CPU %':<10} {'Sent KB/s':<12} {'Recv KB/s':<12} {'Status'}\")
    print(\"-\" * 60)
    for r in summary['results']:
        rooms = r.get('rooms', 'N/A')
        cpu = r.get('avgCpuTotal', 0)
        sent = r.get('avgSentBytesPerSecond', 0) / 1024
        recv = r.get('avgRecvBytesPerSecond', 0) / 1024
        status = '✅' if r.get('success', False) else '❌'
        print(f\"{rooms:<10} {cpu:<10.1f} {sent:<12.1f} {recv:<12.1f} {status}\")
    print()

    # Find max successful rooms
    max_rooms = max((r['rooms'] for r in passed), default=0)
    print(f\"🎯 Maximum successful room count: {max_rooms}\")
    
    # Check if we hit CPU threshold
    high_cpu = [r for r in passed if r.get('avgCpuTotal', 0) > summary['config']['cpuThreshold']]
    if high_cpu:
        print(f\"⚠️  {len(high_cpu)} test(s) exceeded CPU threshold ({summary['config']['cpuThreshold']}%)\")
" 2>/dev/null || echo "Failed to generate summary"

echo ""
echo "Full results saved to: $SUMMARY_FILE"
echo ""
