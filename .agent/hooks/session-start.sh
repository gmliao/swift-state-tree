#!/bin/bash
set -euo pipefail

# Only run in remote cloud sessions
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"

# --- sdk/ts ---
hashes_sdk=sdk/ts/node_modules/.session-start.sha256
if ! sha256sum --check --status "$hashes_sdk" 2>/dev/null; then
  rm -f "$hashes_sdk"
  (cd sdk/ts && npm install)
  sha256sum .agent/hooks/session-start.sh sdk/ts/package.json sdk/ts/package-lock.json > "$hashes_sdk" || rm -f "$hashes_sdk"
fi

# --- Tools/CLI ---
hashes_cli=Tools/CLI/node_modules/.session-start.sha256
if ! sha256sum --check --status "$hashes_cli" 2>/dev/null; then
  rm -f "$hashes_cli"
  (cd Tools/CLI && npm install)
  sha256sum .agent/hooks/session-start.sh Tools/CLI/package.json Tools/CLI/package-lock.json > "$hashes_cli" || rm -f "$hashes_cli"
fi
