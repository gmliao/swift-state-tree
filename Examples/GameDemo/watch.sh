#!/bin/bash
# Watch script for GameDemo server
# Automatically rebuilds and runs GameServer when Swift files change

set -euo pipefail
cd "$(dirname "$0")"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Single variable controls both StateUpdate and TransportMessage encoding
if [[ -z "${TRANSPORT_ENCODING:-}" ]]; then
  echo "Select transport encoding (default: messagepack, press Enter to use default):"
  echo "  1) messagepack - uses MessagePack binary (Opcode structure + MessagePack encoding)"
  echo "  2) opcode      - uses opcodeJsonArray (Opcode structure + JSON encoding)"
  echo "  3) json        - uses jsonObject (traditional JSON)"
  
  # Use timeout to allow Enter to select default
  if read -t 2 -r choice; then
    case "$choice" in
      1|messagepack)
        TRANSPORT_ENCODING="messagepack"
        ;;
      2|opcode)
        TRANSPORT_ENCODING="opcode"
        ;;
      3|json)
        TRANSPORT_ENCODING="json"
        ;;
      "")
        # Empty input (just Enter) - use default
        TRANSPORT_ENCODING="messagepack"
        echo "Using default: messagepack"
        ;;
      *)
        echo "Invalid selection. Using default: messagepack"
        TRANSPORT_ENCODING="messagepack"
        ;;
    esac
  else
    # Timeout or no input - use default
    TRANSPORT_ENCODING="messagepack"
    echo "Using default: messagepack"
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
