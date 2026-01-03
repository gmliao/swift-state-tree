#!/usr/bin/env bash
# Fix Windows line endings if present (for Windows Docker compatibility)
if command -v dos2unix >/dev/null 2>&1; then
    # Check if file has CRLF line endings
    if file "$0" 2>/dev/null | grep -q "CRLF"; then
        dos2unix "$0" 2>/dev/null || true
    fi
fi

set -eu
set -o pipefail

# Change to repository root (this script lives in Tools/CLI)
cd "$(dirname "$0")/../.."

# Ensure OUT_DIR doesn't contain any line endings or whitespace
OUT_DIR="Notes/performance"
OUT_DIR=$(echo -n "$OUT_DIR" | tr -d '\r\n' | xargs)
mkdir -p "$OUT_DIR"

# Generate timestamp for file naming (format: YYYYMMDD-HHMMSS)
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# Function to generate machine identifier from system info
generate_machine_id() {
    local cpu_model="unknown"
    local cpu_cores="unknown"
    local ram_gb="unknown"
    local swift_version="unknown"
    local os_type=$(uname -s)

    # CPU Information
    if [ "$os_type" = "Darwin" ]; then
        # macOS
        cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30)
        if [ -z "$cpu_model" ]; then
            # Fallback for Apple Silicon or unknown CPUs
            cpu_model="Apple_Silicon"
        fi
        cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || sysctl -n hw.physicalcpu 2>/dev/null)
    elif [ -f /proc/cpuinfo ]; then
        # Linux
        cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[[:space:]]*//' | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30)
        cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
    fi

    # Memory Information
    if [ "$os_type" = "Darwin" ]; then
        # macOS - memsize is in bytes
        local total_mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
        if [ -n "$total_mem_bytes" ] && [ "$total_mem_bytes" != "0" ]; then
            local total_mem_gb=$((total_mem_bytes / 1024 / 1024 / 1024))
            ram_gb="${total_mem_gb}GB"
        fi
    elif [ -f /proc/meminfo ]; then
        # Linux
        local total_mem_kb=$(grep "MemTotal" /proc/meminfo | awk '{print $2}')
        if [ -n "$total_mem_kb" ]; then
            local total_mem_gb=$((total_mem_kb / 1024 / 1024))
            ram_gb="${total_mem_gb}GB"
        fi
    fi

    # Swift Information (works on both platforms)
    local swift_full_version=$(swift --version 2>/dev/null | head -1)
    if [ -n "$swift_full_version" ]; then
        swift_version=$(echo "$swift_full_version" | grep -oE 'version [0-9]+\.[0-9]+' | cut -d' ' -f2 | head -1)
        if [ -z "$swift_version" ]; then
            swift_version="unknown"
        fi
    fi

    # Generate machine identifier: CPU-Cores-RAM-SwiftVersion
    echo "${cpu_model}-${cpu_cores}cores-${ram_gb}-swift${swift_version}"
}

# Function to collect system information
collect_system_info() {
    echo "=== System Information ==="
    echo "Timestamp: $(date)"
    echo ""

    local os_type=$(uname -s)

    # CPU Information
    echo "--- CPU ---"
    if [ "$os_type" = "Darwin" ]; then
        # macOS
        local cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
        local cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || sysctl -n hw.physicalcpu 2>/dev/null || echo "Unknown")
        local cpu_arch=$(uname -m)
        echo "Model: ${cpu_model}"
        echo "Cores: ${cpu_cores}"
        echo "Architecture: ${cpu_arch}"
    elif [ -f /proc/cpuinfo ]; then
        # Linux
        local cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[[:space:]]*//')
        local cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
        local cpu_arch=$(uname -m)
        echo "Model: ${cpu_model}"
        echo "Cores: ${cpu_cores}"
        echo "Architecture: ${cpu_arch}"
    else
        echo "CPU info not available"
    fi
    echo ""

    # Memory Information
    echo "--- Memory ---"
    if [ "$os_type" = "Darwin" ]; then
        # macOS - memsize is in bytes
        local total_mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
        if [ -n "$total_mem_bytes" ] && [ "$total_mem_bytes" != "0" ]; then
            local total_mem_gb=$((total_mem_bytes / 1024 / 1024 / 1024))
            local total_mem_mb=$((total_mem_bytes / 1024 / 1024))
            echo "Total RAM: ${total_mem_gb} GB (${total_mem_mb} MB)"

            # Calculate available memory from vm_stat (approximate)
            # Note: macOS doesn't have a direct "available" metric like Linux
            # We'll use free + inactive memory as an approximation
            local page_size=$(vm_stat | grep "page size" | awk '{print $8}' | sed 's/\.//')
            if [ -n "$page_size" ]; then
                local free_pages=$(vm_stat | grep "Pages free" | awk '{print $3}' | sed 's/\.//')
                local inactive_pages=$(vm_stat | grep "Pages inactive" | awk '{print $3}' | sed 's/\.//')
                if [ -n "$free_pages" ] && [ -n "$inactive_pages" ]; then
                    local available_bytes=$(( (free_pages + inactive_pages) * page_size ))
                    local available_gb=$((available_bytes / 1024 / 1024 / 1024))
                    local available_mb=$((available_bytes / 1024 / 1024))
                    echo "Available RAM: ${available_gb} GB (${available_mb} MB) [approximate: free + inactive]"
                fi
            fi
        else
            echo "Memory info not available"
        fi
    elif [ -f /proc/meminfo ]; then
        # Linux
        local total_mem_kb=$(grep "MemTotal" /proc/meminfo | awk '{print $2}')
        if [ -n "$total_mem_kb" ]; then
            local total_mem_gb=$((total_mem_kb / 1024 / 1024))
            local total_mem_mb=$((total_mem_kb / 1024))
            echo "Total RAM: ${total_mem_gb} GB (${total_mem_mb} MB)"
        fi

        local available_mem_kb=$(grep "MemAvailable" /proc/meminfo | awk '{print $2}')
        if [ -n "$available_mem_kb" ]; then
            local available_mem_gb=$((available_mem_kb / 1024 / 1024))
            local available_mem_mb=$((available_mem_kb / 1024))
            echo "Available RAM: ${available_mem_gb} GB (${available_mem_mb} MB)"
        fi
    else
        echo "Memory info not available"
    fi
    echo ""

    # System Information
    echo "--- System ---"
    echo "OS: ${os_type}"
    echo "Kernel: $(uname -r)"
    echo "Hostname: $(hostname 2>/dev/null || echo 'N/A')"
    echo ""

    # Swift Information
    echo "--- Swift ---"
    swift --version | head -1
    echo ""

    # Build Configuration
    echo "--- Build Configuration ---"
    echo "Build Mode: RELEASE"
    local package_name=$(swift package describe --type json 2>/dev/null | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo 'N/A')
    echo "Swift Package: ${package_name}"
    echo ""

    echo "=== End System Information ==="
    echo ""
}

# Generate machine identifier for filename
MACHINE_ID=$(generate_machine_id)

# Defaults (override via env vars)
ROOM_COUNTS="${ROOM_COUNTS:-5,10,20,30,50}"
PLAYER_COUNTS="${PLAYER_COUNTS:-4,10,20,30,50}"
CONCURRENCY_LEVELS="${CONCURRENCY_LEVELS:-1,2,4,8,16}"
TICK_MODE="${TICK_MODE:-staggered}"
TICK_STRIDES="${TICK_STRIDES:-1,2,3,4}"
DIRTY_RATIO="${DIRTY_RATIO:-}"
# Whether to run tests in parallel (default: false, run sequentially)
PARALLEL="${PARALLEL:-false}"

SUITE_NAME="TransportMultiRoomParallelTuning-Medium20%"

# Parse comma-separated lists into arrays
IFS=',' read -ra ROOM_ARRAY <<< "$ROOM_COUNTS"
IFS=',' read -ra PLAYER_ARRAY <<< "$PLAYER_COUNTS"
IFS=',' read -ra CONCURRENCY_ARRAY <<< "$CONCURRENCY_LEVELS"

# Calculate total number of test combinations
TOTAL_TESTS=$((${#ROOM_ARRAY[@]} * ${#PLAYER_ARRAY[@]} * ${#CONCURRENCY_ARRAY[@]}))
CURRENT_TEST=0

echo "Running TransportAdapter multi-room parallel encoding tuning in RELEASE mode..."
echo "Timestamp: $TIMESTAMP"
echo "Machine ID: $MACHINE_ID"
echo "Suite: $SUITE_NAME"
echo "Room counts to test: $ROOM_COUNTS"
echo "Players per room to test: $PLAYER_COUNTS"
echo "Concurrency levels: $CONCURRENCY_LEVELS"
echo "Tick mode: $TICK_MODE"
echo "Tick strides: $TICK_STRIDES"
if [ -n "$DIRTY_RATIO" ]; then
    echo "Dirty ratio override: $DIRTY_RATIO"
fi
echo "Total test combinations: $TOTAL_TESTS"
echo "Run mode: $([ "$PARALLEL" = "true" ] && echo "PARALLEL" || echo "SEQUENTIAL")"
echo "Results will be written to a single merged file."
echo ""

# Define single output file
OUTPUT_FILE="$OUT_DIR/transport-multiroom-parallel-tuning-dirty-on-${MACHINE_ID}-$TIMESTAMP.txt"

# Function to run a single benchmark test
run_single_test() {
    local room_count=$1
    local player_count=$2
    local concurrency=$3
    local is_first_test=$4
    
    CURRENT_TEST=$((CURRENT_TEST + 1))
    echo "[$CURRENT_TEST/$TOTAL_TESTS] Running test: rooms=$room_count, players=$player_count, concurrency=$concurrency"
    
    # Use temporary file for parallel execution to avoid interleaved output
    local temp_file="${OUTPUT_FILE}.tmp.${room_count}.${player_count}.${concurrency}.$$"
    
    {
        # Only include system info in first test
        if [ "$is_first_test" = "true" ]; then
            collect_system_info
        fi
        
        echo ""
        echo "================================================================================"
        echo "=== Test Configuration: rooms=$room_count, players=$player_count, concurrency=$concurrency ==="
        echo "=== Benchmark started at: $(date) ==="
        echo "================================================================================"
        echo ""
        swift run -c release SwiftStateTreeBenchmarks transport-multiroom-parallel-tuning \
            --dirty-on \
            --suite-name="$SUITE_NAME" \
            --player-counts="$player_count" \
            --room-counts="$room_count" \
            --parallel-concurrency="$concurrency" \
            --tick-mode="$TICK_MODE" \
            --tick-strides="$TICK_STRIDES" \
            ${DIRTY_RATIO:+--dirty-ratio="$DIRTY_RATIO"} \
            --no-wait \
            --csv
        echo ""
        echo "=== Benchmark completed at: $(date) ==="
        echo ""
    } > "$temp_file" 2>&1
    
    local exit_code=$?
    
    # Append to main output file
    # For parallel execution, we'll collect temp files and merge at the end
    if [ "$PARALLEL" = "true" ]; then
        # Just keep the temp file, we'll merge later
        echo "$temp_file" >> "${OUTPUT_FILE}.temp_list"
    else
        # Sequential: directly append
        cat "$temp_file" >> "$OUTPUT_FILE"
        rm -f "$temp_file"
    fi
    
    if [ $exit_code -eq 0 ]; then
        echo "  ✓ Completed"
    else
        echo "  ✗ Failed (exit code: $exit_code)"
    fi
    return $exit_code
}

###############################################################################
# Dirty Tracking ON - Run each test combination in separate process
###############################################################################
echo "=== DirtyTracking: ON ==="
echo ""

# Initialize output file
> "$OUTPUT_FILE"  # Create/clear the output file

FAILED_TESTS=0
PIDS=()
FIRST_TEST=true

# Run all test combinations
for room_count in "${ROOM_ARRAY[@]}"; do
    for player_count in "${PLAYER_ARRAY[@]}"; do
        for concurrency in "${CONCURRENCY_ARRAY[@]}"; do
            if [ "$PARALLEL" = "true" ]; then
                # Run in background (parallel)
                run_single_test "$room_count" "$player_count" "$concurrency" "$FIRST_TEST" &
                PIDS+=($!)
                FIRST_TEST=false
            else
                # Run sequentially
                if ! run_single_test "$room_count" "$player_count" "$concurrency" "$FIRST_TEST"; then
                    FAILED_TESTS=$((FAILED_TESTS + 1))
                fi
                FIRST_TEST=false
            fi
        done
    done
done

# Wait for all background processes if running in parallel
if [ "$PARALLEL" = "true" ]; then
    echo ""
    echo "Waiting for all tests to complete..."
    for pid in "${PIDS[@]}"; do
        if ! wait "$pid"; then
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
    done
    
    # Merge all temp files into main output file
    echo ""
    echo "Merging results..."
    if [ -f "${OUTPUT_FILE}.temp_list" ]; then
        while IFS= read -r temp_file; do
            if [ -f "$temp_file" ]; then
                cat "$temp_file" >> "$OUTPUT_FILE"
                rm -f "$temp_file"
            fi
        done < "${OUTPUT_FILE}.temp_list"
        rm -f "${OUTPUT_FILE}.temp_list"
    fi
fi

echo ""
if [ $FAILED_TESTS -eq 0 ]; then
    echo "✓ All transport-multiroom-parallel-tuning benchmarks completed successfully."
else
    echo "✗ $FAILED_TESTS test(s) failed."
fi
echo "Results written to: $OUTPUT_FILE"
echo "Timestamp: $TIMESTAMP"
