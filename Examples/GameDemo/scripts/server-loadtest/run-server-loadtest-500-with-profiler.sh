#!/bin/bash
# Single 500-room ServerLoadTest with optional Swift Profile Recorder for hotspot analysis.
#
# ServerLoadTest runs server + client simulator in one process. When the process
# exits, everything is gone (no separate server to stop).
#
# === Hotspot analysis with Swift Profile Recorder ===
# 1. Enable the sampling server (uncomment the export below). Uses a UNIX socket
#    so you can curl from the same machine. {PID} is replaced by the process ID.
# 2. Run this script in one terminal. Note the process PID (e.g. from "Started ps sampler"
#    or `pgrep -f ServerLoadTest`).
# 3. While the load test is running (e.g. during steady state), in another terminal:
#      SOCK=/tmp/serverloadtest-samples-<PID>.sock
#      curl -sd '{"numberOfSamples":500,"timeInterval":"10ms"}' --unix-socket "$SOCK" http://localhost/sample | swift demangle --compact > /tmp/samples.perf
# 4. View hotspots:
#      - Drag /tmp/samples.perf into https://speedscope.app or https://profiler.firefox.com
#      - Or: ./stackcollapse-perf.pl < /tmp/samples.perf | swift demangle --compact | ./flamegraph.pl > samples.svg && open samples.svg
#
# See also: scripts/server-loadtest/PROFILING_HOTSPOTS.md
#
# Usage:
#   bash run-server-loadtest-500-with-profiler.sh
#   PROFILE_RECORDER_SERVER_URL_PATTERN='unix:///tmp/serverloadtest-samples-{PID}.sock' bash run-server-loadtest-500-with-profiler.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../.."

# Enable profile recorder server for hotspot sampling (uncomment to use)
# export PROFILE_RECORDER_SERVER_URL_PATTERN='unix:///tmp/serverloadtest-samples-{PID}.sock'

bash "$SCRIPT_DIR/run-server-loadtest.sh" \
  --rooms 500 \
  --players-per-room 5 \
  --duration-seconds 60 \
  --ramp-up-seconds 30 \
  --ramp-down-seconds 10 \
  --no-monitoring \
  --release
