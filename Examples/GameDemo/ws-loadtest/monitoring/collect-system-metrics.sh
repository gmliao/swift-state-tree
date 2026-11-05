#!/usr/bin/env bash
# Kept for existing callers: samples <pid> into <output.json> every [intervalSeconds] (default 1).
# The sampler is collect-system-metrics.mjs (cumulative CPU time on a monotonic clock); `exec`
# keeps this PID, so a caller's `kill` reaches it and it closes the JSON.
set -euo pipefail

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "Usage: $0 <pid> <output.json> [intervalSeconds]"
  exit 1
fi

exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/collect-system-metrics.mjs" "$1" "$2" "${3:-1}"
