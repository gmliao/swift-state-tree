#!/bin/bash
# Playwright-cli E2E test for replay stream
# Prerequisites: GameServer (ENABLE_REEVALUATION=true) and WebClient dev server running
# Usage: ./scripts/playwright-replay-e2e.sh [webclient_url]
# Default webclient: http://localhost:3002 (Vite may use 5173, 3001, 3002, etc.)
#
# Steps (refs from snapshot may vary):
#   1. playwright-cli open $WEB_URL
#   2. playwright-cli click e35     # Reevaluation button (or get ref from snapshot)
#   3. playwright-cli snapshot       # Get refs for record list
#   4. playwright-cli click e301     # 2-hero-defense.json listitem (ref from snapshot)
#   5. playwright-cli click e621     # Start Replay Stream (ref from snapshot)
#   6. sleep 5
#   7. playwright-cli console        # Verify Errors: 0
#   8. playwright-cli snapshot       # Verify "Connected", "Replay" in game view
#   9. playwright-cli close

set -e
WEB_URL="${1:-http://localhost:3002}"
CLI="${playwright_cli:-playwright-cli}"

if ! command -v $CLI &>/dev/null && ! command -v npx &>/dev/null; then
  echo "playwright-cli not found. Use: npx playwright-cli"
  exit 1
fi

RUN="playwright-cli"
[ -n "$(command -v playwright-cli 2>/dev/null)" ] || RUN="npx playwright-cli"

echo "=== Playwright-cli Replay E2E ==="
echo "WebClient: $WEB_URL"
echo ""

$RUN open "$WEB_URL"
$RUN click "Reevaluation"
$RUN snapshot
# Click listitem containing "2-hero-defense" (playwright-cli resolves by text when ref matches)
$RUN click "2-hero-defense"
$RUN click "Start Replay Stream"

sleep 5
$RUN console
$RUN snapshot
echo ""
echo "=== Done. Check console for Errors: 0, snapshot for Connected/Replay ==="
$RUN close
