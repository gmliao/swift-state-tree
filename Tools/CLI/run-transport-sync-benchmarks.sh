#!/usr/bin/env bash
set -eu
set -o pipefail

# Change to repository root (this script lives in Tools/CLI)
cd "$(dirname "$0")/../.."

OUT_DIR="Notes/performance"
mkdir -p "$OUT_DIR"

# Generate timestamp for file naming (format: YYYYMMDD-HHMMSS)
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# Function to generate machine identifier from system info
generate_machine_id() {
    local cpu_model="unknown"
    local cpu_cores="unknown"
    local ram_gb="unknown"
    local swift_version="unknown"

    # CPU Information
    if [ -f /proc/cpuinfo ]; then
        cpu_model=$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | sed 's/^[[:space:]]*//' | sed 's/[^a-zA-Z0-9]/_/g' | cut -c1-30)
        cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
    fi

    # Memory Information
    if [ -f /proc/meminfo ]; then
        local total_mem_kb=$(grep "MemTotal" /proc/meminfo | awk '{print $2}')
        if [ -n "$total_mem_kb" ]; then
            local total_mem_gb=$((total_mem_kb / 1024 / 1024))
            ram_gb="${total_mem_gb}GB"
        fi
    fi

    # Swift Information
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

    # CPU Information
    echo "--- CPU ---"
    if [ -f /proc/cpuinfo ]; then
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
    if [ -f /proc/meminfo ]; then
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
    echo "OS: $(uname -s)"
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

# Default player counts to test (can be overridden via PLAYER_COUNTS environment variable)
PLAYER_COUNTS="${PLAYER_COUNTS:-4,10,20,30,50}"

echo "Running TransportAdapter sync benchmarks in RELEASE mode..."
echo "Timestamp: $TIMESTAMP"
echo "Machine ID: $MACHINE_ID"
echo "Player counts to test: $PLAYER_COUNTS"
echo "Results will be written to:"
echo "  - $OUT_DIR/transport-sync-dirty-on-${MACHINE_ID}-$TIMESTAMP.txt"
echo "  - $OUT_DIR/transport-sync-dirty-off-${MACHINE_ID}-$TIMESTAMP.txt"
echo "  - $OUT_DIR/transport-sync-players-dirty-on-${MACHINE_ID}-$TIMESTAMP.txt"
echo "  - $OUT_DIR/transport-sync-players-dirty-off-${MACHINE_ID}-$TIMESTAMP.txt"
echo ""

###############################################################################
# 1) Dirty Tracking ON（使用 Benchmark 預設的 dirty ratio 配置）
# Each suite runs in a separate process to avoid interference
###############################################################################
echo "=== [1/4] DirtyTracking: ON (benchmark default ratios) ==="
{
  collect_system_info
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  # Run each suite separately to avoid interference between tests
  # Each suite runs in its own process for accurate, isolated testing
  for suite_name in "TransportSync-Parallel-Low5%" "TransportSync-Parallel-Medium20%" "TransportSync-Parallel-High80%" \
                     "TransportSync-Serial-Low5%" "TransportSync-Serial-High80%"; do
    echo "Running suite: $suite_name"
    swift run -c release SwiftStateTreeBenchmarks transport-sync \
      --dirty-on \
      --suite-name="$suite_name" \
      --player-counts="$PLAYER_COUNTS" \
      --no-wait \
      --csv
    echo ""
  done
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-sync-dirty-on-${MACHINE_ID}-$TIMESTAMP.txt" 2>&1

###############################################################################
# 2) Dirty Tracking OFF（使用 Benchmark 預設的 dirty ratio 配置）
# Each suite runs in a separate process to avoid interference
###############################################################################
echo "=== [2/4] DirtyTracking: OFF (benchmark default ratios) ==="
{
  collect_system_info
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  # Run each suite separately to avoid interference between tests
  # Each suite runs in its own process for accurate, isolated testing
  for suite_name in "TransportSync-Parallel-Low5%" "TransportSync-Parallel-Medium20%" "TransportSync-Parallel-High80%" \
                     "TransportSync-Serial-Low5%" "TransportSync-Serial-High80%"; do
    echo "Running suite: $suite_name"
    swift run -c release SwiftStateTreeBenchmarks transport-sync \
      --dirty-off \
      --suite-name="$suite_name" \
      --player-counts="$PLAYER_COUNTS" \
      --no-wait \
      --csv
    echo ""
  done
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-sync-dirty-off-${MACHINE_ID}-$TIMESTAMP.txt" 2>&1

###############################################################################
# 3) Dirty Tracking ON (Public Players Hot)
# Each suite runs in a separate process to avoid interference
###############################################################################
echo "=== [3/4] DirtyTracking: ON (public players hot) ==="
{
  collect_system_info
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  # Run each suite separately to avoid interference between tests
  # Each suite runs in its own process for accurate, isolated testing
  # Note: TransportSyncPlayers-Hot-Parallel-* removed because they're identical to TransportSyncPlayers-Hot-Parallel-* above
  # We only need Serial vs Parallel comparison, not nil vs true
  for suite_name in "TransportSyncPlayers-Hot-Parallel-Low5%" "TransportSyncPlayers-Hot-Parallel-Medium20%" "TransportSyncPlayers-Hot-Parallel-High80%" \
                     "TransportSyncPlayers-Hot-Serial-Low5%" "TransportSyncPlayers-Hot-Serial-High80%"; do
    echo "Running suite: $suite_name"
    swift run -c release SwiftStateTreeBenchmarks transport-sync-players \
      --dirty-on \
      --suite-name="$suite_name" \
      --player-counts="$PLAYER_COUNTS" \
      --no-wait \
      --csv
    echo ""
  done
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-sync-players-dirty-on-${MACHINE_ID}-$TIMESTAMP.txt" 2>&1

###############################################################################
# 4) Dirty Tracking OFF (Public Players Hot)
# Each suite runs in a separate process to avoid interference
###############################################################################
echo "=== [4/4] DirtyTracking: OFF (public players hot) ==="
{
  collect_system_info
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  # Run each suite separately to avoid interference between tests
  # Each suite runs in its own process for accurate, isolated testing
  # Note: TransportSyncPlayers-Hot-Parallel-* removed because they're identical to TransportSyncPlayers-Hot-Parallel-* above
  # We only need Serial vs Parallel comparison, not nil vs true
  for suite_name in "TransportSyncPlayers-Hot-Parallel-Low5%" "TransportSyncPlayers-Hot-Parallel-Medium20%" "TransportSyncPlayers-Hot-Parallel-High80%" \
                     "TransportSyncPlayers-Hot-Serial-Low5%" "TransportSyncPlayers-Hot-Serial-High80%"; do
    echo "Running suite: $suite_name"
    swift run -c release SwiftStateTreeBenchmarks transport-sync-players \
      --dirty-off \
      --suite-name="$suite_name" \
      --player-counts="$PLAYER_COUNTS" \
      --no-wait \
      --csv
    echo ""
  done
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-sync-players-dirty-off-${MACHINE_ID}-$TIMESTAMP.txt" 2>&1

echo ""
echo "All transport-sync benchmarks completed."
echo "Check generated txt files under: $OUT_DIR/"
echo "Files generated with timestamp: $TIMESTAMP"
