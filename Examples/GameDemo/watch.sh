#!/bin/bash
# Watch script for GameDemo server
# Automatically rebuilds and runs GameServer when Swift files change

set -euo pipefail
cd "$(dirname "$0")"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ -z "${STATE_UPDATE_ENCODING:-}" ]]; then
  echo "Select state update encoding:"
  select choice in "opcodeJsonArray" "jsonObject"; do
    case "$choice" in
      opcodeJsonArray|jsonObject)
        STATE_UPDATE_ENCODING="$choice"
        break
        ;;
      *)
        echo "Invalid selection. Choose 1 or 2."
        ;;
    esac
  done
fi

export STATE_UPDATE_ENCODING

echo "Watching for changes in:"
echo "  - $(pwd)/Sources"
echo "  - $PROJECT_ROOT/Sources"
echo "Using STATE_UPDATE_ENCODING=$STATE_UPDATE_ENCODING"
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
