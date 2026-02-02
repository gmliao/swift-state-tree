#!/usr/bin/env bash
# Run GameServer under lldb to capture backtrace when it crashes (freed pointer / SIGABRT).
# Usage:
#   Terminal 1: ./run-gameserver-lldb-backtrace.sh   (starts lldb + GameServer)
#   Terminal 2: when server is up, run the trigger command below; when crash happens, in lldb run: bt
#   Optional: TRIGGER=1 ./run-gameserver-lldb-backtrace.sh  (script runs client automatically after 15s)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAMEDEMO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$GAMEDEMO_DIR/../.." && pwd)"
CLI_DIR="$PROJECT_ROOT/Tools/CLI"

echo "Building GameServer (release)..."
cd "$GAMEDEMO_DIR"
swift build -c release

BINARY="$GAMEDEMO_DIR/.build/release/GameServer"
if [ ! -f "$BINARY" ]; then
    echo "Error: GameServer binary not found at $BINARY"
    exit 1
fi

TRIGGER_CMD="cd $CLI_DIR && TRANSPORT_ENCODING=messagepack npx tsx src/cli.ts script -u ws://localhost:8080/game/hero-defense -l hero-defense:test-\$(date +%s) -s scenarios/game/ --state-update-encoding messagepack"
echo ""
echo "When server is up, in another terminal run:"
echo "  $TRIGGER_CMD"
echo ""
echo "When the server crashes (freed pointer / SIGABRT), in lldb run: bt"
echo ""

if [ "${TRIGGER:-0}" = "1" ]; then
  OUTPUT_FILE="${GAMEDEMO_DIR}/tmp/lldb-backtrace.txt"
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  echo "TRIGGER=1: starting lldb in batch; client will run after 45s (server under lldb may start slow); backtrace -> $OUTPUT_FILE"
  (
    sleep 45
    cd "$CLI_DIR"
    TRANSPORT_ENCODING=messagepack npx tsx src/cli.ts script \
      -u ws://localhost:8080/game/hero-defense \
      -l "hero-defense:test-$(date +%s)" \
      -s scenarios/game/ \
      --state-update-encoding messagepack || true
  ) &
  cd "$GAMEDEMO_DIR"
  ENABLE_REEVALUATION=false TRANSPORT_ENCODING=messagepack LOG_LEVEL=info NO_COLOR=1 \
    lldb -b -o "run" -o "bt 50" -o "thread backtrace all" -o "quit" -- "$BINARY" 2>&1 | tee "$OUTPUT_FILE"
  echo ""
  echo "Backtrace written to $OUTPUT_FILE"
  exit 0
fi

cd "$GAMEDEMO_DIR"
ENABLE_REEVALUATION=false TRANSPORT_ENCODING=messagepack LOG_LEVEL=info NO_COLOR=1 \
  lldb -- "$BINARY"
