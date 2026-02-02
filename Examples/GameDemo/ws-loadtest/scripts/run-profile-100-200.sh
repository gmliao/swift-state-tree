#!/usr/bin/env bash
# Run transport profiling with 100 and 200 rooms. No need to run until failure;
# 100/200 rooms give enough data to see encode_ms, send_ms, stateUpdates trends.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Profile 100 rooms ==="
"$SCRIPT_DIR/run-ws-loadtest.sh" \
  --scenario scenarios/hero-defense/profile-100rooms.json \
  --output-dir results/profile-100 \
  --profile

echo ""
echo "=== Profile 200 rooms ==="
"$SCRIPT_DIR/run-ws-loadtest.sh" \
  --scenario scenarios/hero-defense/profile-200rooms.json \
  --output-dir results/profile-200 \
  --profile

echo ""
echo "Done. Transport profile JSONL:"
echo "  100 rooms: $ROOT_DIR/results/profile-100/transport-profile.jsonl"
echo "  200 rooms: $ROOT_DIR/results/profile-200/transport-profile.jsonl"
echo ""
echo "Compare stateUpdates, encode_ms, send_ms, lag_ms between the two runs."
