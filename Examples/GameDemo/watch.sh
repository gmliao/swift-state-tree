#!/bin/bash
# Watch script for GameDemo server
# Automatically rebuilds and runs GameServer when Swift files change

set -euo pipefail
cd "$(dirname "$0")"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Single variable controls both StateUpdate and TransportMessage encoding
if [[ -z "${TRANSPORT_ENCODING:-}" ]]; then
  echo "Select transport encoding (default: opcode, press Enter to use default):"
  echo "  1) opcode - uses opcodeJsonArray for both StateUpdate and TransportMessage"
  echo "  2) json   - uses jsonObject for StateUpdate, json for TransportMessage"
  
  # Use timeout to allow Enter to select default
  if read -t 2 -r choice; then
    case "$choice" in
      1|opcode)
        TRANSPORT_ENCODING="opcode"
        ;;
      2|json)
        TRANSPORT_ENCODING="json"
        ;;
      "")
        # Empty input (just Enter) - use default
        TRANSPORT_ENCODING="opcode"
        echo "Using default: opcode"
        ;;
      *)
        echo "Invalid selection. Using default: opcode"
        TRANSPORT_ENCODING="opcode"
        ;;
    esac
  else
    # Timeout or no input - use default
    TRANSPORT_ENCODING="opcode"
    echo "Using default: opcode"
  fi
fi

export TRANSPORT_ENCODING

# Display startup info with box
echo "╔════════════════════════════════════════════════════════════╗"
echo "║              GameDemo Server - Watch Mode                  ║"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  Watching for changes in:                                  ║"
echo "║    • $(pwd)/Sources"
echo "║    • $PROJECT_ROOT/Sources"
echo "╠════════════════════════════════════════════════════════════╣"
echo "║  Encoding: $TRANSPORT_ENCODING"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

watchexec \
  --verbose \
  --restart \
  --watch Sources \
  --watch "$PROJECT_ROOT/Sources" \
  --ignore .build \
  --ignore .swiftpm \
  --ignore node_modules \
  --exts swift \
  -- \
  swift run GameServer
