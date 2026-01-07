#!/bin/bash
# Watch script for GameDemo server
# Automatically rebuilds and runs GameServer when Swift files change

set -euo pipefail
cd "$(dirname "$0")"

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Watching for changes in:"
echo "  - $(pwd)/Sources"
echo "  - $PROJECT_ROOT/Sources"
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
