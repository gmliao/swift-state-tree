#!/usr/bin/env bash
# Re-records the sync-output golden recordings in
# Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens and their expected summaries.
#
# Run it only for an intentional change to the sync output (the diff, the canonical form, the
# hashes, the record format, or the verifier test land), and say why in the PR. Then run
# `swift test --filter SyncOutputGoldenTests` without it to check the new baseline.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

SST_REGENERATE_SYNC_OUTPUT_GOLDENS=1 IN_TURN_SYNC=true \
    swift test --filter SyncOutputGoldenTests

echo "Regenerated:"
git status --short -- Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens
