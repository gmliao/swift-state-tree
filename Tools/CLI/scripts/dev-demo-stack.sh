#!/bin/bash
# Dev script: Start DemoServer for counter/cookie demo (no matchmaking).
#
# Usage: from Tools/CLI: npm run dev:demo
#        or: bash scripts/dev-demo-stack.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

echo "=========================================="
echo "  Demo Dev Stack"
echo "=========================================="
echo "DemoServer: ws://127.0.0.1:8080"
echo "  - counter: ws://127.0.0.1:8080/game/counter"
echo "  - cookie:  ws://127.0.0.1:8080/game/cookie"
echo ""
echo "Press Ctrl+C to stop."
echo ""

cd "$PROJECT_ROOT/Examples/Demo"
TRANSPORT_ENCODING="${TRANSPORT_ENCODING:-jsonOpcode}" swift run DemoServer
