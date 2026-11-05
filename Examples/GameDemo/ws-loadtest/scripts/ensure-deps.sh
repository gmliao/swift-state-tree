#!/usr/bin/env bash
# Installs and builds what ws-loadtest needs before its own `npm run build`:
#   1. sdk/ts dependencies (`npm ci`) when its node_modules is missing or older than its lockfile;
#   2. sdk/ts itself (`npm run build`) when dist/ is missing or older than its sources, since
#      ws-loadtest depends on it through `file:../../../sdk/ts` and imports its dist/;
#   3. ws-loadtest dependencies (`npm ci`) when node_modules is missing or older than its lockfile.
# Only `npm ci`, so neither package-lock.json is rewritten. Does nothing when all are current.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOADTEST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SDK_DIR="$(cd "$LOADTEST_DIR/../../../sdk/ts" && pwd)"
SDK_STAMP="$SDK_DIR/dist/.ws-loadtest-build-stamp"

# True when the reference file is missing or any file under the other paths is newer than it.
stale() {
  local ref="$1"
  shift
  [ -e "$ref" ] || return 0
  [ -n "$(find "$@" -type f -newer "$ref" -print -quit 2>/dev/null)" ]
}

if stale "$SDK_DIR/node_modules/.package-lock.json" "$SDK_DIR/package-lock.json"; then
  echo "Installing sdk/ts dependencies (npm ci)..."
  (cd "$SDK_DIR" && npm ci)
fi

if stale "$SDK_STAMP" "$SDK_DIR/src" "$SDK_DIR/package.json" "$SDK_DIR/tsconfig.json" "$SDK_DIR/tsconfig.build.json"; then
  echo "Building sdk/ts (dist/ missing or older than its sources)..."
  (cd "$SDK_DIR" && npm run build)
  touch "$SDK_STAMP"
fi

if stale "$LOADTEST_DIR/node_modules/.package-lock.json" "$LOADTEST_DIR/package-lock.json"; then
  echo "Installing ws-loadtest dependencies (npm ci)..."
  (cd "$LOADTEST_DIR" && npm ci)
fi
