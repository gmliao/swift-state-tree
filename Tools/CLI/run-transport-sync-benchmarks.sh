#!/usr/bin/env bash
set -euo pipefail

# Change to repository root (this script lives in Tools/CLI)
cd "$(dirname "$0")/../.."

OUT_DIR="docs/performance"
mkdir -p "$OUT_DIR"

echo "Running TransportAdapter sync benchmarks in RELEASE mode..."
echo "Results will be written to:"
echo "  - $OUT_DIR/transport-sync-dirty-on.txt"
echo "  - $OUT_DIR/transport-sync-dirty-off.txt"
echo "  - $OUT_DIR/transport-sync-players-dirty-on.txt"
echo "  - $OUT_DIR/transport-sync-players-dirty-off.txt"
echo ""

###############################################################################
# 1) Dirty Tracking ON（使用 Benchmark 預設的 dirty ratio 配置）
###############################################################################
echo "=== [1/2] DirtyTracking: ON (benchmark default ratios) ==="
swift run -c release SwiftStateTreeBenchmarks transport-sync \
  --dirty-on \
  --no-wait \
  --csv \
  > "$OUT_DIR/transport-sync-dirty-on.txt"

###############################################################################
# 2) Dirty Tracking OFF（使用 Benchmark 預設的 dirty ratio 配置）
###############################################################################
echo "=== [2/2] DirtyTracking: OFF (benchmark default ratios) ==="
swift run -c release SwiftStateTreeBenchmarks transport-sync \
  --dirty-off \
  --no-wait \
  --csv \
  > "$OUT_DIR/transport-sync-dirty-off.txt"

###############################################################################
# 3) Dirty Tracking ON (Public Players Hot)
###############################################################################
echo "=== [3/4] DirtyTracking: ON (public players hot) ==="
swift run -c release SwiftStateTreeBenchmarks transport-sync-players \
  --dirty-on \
  --no-wait \
  --csv \
  > "$OUT_DIR/transport-sync-players-dirty-on.txt"

###############################################################################
# 4) Dirty Tracking OFF (Public Players Hot)
###############################################################################
echo "=== [4/4] DirtyTracking: OFF (public players hot) ==="
swift run -c release SwiftStateTreeBenchmarks transport-sync-players \
  --dirty-off \
  --no-wait \
  --csv \
  > "$OUT_DIR/transport-sync-players-dirty-off.txt"

echo ""
echo "All transport-sync benchmarks completed."
echo "Check generated txt files under: $OUT_DIR/"

