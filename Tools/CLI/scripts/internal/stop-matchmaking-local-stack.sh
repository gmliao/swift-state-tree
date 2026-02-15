#!/bin/bash
# Stop local matchmaking stack processes
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${E2E_PROJECT_ROOT:-$(cd "$SCRIPT_DIR/../../../.." && pwd)}"
TMP_DIR="${E2E_TMP_DIR:-$PROJECT_ROOT/tmp/e2e}"

for name in control-plane stub gameserver; do
    pid_file="$TMP_DIR/$name.pid"
    if [ -f "$pid_file" ]; then
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            echo "Stopping $name (PID $pid)..."
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    fi
done

# Fallback: kill by process name
pkill -f "MatchmakingSwiftProvisioningStub" 2>/dev/null || true
pkill -f "matchmaking-control-plane" 2>/dev/null || true
pkill -f "GameServer" 2>/dev/null || true

echo "Matchmaking stack stopped."
