#!/usr/bin/env bash
# Fix Windows line endings if present (for Windows Docker compatibility)
# Re-execute script with CR characters removed if needed
if [ -z "$_CRLF_FIXED" ]; then
    export _CRLF_FIXED=1
    exec bash <(sed 's/\r$//' "$0") "$@"
    exit $?
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
PLAYER_COUNTS="${PLAYER_COUNTS:-4,10,20,30,50}"
DIRTY_RATIO="${DIRTY_RATIO:-}"

SUITE_NAME="TransportParallelTuning-Medium20%"

echo "Running TransportAdapter parallel encoding tuning in RELEASE mode..."
echo "Timestamp: $TIMESTAMP"
echo "Machine ID: $MACHINE_ID"
echo "Suite: $SUITE_NAME"
echo "Player counts to test: $PLAYER_COUNTS"
if [ -n "$DIRTY_RATIO" ]; then
    echo "Dirty ratio override: $DIRTY_RATIO"
fi
echo "Results will be written to:"
echo "  - $OUT_DIR/transport-parallel-tuning-dirty-on-${MACHINE_ID}-$TIMESTAMP.txt"
echo "  - $OUT_DIR/transport-parallel-tuning-dirty-off-${MACHINE_ID}-$TIMESTAMP.txt"
echo ""

###############################################################################
# 1) Dirty Tracking ON
###############################################################################
echo "=== [1/2] DirtyTracking: ON ==="
{
  collect_system_info
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  echo "Running suite: $SUITE_NAME"
  swift run -c release SwiftStateTreeBenchmarks transport-parallel-tuning \
    --dirty-on \
    --suite-name="$SUITE_NAME" \
    --player-counts="$PLAYER_COUNTS" \
    ${DIRTY_RATIO:+--dirty-ratio="$DIRTY_RATIO"} \
    --no-wait \
    --csv
  echo ""
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-parallel-tuning-dirty-on-${MACHINE_ID}-$TIMESTAMP.txt" 2>&1

###############################################################################
# 2) Dirty Tracking OFF
###############################################################################
echo "=== [2/2] DirtyTracking: OFF ==="
{
  collect_system_info
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  echo "Running suite: $SUITE_NAME"
  swift run -c release SwiftStateTreeBenchmarks transport-parallel-tuning \
    --dirty-off \
    --suite-name="$SUITE_NAME" \
    --player-counts="$PLAYER_COUNTS" \
    ${DIRTY_RATIO:+--dirty-ratio="$DIRTY_RATIO"} \
    --no-wait \
    --csv
  echo ""
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-parallel-tuning-dirty-off-${MACHINE_ID}-$TIMESTAMP.txt" 2>&1

echo ""
echo "All transport-parallel-tuning benchmarks completed."
echo "Check generated txt files under: $OUT_DIR/"
echo "Files generated with timestamp: $TIMESTAMP"
