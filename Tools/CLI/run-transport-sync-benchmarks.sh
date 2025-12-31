#!/usr/bin/env bash
set -euo pipefail

# Change to repository root (this script lives in Tools/CLI)
cd "$(dirname "$0")/../.."

OUT_DIR="Notes/performance"
mkdir -p "$OUT_DIR"

# Generate timestamp for file naming (format: YYYYMMDD-HHMMSS)
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

echo "Running TransportAdapter sync benchmarks in RELEASE mode..."
echo "Timestamp: $TIMESTAMP"
echo "Results will be written to:"
echo "  - $OUT_DIR/transport-sync-dirty-on-$TIMESTAMP.txt"
echo "  - $OUT_DIR/transport-sync-dirty-off-$TIMESTAMP.txt"
echo "  - $OUT_DIR/transport-sync-players-dirty-on-$TIMESTAMP.txt"
echo "  - $OUT_DIR/transport-sync-players-dirty-off-$TIMESTAMP.txt"
echo ""

###############################################################################
# 1) Dirty Tracking ON（使用 Benchmark 預設的 dirty ratio 配置）
###############################################################################
echo "=== [1/4] DirtyTracking: ON (benchmark default ratios) ==="
{
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  swift run -c release SwiftStateTreeBenchmarks transport-sync \
    --dirty-on \
    --no-wait \
    --csv
  echo ""
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-sync-dirty-on-$TIMESTAMP.txt" 2>&1

###############################################################################
# 2) Dirty Tracking OFF（使用 Benchmark 預設的 dirty ratio 配置）
###############################################################################
echo "=== [2/4] DirtyTracking: OFF (benchmark default ratios) ==="
{
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  swift run -c release SwiftStateTreeBenchmarks transport-sync \
    --dirty-off \
    --no-wait \
    --csv
  echo ""
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-sync-dirty-off-$TIMESTAMP.txt" 2>&1

###############################################################################
# 3) Dirty Tracking ON (Public Players Hot)
###############################################################################
echo "=== [3/4] DirtyTracking: ON (public players hot) ==="
{
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  swift run -c release SwiftStateTreeBenchmarks transport-sync-players \
    --dirty-on \
    --no-wait \
    --csv
  echo ""
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-sync-players-dirty-on-$TIMESTAMP.txt" 2>&1

###############################################################################
# 4) Dirty Tracking OFF (Public Players Hot)
###############################################################################
echo "=== [4/4] DirtyTracking: OFF (public players hot) ==="
{
  echo "=== Benchmark started at: $(date) ==="
  echo ""
  swift run -c release SwiftStateTreeBenchmarks transport-sync-players \
    --dirty-off \
    --no-wait \
    --csv
  echo ""
  echo "=== Benchmark completed at: $(date) ==="
} > "$OUT_DIR/transport-sync-players-dirty-off-$TIMESTAMP.txt" 2>&1

echo ""
echo "All transport-sync benchmarks completed."
echo "Check generated txt files under: $OUT_DIR/"
echo "Files generated with timestamp: $TIMESTAMP"